#!/usr/bin/env python3
"""Re-run the reason classifier (scripts/classify.py + reason-patterns.json) over an existing
results.json and its logs/ directory, and print the before/after reason tally for build_failed rows.
Nothing is written. Usage:
  python3 -I scripts/reclassify.py results/works/results.json [--show]
"""
import collections, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify  # noqa: E402


def main(argv):
    if not argv:
        print(__doc__); return 2
    show = "--show" in argv
    paths = [a for a in argv if not a.startswith("--")]
    pats = classify.load_patterns()
    before, after, moves = collections.Counter(), collections.Counter(), collections.Counter()
    for path in paths:
        rows = json.load(open(path))
        logs = os.path.join(os.path.dirname(path), "logs")
        for r in rows:
            if r.get("result") != "build_failed":
                continue
            log_path = os.path.join(logs, f"{r['id']}.log")
            text = open(log_path, errors="replace").read() if os.path.exists(log_path) else ""
            reason, detail, names = classify.classify(text, pats)
            old = r.get("reason") or "?"
            before[old] += 1; after[reason] += 1; moves[(old, reason)] += 1
            if show:
                print(f"{r['id']:6} {old:19} -> {reason:19} {detail or ''}  names={names}")
    n = sum(before.values())
    print(f"\nbuild_failed rows: {n}")
    print("before:", dict(before.most_common()))
    print("after: ", dict(after.most_common()))
    print("moves:")
    for (o, a), c in sorted(moves.items(), key=lambda kv: -kv[1]):
        print(f"  {o:19} -> {a:19} {c}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
