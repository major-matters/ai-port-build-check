#!/usr/bin/env python3
"""Summarize merged results.json files into the numbers the dataset page and the article use.
Usage: python3 scripts/analyze.py results/works/results.json [results/partial/results.json ...]
Strict asset signals only (the README scan over-matches "iso" and "rom").
Works on schema 1 and schema 2 results; schema 2 adds reason_detail, static_web, submodules, retries."""
import json, sys, collections, datetime
STRICT = {"baserom", "original game", "copy of the game", "game files", "legally obtained", "extract the assets", "retail"}
REPRODUCIBLE = {"built", "static_web"}
rows = []
for f in sys.argv[1:]:
    rows += json.load(open(f))
def strict_assets(r):
    sig = {s.lower() for s in (r.get("asset_signals") or [])}
    return bool(sig & STRICT) or r.get("reason") == "missing_assets"
by = collections.defaultdict(list)
for r in rows: by[r.get("outcome_reported") or "?"].append(r)
def table(rs, label):
    n = len(rs)
    res = collections.Counter(r["result"] for r in rs)
    reasons = collections.Counter(f'{r["result"]}/{r.get("reason")}' for r in rs if r["result"] not in REPRODUCIBLE)
    details = collections.Counter(f'{r.get("reason")}: {r["reason_detail"]}' for r in rs if r.get("reason_detail"))
    names = collections.Counter(x for r in rs for x in (r.get("missing_names") or []))
    retries = collections.Counter(x for r in rs for x in (r.get("retries") or []))
    bs = collections.Counter(r.get("build_system") or "none" for r in rs)
    dirs = sum(1 for r in rs if (r.get("build_dir") or ".") != ".")
    assets = sum(1 for r in rs if strict_assets(r))
    reproducible = sum(v for k, v in res.items() if k in REPRODUCIBLE)
    static_web = res.get("static_web", 0)
    sub_failed = sum(1 for r in rs if r.get("submodules") == "failed")
    stale = 0; dated = 0
    for r in rs:
        d = r.get("last_commit_date")
        if d:
            dated += 1
            age = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(d.replace("Z","+00:00"))).days
            if age > 90: stale += 1
    print(f"\n== {label}: {n} repositories ==")
    for k, v in res.most_common(): print(f"  {k:16} {v:4} ({100*v/n:.0f}%)")
    print(f"  reproducible (built + static_web): {reproducible} ({100*reproducible/n:.0f}%); static_web: {static_web}; submodules failed: {sub_failed}")
    print("  reasons:"); [print(f"    {k:40} {v}") for k, v in reasons.most_common()]
    if details:
        print("  reason_detail (top 15):"); [print(f"    {v:3}  {k[:120]}") for k, v in details.most_common(15)]
    if names:
        print("  missing_names:", dict(names.most_common(15)))
    if retries:
        print("  retries:", dict(retries.most_common()))
    print("  build systems:", dict(bs.most_common()), f"; build dir below root: {dirs}")
    print(f"  strict asset signals: {assets} ({100*assets/n:.0f}%); untouched >90 days: {stale} of {dated} dated")
    return res
for k in ["Works", "Partial", "Research"]:
    if by.get(k): table(by[k], k)
table(rows, "ALL")
