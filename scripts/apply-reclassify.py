#!/usr/bin/env python3
"""Re-run the classifier over the kept log tails and write results-final.json beside each results.json.
Rule: the runner classified the full log; the artifact keeps only the tail. So a reclassification is
applied only when it finds a reason (never to turn a runner reason into 'unclassified'), and only for
rows whose runner reason was unclassified or compile_error, where under-matching was observed.
Every changed row records reason_source = 'reclassified' and keeps the runner's original in reason_runner."""
import json, glob, sys, os, subprocess
sys.path.insert(0, os.path.dirname(__file__)); import classify
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))).stdout.strip()
for path in sys.argv[1:]:
    d = os.path.dirname(path); rows = json.load(open(path)); changed = 0
    for r in rows:
        r.setdefault("reason_source", "runner")
        if r.get("result") != "build_failed" or r.get("reason") not in ("unclassified", "compile_error"): continue
        logs = glob.glob(f"{d}/**/{r['id']}.log", recursive=True)
        if not logs: continue
        reason, detail, names = classify.classify(open(logs[0], errors="replace").read())
        if reason != "unclassified" and reason != r.get("reason"):
            r["reason_runner"] = r.get("reason"); r["reason"] = reason; r["reason_detail"] = detail
            if names and not r.get("missing_names"): r["missing_names"] = names
            r["reason_source"] = f"reclassified@{commit}"; changed += 1
    out = os.path.join(d, "results-final.json"); json.dump(rows, open(out, "w"), indent=1)
    print(f"{path}: {len(rows)} rows, {changed} reclassified -> {out}")
