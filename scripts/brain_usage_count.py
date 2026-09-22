#!/usr/bin/env python3
"""brain_usage_count - count the notes the model actually opened, for BM25's usage reinforcement.

stdin: a PostToolUse hook payload. If `tool_name` is Read and `tool_input.file_path` is a markdown note
inside the vault or a memory root, `<vault>/.index/recall_counts.json[basename]` gains one: {"c": n, "ts": …}.
brain_bm25.py reads that file as a small, capped multiplier (USE_W / USE_CAP), so a note's own reading
history nudges its future rank.

Why it lives here (23 Sep 2026): until this file existed the counter was written by the renderer, which
counted *injections* - every note recall printed scored as "used", including the ones the model skipped.
Measured over 1529 prompt/read pairs on the author's install: notes sitting at the counter's cap accounted
for 71.7% of all injections and were opened 5.4% of the time, while notes below the cap were opened 8.3%
of the time. The reinforcement was pushing unread notes up. The multiplier is unchanged; what feeds it is.

Prints nothing (a PostToolUse stdout lands in the model's context) and always exits 0. flock plus an atomic
rename, because several sessions on one machine share the file. Standard library only.

Env: BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_MEMORY (<root>/memory) . BRAIN_MEMORY2
"""
import fcntl
import json
import os
import sys
import tempfile
import time

BRAIN_ROOT = os.path.expanduser(os.environ.get("BRAIN_ROOT", "~/brain"))
VAULT = os.path.abspath(os.path.expanduser(os.environ.get("BRAIN_DIR") or os.path.join(BRAIN_ROOT, "vault")))
COUNTS = os.path.join(VAULT, ".index", "recall_counts.json")
LOCK = os.path.join(VAULT, ".index", ".recall_counts.lock")
# The memory roots brain_bm25 indexes: the kit's own, and the per-project directory an agent CLI manages.
MEMORY = os.path.abspath(os.path.expanduser(os.environ.get("BRAIN_MEMORY") or os.path.join(BRAIN_ROOT, "memory")))
MEMORY2 = os.environ.get("BRAIN_MEMORY2") or ""
MEMORY2 = os.path.abspath(os.path.expanduser(MEMORY2)) if MEMORY2 else ""


def counted(fp):
    """True for a file the corpus contains: a .md note under the vault or a memory root, excluding the
    directories brain_bm25._corpus skips (hidden, _drafts, _archive) and the agent's own MEMORY.md index."""
    if not fp or not fp.lower().endswith(".md"):
        return False
    p = os.path.abspath(os.path.expanduser(fp))
    root = next((r for r in ([VAULT, MEMORY] + ([MEMORY2] if MEMORY2 else [])) if p.startswith(r + os.sep)), None)
    if root is None:
        return False
    rel = p[len(root) + 1:].split(os.sep)            # the same exclusions brain_bm25._corpus applies
    return not (any(x.startswith(".") for x in rel) or rel[-1] == "MEMORY.md"
                or "_drafts" in rel or "_archive" in rel)


def main():
    try:
        o = json.load(sys.stdin)
    except Exception:
        return
    if (o.get("tool_name") or "") != "Read":
        return
    fp = ((o.get("tool_input") or {}).get("file_path")) or ""
    if not counted(fp):
        return
    b = os.path.basename(os.path.abspath(os.path.expanduser(fp)))
    d = os.path.dirname(COUNTS)
    os.makedirs(d, exist_ok=True)
    with open(LOCK, "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            try:
                with open(COUNTS) as fh:
                    c = json.load(fh)
            except Exception:
                c = {}
            if not isinstance(c, dict):
                c = {}
            e = c.get(b) or {"c": 0}
            if not isinstance(e, dict):
                e = {"c": int(e or 0)}
            e["c"] = int(e.get("c", 0) or 0) + 1
            e["ts"] = int(time.time())
            c[b] = e
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".rc-")
            with os.fdopen(fd, "w") as fh:
                json.dump(c, fh, ensure_ascii=False)
            os.replace(tmp, COUNTS)
        finally:
            fcntl.flock(lk, fcntl.LOCK_UN)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
