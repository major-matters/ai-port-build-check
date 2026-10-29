#!/usr/bin/env python3
"""Export the runtime smoke results as a dataset.

Reads one or more results.json files from a smoke run (rows carry a `smoke` object), joins the
build-pass fields that matter (reported outcome, build system, asset signals from the README),
and writes a JSON dataset plus an optional markdown summary.

  python3 scripts/export-smoke.py --results results/smoke/results.json --as-of 2026-10-29 \
      --out ../site/public/data/ai-ports-smoke.json --markdown summary.md
"""
import argparse, collections, json, sys

OUTCOME_LABEL = {
    "window_opened_kept_running": "opened a window and kept running",
    "window_opened_exited_clean": "opened a window, then exited cleanly",
    "kept_running_no_window": "kept running, no window",
    "exited_clean": "exited cleanly",
    "exited_asking_for_files": "exited asking for files",
    "exited_with_error": "exited with an error",
    "crashed": "crashed",
    "no_executable_found": "built nothing that can be launched",
    "not_built": "did not build this time",
    "smoke_error": "smoke step failed",
}
# Outcomes that count as "runs": the program stayed up or showed a window without the player's files.
RUNS = {"window_opened_kept_running", "window_opened_exited_clean", "kept_running_no_window"}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", nargs="+", required=True)
    ap.add_argument("--as-of", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--markdown")
    a = ap.parse_args()
    rows = []
    for f in a.results:
        with open(f) as fh:
            rows += json.load(fh)
    out_rows = []
    for r in rows:
        s = r.get("smoke") or {}
        outcome = s.get("outcome") or ("not_built" if r.get("result") != "built" else "smoke_error")
        bs = r.get("build_system")
        # Builds that cannot produce a native program are their own bucket, not a failure of the program.
        if outcome == "no_executable_found" and bs in ("python", "npm", "none"):
            bucket = "no_native_program"
        else:
            bucket = outcome
        out_rows.append({
            "id": r["id"], "repo": r["repo"], "title": r.get("title"), "platform": r.get("platform"),
            "outcome_reported": r.get("outcome_reported"), "build_system": bs,
            "build_result": r.get("result"), "build_seconds": r.get("duration_seconds"),
            "readme_needs_assets": bool(r.get("needs_assets")), "asset_signals": r.get("asset_signals") or [],
            "smoke_outcome": outcome, "bucket": bucket,
            "runs_without_player_files": outcome in RUNS,
            "executable": s.get("executable"), "candidates": len(s.get("candidates") or []),
            "exit_code": s.get("exit_code"), "timed_out": s.get("timed_out"), "seconds_alive": s.get("seconds_alive"),
            "windows": s.get("windows") or [], "asked_for_files": bool(s.get("asked_for_files")),
            "mentioned_files": s.get("mentioned_files") or [],
            "stderr_tail": (s.get("stderr_tail") or [])[-6:],
            "run_id": r.get("run_id"), "checked_at": r.get("checked_at"),
        })
    out_rows.sort(key=lambda x: x["id"])
    by_bucket = collections.Counter(x["bucket"] for x in out_rows)
    by_outcome = {}
    for x in out_rows:
        by_outcome.setdefault(x["outcome_reported"] or "unknown", collections.Counter())[x["bucket"]] += 1
    native = [x for x in out_rows if x["bucket"] != "no_native_program" and x["build_result"] == "built"]
    runs = [x for x in native if x["runs_without_player_files"]]
    asks = [x for x in native if x["bucket"] == "exited_asking_for_files"]
    data = {
        "as_of": a.as_of, "schema_version": 1,
        "method": "Every repository that built in the clean-room pass was built again on a fresh GitHub-hosted runner, then the most likely executable the build produced was launched under a virtual X display with dummy audio and no game files present, for at most 45 seconds. After 20 seconds the harness counted X windows. The exit code, the window list, and the last lines of output decide the outcome. No paid or proprietary file was supplied; the question is what a player sees before adding their own copy of the game.",
        "summary": {
            "rows": len(out_rows), "built_again": sum(1 for x in out_rows if x["build_result"] == "built"),
            "native_programs": len(native), "runs_without_player_files": len(runs),
            "runs_pct_of_native": round(100 * len(runs) / len(native), 1) if native else None,
            "asked_for_files": len(asks),
            "by_bucket": dict(by_bucket), "by_reported_outcome": {k: dict(v) for k, v in by_outcome.items()},
            "readme_says_needs_assets": sum(1 for x in out_rows if x["readme_needs_assets"]),
        },
        "bucket_labels": {**OUTCOME_LABEL, "no_native_program": "builds a package or a web app, nothing to launch natively"},
        "rows": out_rows,
    }
    with open(a.out, "w") as fh:
        json.dump(data, fh, indent=1)
    if a.markdown:
        s = data["summary"]
        lines = [f"# Smoke run, as of {a.as_of}", "", f"Rows: {s['rows']}; built again: {s['built_again']}; native programs: {s['native_programs']}; run without the player's files: {s['runs_without_player_files']} ({s['runs_pct_of_native']} percent of native); exited asking for files: {s['asked_for_files']}.", "", "| bucket | count |", "|---|---|"]
        for k, v in sorted(by_bucket.items(), key=lambda kv: -kv[1]):
            lines.append(f"| {k} | {v} |")
        lines += ["", "| id | repo | reported | build | bucket | exe | windows | exit | mentioned files |", "|---|---|---|---|---|---|---|---|---|"]
        for x in out_rows:
            lines.append(f"| {x['id']} | {x['repo'].replace('https://github.com/','')} | {x['outcome_reported']} | {x['build_system']} | {x['bucket']} | {x['executable'] or ''} | {len(x['windows'])} | {x['exit_code']} | {', '.join(x['mentioned_files'][:4])} |")
        with open(a.markdown, "w") as fh:
            fh.write("\n".join(lines) + "\n")
    print(json.dumps(data["summary"], indent=1))

if __name__ == "__main__":
    main()
