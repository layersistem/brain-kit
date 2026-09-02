#!/usr/bin/env python3
"""beliefs_merge.py - merge a batch of belief candidates into knowledge/beliefs.md.

Meant for a bulk extraction pass (a subagent reads a batch of decision records and proposes
candidate beliefs in the same ledger format, using a temporary "T01-01"-style id since it does
not know the ledger's current max id). This renumbers the batch from the ledger's current
max+1, rewrites any `superseded_by: T..` reference to the real `B###` id it resolved to, flags
duplicates and malformed rows, and only writes with --apply - the default is a dry-run preview.

Usage: beliefs_merge.py [--apply] [--skip T02-09,T03-04] batch-00.md batch-01.md ...
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault)
"""
import os, re, sys, pathlib
from collections import Counter

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
LEDGER = VAULT / "knowledge" / "beliefs.md"
HEAD = re.compile(r"^## (T\d{2}-\d{2}) · (.+?)\s*$")
META = re.compile(r"^- status: (\S+) · evidence: (\S+) · from: (\S+) · superseded_by: (\S+)\s*$")
STATUS = {"active", "expected", "confirmed", "falsified", "superseded", "pending"}
EVIDENCE = {"canon", "decision", "measurement", "observation", "lesson", "assumption"}
SRC_OK = re.compile(r"^(decision|knowledge|memory|moc)/")


def main():
    args = sys.argv[1:]
    apply = "--apply" in args
    skip = set(args[args.index("--skip") + 1].split(",")) if "--skip" in args else set()
    files = [a for a in args if a.endswith(".md")]

    recs, errs = [], []
    for f in files:
        cur = None
        for n, line in enumerate(pathlib.Path(f).read_text().splitlines(), 1):
            m = HEAD.match(line)
            if m:
                cur = {"tid": m.group(1), "topic": m.group(2).strip().lower(), "file": f, "line": n}
                recs.append(cur); continue
            if cur is None or not line.startswith("- "):
                continue
            m = META.match(line)
            if m:
                cur.update(status=m.group(1), evidence=m.group(2), vf=m.group(3), sb=m.group(4)); continue
            k, _, v = line[2:].partition(": ")
            if k in ("src", "claim", "note"):
                cur[k] = v.strip()

    recs = [r for r in recs if r["tid"] not in skip]
    existing = LEDGER.read_text() if LEDGER.exists() else "# Belief ledger\n"
    ex_claims = set(re.findall(r"^- claim: (.+)$", existing, re.M))
    ids = [int(x) for x in re.findall(r"^## B(\d+)", existing, re.M)]
    max_id = max(ids) if ids else 0
    tid2bid = {}
    for r in recs:
        for k in ("status", "evidence", "src", "claim"):
            if not r.get(k):
                errs.append(f"{r['tid']} ({r['file']}:{r['line']}): missing {k}")
        if r.get("status") not in STATUS:
            errs.append(f"{r['tid']}: unknown status '{r.get('status')}'")
        if r.get("evidence") not in EVIDENCE:
            errs.append(f"{r['tid']}: unknown evidence type '{r.get('evidence')}'")
        if r.get("claim") in ex_claims:
            errs.append(f"{r['tid']}: claim is already in the ledger")
        if not SRC_OK.match(r.get("src", "")):
            errs.append(f"{r['tid']}: suspicious src path: {r.get('src')}")
    for i, r in enumerate(recs, max_id + 1):
        tid2bid[r["tid"]] = i
    for r in recs:
        sb = r.get("sb", "-")
        if sb != "-":
            if sb.startswith("T"):
                if sb not in tid2bid:
                    errs.append(f"{r['tid']}: superseded_by {sb} is not in this batch")
                else:
                    r["sb"] = f"B{tid2bid[sb]:03d}"
            elif not re.match(r"^B\d{3}$", sb):
                errs.append(f"{r['tid']}: superseded_by '{sb}' is malformed")

    print(f"candidates {len(recs)} . skipped {len(skip)} . B{max_id+1:03d}-B{max_id+len(recs):03d}")
    print("status:", dict(Counter(r.get("status") for r in recs)), ". evidence:", dict(Counter(r.get("evidence") for r in recs)))
    print("topics:", len({r["topic"] for r in recs}), "distinct")
    if errs:
        print("ERRORS:\n  " + "\n  ".join(errs)); sys.exit(1)
    if not apply:
        print("(preview only; pass --apply to write)"); sys.exit(0)
    blocks = []
    for r in recs:
        bid = tid2bid[r["tid"]]
        blocks.append(f"## B{bid:03d} · {r['topic']}\n- status: {r['status']} · evidence: {r['evidence']} · from: {r['vf']} · superseded_by: {r['sb']}\n"
                      f"- src: {r['src']}\n- claim: {r['claim']}\n- note: {r.get('note') or '-'}\n")
    LEDGER.write_text(existing.rstrip("\n") + "\n\n" + "\n".join(blocks) + "\n")
    print(f"ledger updated: +{len(recs)} -> B{max_id+len(recs):03d}")


if __name__ == "__main__":
    main()
