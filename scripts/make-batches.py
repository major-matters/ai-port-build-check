#!/usr/bin/env python3
"""Turn data/projects.json into batch files the workflow can dispatch.

Input: a JSON array of objects with fields
    slug, title, platform, outcome, model, repos (array of URLs)

Output (under batches/):
    works.json, partial.json, research.json   one entry per project with a repo
    control.json                              only if any project is marked Control
    other.json                                only if an outcome is unrecognized
    all.json                                  every entry, in one file
    no-repo.json                              projects skipped because no usable repo

Each entry: {id, repo, title, platform, outcome, slug}. Ids are w001, p001,
r001, c001 (controls) in input order. Only the FIRST usable repo URL per
project is checked.

Usage:
    python3 scripts/make-batches.py [--input data/projects.json] [--outdir batches]
"""
import argparse
import json
import os
import re
import sys

PREFIX = {"works": "w", "partial": "p", "research": "r", "control": "c"}
HOSTS = ("github.com", "gitlab.com", "codeberg.org")
URL_RE = re.compile(r"^https?://(?:www\.)?(github\.com|gitlab\.com|codeberg\.org)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/.*)?$")


def normalize_outcome(value):
    v = (value or "").strip().lower()
    if v.startswith("work"):
        return "works"
    if v.startswith("partial"):
        return "partial"
    if v.startswith("research") or v.startswith("study"):
        return "research"
    if v.startswith("control"):
        return "control"
    return "other"


def normalize_repo(url):
    """Return a canonical https://host/owner/repo URL, or None if unusable."""
    if not isinstance(url, str):
        return None
    m = URL_RE.match(url.strip())
    if not m:
        return None
    host, owner, repo = m.groups()
    return f"https://{host}/{owner}/{repo}"


def first_repo(repos):
    for r in repos or []:
        norm = normalize_repo(r)
        if norm:
            return norm
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="data/projects.json")
    ap.add_argument("--outdir", default="batches")
    args = ap.parse_args()

    with open(args.input) as fh:
        projects = json.load(fh)
    if not isinstance(projects, list):
        sys.exit("input must be a JSON array")

    buckets = {k: [] for k in ("works", "partial", "research", "control", "other")}
    counters = {k: 0 for k in buckets}
    no_repo = []

    for p in projects:
        repo = first_repo(p.get("repos"))
        if not repo:
            no_repo.append({
                "slug": p.get("slug"),
                "title": p.get("title"),
                "outcome": p.get("outcome"),
                "repos_listed": p.get("repos") or [],
            })
            continue
        bucket = normalize_outcome(p.get("outcome"))
        counters[bucket] += 1
        prefix = PREFIX.get(bucket, "x")
        buckets[bucket].append({
            "id": f"{prefix}{counters[bucket]:03d}",
            "repo": repo,
            "title": p.get("title") or p.get("slug") or repo,
            "platform": p.get("platform") or "",
            "outcome": p.get("outcome") or "",
            "slug": p.get("slug") or "",
        })

    os.makedirs(args.outdir, exist_ok=True)

    def write(name, data):
        path = os.path.join(args.outdir, name)
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        print(f"{path}: {len(data)}")

    write("works.json", buckets["works"])
    write("partial.json", buckets["partial"])
    write("research.json", buckets["research"])
    if buckets["control"]:
        write("control.json", buckets["control"])
    if buckets["other"]:
        write("other.json", buckets["other"])
    write("all.json", buckets["works"] + buckets["partial"] + buckets["research"] + buckets["control"] + buckets["other"])
    write("no-repo.json", no_repo)

    ids = [e["id"] for b in buckets.values() for e in b]
    assert len(ids) == len(set(ids)), "duplicate ids"


if __name__ == "__main__":
    main()
