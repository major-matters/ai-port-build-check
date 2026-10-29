#!/usr/bin/env python3
"""Classify a build log into a build_failed reason, using scripts/reason-patterns.json.

This is the only place the reason regexes are evaluated. detect-and-build.sh calls it on
the runner, reclassify.py imports it locally, so the two always agree.

CLI:
  python3 -I classify.py --log /tmp/build.log            -> JSON {reason, reason_detail, missing_names}
  python3 -I classify.py --log /tmp/build.log --trigger sdl3   -> exit 0 if the sdl3 trigger matches, else 1
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATTERNS_PATH = os.path.join(HERE, "reason-patterns.json")
DETAIL_MAX = 160
NAMES_MAX = 6


def load_patterns(path=PATTERNS_PATH):
    with open(path) as fh:
        return json.load(fh)


def clean_log(text):
    """Drop the harness's own lines; they quote asset phrases and would self-match."""
    return "\n".join(line for line in text.splitlines() if not line.startswith("[harness]"))


def _squash(s):
    return re.sub(r"\s+", " ", s).strip()[:DETAIL_MAX]


def classify(text, patterns=None):
    """Return (reason, reason_detail, missing_names) for a build log string."""
    p = patterns or load_patterns()
    log = clean_log(text)
    reason, detail = "unclassified", None
    for group in p["priority"]:
        for pat in p["reasons"][group]:
            m = re.search(pat, log, re.IGNORECASE)
            if m:
                reason, detail = group, _squash(m.group(0))
                break
        if detail is not None:
            break

    names = []
    hits = []  # (position, name)
    for spec in p["missing_names"]:
        flags = 0 if spec.get("flags") == "" else re.IGNORECASE
        for m in re.finditer(spec["pattern"], log, flags):
            hits.append((m.start(), m.group(spec.get("group", 1))))
    for pat, name in p["toolchain_names"].items():
        m = re.search(pat, log, re.IGNORECASE)
        if m:
            hits.append((m.start(), name))
    for _, name in sorted(hits):
        name = name.strip().rstrip(".,;:'\")")
        if name and name not in names:
            names.append(name)
        if len(names) >= NAMES_MAX:
            break
    return reason, detail, names


def trigger(text, name, patterns=None):
    p = patterns or load_patterns()
    log = clean_log(text)
    return any(re.search(pat, log, re.IGNORECASE) for pat in p["triggers"][name])


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--trigger", choices=sorted(load_patterns()["triggers"].keys()))
    a = ap.parse_args(argv)
    with open(a.log, errors="replace") as fh:
        text = fh.read()
    if a.trigger:
        return 0 if trigger(text, a.trigger) else 1
    reason, detail, names = classify(text)
    print(json.dumps({"reason": reason, "reason_detail": detail, "missing_names": names}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
