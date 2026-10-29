#!/usr/bin/env python3
"""Export the build-check results as one public JSON dataset (and an optional summary.md).

Usage:
  python3 scripts/export-dataset.py \
      --projects data/projects.json \
      --results results/works2/results.json results/partial2/results.json results/research2/results.json \
      --as-of 2026-10-29 \
      --out /path/to/ai-ports-build-check.json \
      [--markdown /path/to/summary.md] [--batches batches]

Works on schema 1 and schema 2 result rows; a field a row does not carry is null.
Rows are joined to data/projects.json through the batch files (id -> slug) and, failing
that, by a case-insensitive match on the repository URL. Only the title, the raw model
string and the model family come from the project list; everything else is the harness's own record.
No logs and no root_files are exported.
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

SOURCE_URL = "https://reversedwithai.com"
HARNESS_URL = "https://github.com/major-matters/ai-port-build-check"
RUNNER = "ubuntu-24.04"
BUDGET_MINUTES = 20
SCHEMA_VERSION = 1  # of this export, not of the result rows
REPRODUCIBLE = ("built", "static_web")
OUTCOMES = ("Works", "Partial", "Research")
TITLE_SUFFIX = " · Reversed with AI"
URL_RE = re.compile(r"^https?://(?:www\.)?(github\.com|gitlab\.com|codeberg\.org)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/.*)?$")

# One plain-English sentence per value, taken from README.md ("Result vocabulary").
RESULT_VOCAB = {
    "built": "The build command finished with exit code 0 on a clean Ubuntu runner within the time budget.",
    "static_web": "There were no build files, but an index.html sits at the root or in web/, public/ or dist/, so there is nothing to build and it counts as reproducible.",
    "build_failed": "The build command ran and exited nonzero; the reason and reason_detail say what the log showed.",
    "timeout": "The build ran past the budget (20 minutes, package installation not included) and was stopped.",
    "no_build_system": "No recognized build files were found anywhere from the root down to three directory levels.",
    "needs_toolchain": "A build system was found that a stock Ubuntu runner cannot drive, such as a Visual Studio solution, an Xcode project or a Windows-only script.",
    "clone_failed": "The repository could not be cloned: it is gone, the clone timed out, or git exited with an error.",
    "harness_error": "The harness itself failed to produce a result for this repository; treat the row as unknown.",
}
REASON_VOCAB = {
    "exit_0": "The build command exited 0.",
    "no_build_step_needed": "A static web page with nothing to compile.",
    "notes_only": "No build files and fewer than three source files by extension; the repository holds notes, not a buildable tree.",
    "sources_without_build_files": "Source files are present but no build file was found down to three directory levels.",
    "no_recognized_build_files_in_root": "No recognized build files in the repository root (first-run vocabulary; the root only was searched).",
    "windows_msbuild": "The only build system is a Visual Studio solution or project (.sln or .vcxproj), which needs MSBuild.",
    "windows_script": "The only build entry is a build.bat, build.ps1 or .cmd script, which needs Windows.",
    "xcode": "The only build system is an Xcode project, which needs macOS.",
    "premake_or_scons": "The build is driven by Premake or SCons, which the harness does not run.",
    "zig_not_installed": "The build needs the Zig toolchain, which is not installed on the runner.",
    "android_gradle": "An Android project without a Gradle wrapper, which the runner cannot build.",
    "gradle_wrapper_missing": "A Gradle project whose wrapper script is missing from the repository.",
    "repo_gone": "The repository returned HTTP 404, 410 or 451; it has been removed, hidden or taken down.",
    "clone_timeout": "The clone did not finish within its five-minute limit.",
    "git_exit_N": "git exited with code N during the clone; the log tail says why.",
    "missing_assets": "The build needs a base ROM, the original game, game files, or a generated or extracted input that the harness never supplies.",
    "missing_toolchain": "The build needs a console SDK, a cross compiler, MSVC, Direct3D headers, Zig, Emscripten, CUDA, or another compiler or linker that is not installed.",
    "missing_dependency": "CMake, pkg-config or Meson could not find a package, a header is missing, or the build files point at a directory or source file that is not there.",
    "compile_error": "A compiler, rustc, MSVC or linker error line appears in the log.",
    "unclassified": "None of the reason patterns matched; the log has to be read by hand.",
}


def strip_title(t):
    if not t:
        return t
    t = t.strip()
    if t.endswith(TITLE_SUFFIX):
        t = t[: -len(TITLE_SUFFIX)].rstrip()
    return t


def normalize_repo(url):
    if not isinstance(url, str):
        return None
    m = URL_RE.match(url.strip())
    if not m:
        return None
    host, owner, repo = m.groups()
    return f"https://{host}/{owner}/{repo}"


def model_family(model):
    m = (model or "").strip().lower()
    if not m:
        return "not reported"
    if "claude" in m or "anthropic" in m:
        return "Claude"
    if "gpt" in m or "codex" in m or "openai" in m:
        return "OpenAI"
    return "other"


def short_commit(c):
    if not c or not isinstance(c, str):
        return None
    return c[:7]


def parse_date(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def commit_bucket(last_commit_date, as_of):
    d = parse_date(last_commit_date)
    if d is None:
        return "unknown"
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    age = (as_of - d.astimezone(datetime.timezone.utc)).days
    if age <= 30:
        return "within 30 days"
    if age <= 90:
        return "31 to 90 days"
    if age <= 365:
        return "91 to 365 days"
    return "older than a year"


COMMIT_BUCKETS = ["within 30 days", "31 to 90 days", "91 to 365 days", "older than a year", "unknown"]
FAMILIES = ["Claude", "OpenAI", "other", "not reported"]


def harness_commit():
    try:
        out = subprocess.run(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def load_projects(path):
    with open(path) as fh:
        projects = json.load(fh)
    if not isinstance(projects, list):
        sys.exit("projects file must be a JSON array")
    by_slug = {}
    by_repo = {}
    for p in projects:
        if p.get("slug"):
            by_slug[p["slug"]] = p
        for r in p.get("repos") or []:
            n = normalize_repo(r)
            if n:
                by_repo.setdefault(n.lower(), p)
    return projects, by_slug, by_repo


def load_batches(batches_dir):
    """id -> slug, from every batch file. Missing directory is fine."""
    out = {}
    for f in sorted(glob.glob(os.path.join(batches_dir, "*.json"))):
        try:
            with open(f) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(data, list):
            continue
        for e in data:
            if isinstance(e, dict) and e.get("id") and e.get("slug"):
                out.setdefault(e["id"], e["slug"])
    return out


def source_block(projects):
    outcomes = collections.Counter((p.get("outcome") or "").strip() for p in projects)
    with_repo = sum(1 for p in projects if any(normalize_repo(r) for r in (p.get("repos") or [])))
    return {
        "name": "reversedwithai.com",
        "url": SOURCE_URL,
        "fetched": None,  # filled from --fetched
        "listed": len(projects),
        "by_outcome": {k: outcomes.get(k, 0) for k in OUTCOMES},
        "with_repo": with_repo,
        "without_repo": len(projects) - with_repo,
    }


def build_row(r, id_to_slug, by_slug, by_repo):
    rid = r.get("id")
    repo = r.get("repo")
    project = None
    slug = id_to_slug.get(rid)
    if slug:
        project = by_slug.get(slug)
    if project is None and repo:
        n = normalize_repo(repo)
        if n:
            project = by_repo.get(n.lower())
    model = (project or {}).get("model")
    model = model if isinstance(model, str) and model.strip() else None
    title = strip_title(r.get("title")) or strip_title((project or {}).get("title")) or repo
    return {
        "id": rid,
        "title": title,
        "repo": repo,
        "platform": r.get("platform") or (project or {}).get("platform") or None,
        "model": model,
        "model_family": model_family(model),
        "outcome_reported": r.get("outcome_reported") or (project or {}).get("outcome") or None,
        "result": r.get("result"),
        "reason": r.get("reason"),
        "reason_detail": r.get("reason_detail"),
        "missing_names": list(r.get("missing_names") or []),
        "build_system": r.get("build_system"),
        "build_dir": r.get("build_dir"),
        "submodules": r.get("submodules"),
        "retries": list(r.get("retries") or []),
        "commit": short_commit(r.get("commit")),
        "last_commit_date": r.get("last_commit_date"),
        "duration_seconds": r.get("duration_seconds"),
        "run_id": r.get("run_id"),
    }


def pct(part, whole):
    return round(100.0 * part / whole, 1) if whole else 0.0


def group_summary(rows, as_of):
    n = len(rows)
    results = collections.Counter(r["result"] or "unknown" for r in rows)
    reasons = collections.Counter(
        f'{r["result"]}/{r["reason"]}' for r in rows if r["result"] not in REPRODUCIBLE
    )
    reproducible = sum(1 for r in rows if r["result"] in REPRODUCIBLE)
    names = collections.Counter(x for r in rows for x in r["missing_names"])
    retries = collections.Counter(x for r in rows for x in r["retries"])
    fam = collections.Counter(r["model_family"] for r in rows)
    fam_by_result = {f: collections.Counter() for f in FAMILIES}
    for r in rows:
        fam_by_result[r["model_family"]][r["result"] or "unknown"] += 1
    buckets = collections.Counter(commit_bucket(r["last_commit_date"], as_of) for r in rows)
    return {
        "n": n,
        "results": dict(results.most_common()),
        "reasons": dict(reasons.most_common()),
        "reproducible": reproducible,
        "reproducible_pct": pct(reproducible, n),
        "build_dir_below_root": sum(1 for r in rows if r["build_dir"] not in (None, "", ".")),
        "submodules_failed": sum(1 for r in rows if r["submodules"] == "failed"),
        "retries": dict(retries.most_common()),
        "missing_names": [{"name": k, "count": v} for k, v in names.most_common(15)],
        "model_family": {f: fam.get(f, 0) for f in FAMILIES},
        "model_family_by_result": {
            f: dict(sorted(fam_by_result[f].items(), key=lambda kv: -kv[1])) for f in FAMILIES
        },
        "last_commit_date": {b: buckets.get(b, 0) for b in COMMIT_BUCKETS},
    }


def vocabulary(rows):
    results = {}
    reasons = {}
    for r in rows:
        res = r["result"]
        if res and res not in results:
            results[res] = RESULT_VOCAB.get(res, "Not defined in the README; see the harness.")
        rea = r["reason"]
        if rea and rea not in reasons:
            m = re.match(r"^git_exit_(\d+)$", rea)
            if rea in REASON_VOCAB:
                reasons[rea] = REASON_VOCAB[rea]
            elif m:
                reasons[rea] = f"git exited with code {m.group(1)} during the clone; the log tail says why."
            else:
                reasons[rea] = "Not defined in the README; see the harness."
    # Always carry the full README vocabulary so a reader can see the values that did not occur.
    for k, v in RESULT_VOCAB.items():
        results.setdefault(k, v)
    for k, v in REASON_VOCAB.items():
        if k != "git_exit_N" or not any(x.startswith("git_exit_") for x in reasons):
            reasons.setdefault(k, v)
    return {"result": results, "reason": reasons}


def sort_key(r):
    order = {o: i for i, o in enumerate(OUTCOMES)}
    return (order.get(r["outcome_reported"], len(OUTCOMES)), r["id"] or "")


def markdown(doc):
    L = []
    s = doc["source"]
    L.append(f"# AI-ported games: does it build? ({doc['as_of']})\n")
    L.append(f"Source: {s['name']} ({s['url']}), {s['listed']} projects listed, {s['with_repo']} with a repository, "
             f"{s['without_repo']} without. Reported outcomes: " + ", ".join(f"{k} {v}" for k, v in s["by_outcome"].items()) + ".\n")
    m = doc["method"]
    L.append(f"Method: {m['runner']}, {m['budget_minutes']}-minute build budget, harness {m['harness_url']} at commit `{m['harness_commit']}`.\n")
    for key in list(OUTCOMES) + ["all", "controls"]:
        g = doc["summary"].get(key)
        if not g:
            continue
        L.append(f"\n## {key}: {g['n']} repositories\n")
        L.append(f"Reproducible (built + static_web): {g['reproducible']} ({g['reproducible_pct']}%). "
                 f"Build dir below root: {g['build_dir_below_root']}. Submodules failed: {g['submodules_failed']}.\n")
        L.append("| result | count | percent |\n|---|---|---|")
        for k, v in g["results"].items():
            L.append(f"| {k} | {v} | {pct(v, g['n'])}% |")
        L.append("")
        if g["reasons"]:
            L.append("| result/reason | count |\n|---|---|")
            for k, v in g["reasons"].items():
                L.append(f"| {k} | {v} |")
            L.append("")
        if g["missing_names"]:
            L.append("Missing names (top 15): " + ", ".join(f"{x['name']} ({x['count']})" for x in g["missing_names"]) + "\n")
        if g["retries"]:
            L.append("Retries: " + ", ".join(f"{k} {v}" for k, v in g["retries"].items()) + "\n")
        L.append("| model family | n | " + " | ".join(g["results"].keys()) + " |")
        L.append("|---|---|" + "---|" * len(g["results"]))
        for f in FAMILIES:
            row = g["model_family_by_result"][f]
            L.append(f"| {f} | {g['model_family'][f]} | " + " | ".join(str(row.get(k, 0)) for k in g["results"].keys()) + " |")
        L.append("")
        L.append("| last commit | count |\n|---|---|")
        for k, v in g["last_commit_date"].items():
            L.append(f"| {k} | {v} |")
        L.append("")
    L.append("\n## Per repository\n")
    L.append("| id | title | reported | result | reason | detail | build dir | last commit |\n|---|---|---|---|---|---|---|---|")
    for r in doc["rows"]:
        detail = (r["reason_detail"] or "")[:80].replace("|", "\\|")
        title = (r["title"] or "").replace("|", "\\|")
        L.append(f"| {r['id']} | [{title}]({r['repo']}) | {r['outcome_reported']} | {r['result']} | {r['reason']} | {detail} | {r['build_dir'] or ''} | {(r['last_commit_date'] or '')[:10]} |")
    L.append("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--projects", required=True)
    ap.add_argument("--results", nargs="+", required=True)
    ap.add_argument("--as-of", required=True, help="YYYY-MM-DD")
    ap.add_argument("--out", required=True)
    ap.add_argument("--markdown", help="optional summary.md path")
    ap.add_argument("--batches", default=os.path.join(REPO_ROOT, "batches"), help="batch directory for id -> slug")
    ap.add_argument("--fetched", default=None, help="date the project list was scraped (default: file mtime of --projects)")
    a = ap.parse_args()

    try:
        as_of = datetime.datetime.strptime(a.as_of, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        sys.exit("--as-of must be YYYY-MM-DD")

    projects, by_slug, by_repo = load_projects(a.projects)
    id_to_slug = load_batches(a.batches)

    raw = []
    for f in a.results:
        with open(f) as fh:
            data = json.load(fh)
        if not isinstance(data, list):
            sys.exit(f"{f}: expected a JSON array")
        raw += data

    rows = [build_row(r, id_to_slug, by_slug, by_repo) for r in raw]
    seen = set()
    for r in rows:
        if r["id"] in seen:
            print(f"warning: duplicate id {r['id']}", file=sys.stderr)
        seen.add(r["id"])
    rows.sort(key=sort_key)

    src = source_block(projects)
    if a.fetched:
        src["fetched"] = a.fetched
    else:
        src["fetched"] = datetime.datetime.fromtimestamp(os.path.getmtime(a.projects), datetime.timezone.utc).strftime("%Y-%m-%d")

    summary = {}
    for o in OUTCOMES:
        grp = [r for r in rows if r["outcome_reported"] == o]
        if grp:
            summary[o] = group_summary(grp, as_of)
    listed = [r for r in rows if r["outcome_reported"] in OUTCOMES]
    summary["all"] = group_summary(listed, as_of)
    controls = [r for r in rows if r["outcome_reported"] not in OUTCOMES]
    if controls:
        # Control repositories (not on the source list) are kept in rows but out of "all".
        summary["controls"] = group_summary(controls, as_of)

    doc = {
        "as_of": a.as_of,
        "schema_version": SCHEMA_VERSION,
        "source": src,
        "method": {
            "runner": RUNNER,
            "budget_minutes": BUDGET_MINUTES,
            "harness_url": HARNESS_URL,
            "harness_commit": harness_commit(),
            "vocabulary": vocabulary(rows),
        },
        "summary": summary,
        "rows": rows,
    }

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(f"{a.out}: {len(rows)} rows; reproducible all {summary['all']['reproducible']}/{summary['all']['n']} "
           f"({summary['all']['reproducible_pct']}%)")
    if a.markdown:
        os.makedirs(os.path.dirname(os.path.abspath(a.markdown)), exist_ok=True)
        with open(a.markdown, "w") as fh:
            fh.write(markdown(doc))
        print(f"{a.markdown}: written")


if __name__ == "__main__":
    main()
