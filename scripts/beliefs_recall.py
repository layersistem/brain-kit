#!/usr/bin/env python3
"""beliefs_recall.py - shows the active beliefs attached to whatever notes recall just surfaced,
plus a pointer to any belief on the same topic that has since evolved. Meant to be called from
the auto-retrieve hook right after it prints its recall block, so the question "is there an
active belief here, and does it contradict anything" reaches the model before it renders a
judgement - not after.

Input: argv = the recall paths just printed ("vault/<note>.md", "memory/<note>.md" ...); matched
by basename against the ledger's `src` field (decision/... or memory/...). Silent if there is no
DB or no match. Stdlib only - the hook invokes it with the system python3, not the kit's venv.

Usage: beliefs_recall.py <path> [<path> ...]
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault)
"""
import os, sys, sqlite3
from collections import defaultdict

BRAIN_ROOT = os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain"))
VAULT = os.environ.get("BRAIN_DIR", os.path.join(BRAIN_ROOT, "vault"))
DB = os.path.join(VAULT, ".index", "beliefs.db")
LIVE = ("active", "expected", "pending")
DEAD = ("superseded", "falsified")
MAX_LINES, PER_FILE, CLAIM_CH = 5, 2, 96


def main(paths):
    names = [os.path.basename(p) for p in paths if p]
    if not names or not os.path.exists(DB):
        return
    with sqlite3.connect(DB) as c:
        rows = c.execute("SELECT id, source_file, topic, status, claim FROM beliefs").fetchall()
    by_topic = defaultdict(list)
    for r in rows:
        by_topic[r[2]].append(r)
    hits, seen = [], set()
    for n in names:  # keep recall's own order - the most relevant note's beliefs come first
        mine = sorted((r for r in rows if os.path.basename(r[1]) == n and r[3] in LIVE), key=lambda r: -r[0])
        for r in mine[:PER_FILE]:
            if r[0] not in seen:
                seen.add(r[0]); hits.append(r)
    if not hits:
        return
    print("  BELIEF (active beliefs tied to what recall just surfaced; check before judging - knowledge/beliefs.md):")
    for bid, src, topic, status, claim in hits[:MAX_LINES]:
        cl = " ".join(claim.split())
        cl = cl[:CLAIM_CH] + ("..." if len(cl) > CLAIM_CH else "")
        others = [r for r in by_topic[topic] if r[0] != bid]
        act = [f"B{r[0]:03d}" for r in others if r[3] in LIVE]
        dead = [f"B{r[0]:03d}" for r in others if r[3] in DEAD]
        tail = []
        if act: tail.append("same topic active " + ",".join(act[:4]))
        if dead: tail.append("evolved/retracted " + ",".join(dead[:3]))
        print(f"    B{bid:03d} {status} [{topic}] {cl}" + (("  . " + " . ".join(tail)) if tail else ""))
    if len(hits) > MAX_LINES:
        print(f"    (+{len(hits) - MAX_LINES} more beliefs; search the ledger by src)")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:
        pass
