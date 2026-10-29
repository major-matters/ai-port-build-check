#!/usr/bin/env python3
"""Merge a rerun's results into a base smoke results.json, replacing rows by id, and copy its logs.

  python3 scripts/merge-smoke.py --base results/smoke --rerun results/smoke-rerun-7
"""
import argparse, json, os, shutil

ap = argparse.ArgumentParser()
ap.add_argument("--base", required=True)
ap.add_argument("--rerun", required=True)
a = ap.parse_args()
base = json.load(open(os.path.join(a.base, "results.json")))
rerun = json.load(open(os.path.join(a.rerun, "results.json")))
by = {r["id"]: r for r in rerun}
replaced = []
out = []
for r in base:
    if r["id"] in by:
        out.append(by[r["id"]]); replaced.append(r["id"])
    else:
        out.append(r)
for r in rerun:
    if r["id"] not in {x["id"] for x in base}:
        out.append(r)
json.dump(out, open(os.path.join(a.base, "results.json"), "w"), indent=2)
logs_src, logs_dst = os.path.join(a.rerun, "logs"), os.path.join(a.base, "logs")
copied = 0
if os.path.isdir(logs_src):
    os.makedirs(logs_dst, exist_ok=True)
    for f in os.listdir(logs_src):
        shutil.copy2(os.path.join(logs_src, f), os.path.join(logs_dst, f)); copied += 1
print(f"replaced {len(replaced)} rows ({', '.join(replaced)}); {len(out)} rows total; {copied} logs copied")
