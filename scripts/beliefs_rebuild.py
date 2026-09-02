#!/usr/bin/env python3
"""beliefs_rebuild.py - the belief layer: source of truth is knowledge/beliefs.md (plain
markdown, tracked in git); <vault>/.index/beliefs.db is a derived, disposable rebuild of it.
Every call re-reads the ledger, rebuilds the table from scratch, and carries an existing
embedding over untouched when its claim text has not changed (so a rebuild never re-runs the
encoder unless something was actually added or edited). The contradiction check is deterministic
- same topic plus an opposed status - not a similarity threshold; embeddings only back
`suggest-topic`, which is advisory.

A belief is not a decision record. Decision records are the episodic layer - what happened, in
what order, with what reasoning. A belief is one distilled, falsifiable claim pulled out of that
history, carrying its own status so a later session can ask "is this still true" without
re-reading every record that ever touched the topic. See docs/BELIEFS.md.

Usage: beliefs_rebuild.py [rebuild] [--embed] | report | check | suggest-topic "<claim>"
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_EMBED_MODEL (default BAAI/bge-m3)
"""
import os, re, sys, sqlite3, struct, pathlib
from collections import defaultdict

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
MODEL_NAME = os.environ.get("BRAIN_EMBED_MODEL", "BAAI/bge-m3")
LEDGER = VAULT / "knowledge" / "beliefs.md"
DB = VAULT / ".index" / "beliefs.db"
STATUS = {"active", "expected", "confirmed", "falsified", "superseded", "pending"}
EVIDENCE = {"canon", "decision", "measurement", "observation", "lesson", "assumption"}
SCHEMA = f"""
CREATE TABLE beliefs (
  id INTEGER PRIMARY KEY, source_file TEXT NOT NULL, claim TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ({','.join(repr(s) for s in sorted(STATUS))})),
  evidence_type TEXT NOT NULL CHECK(evidence_type IN ({','.join(repr(e) for e in sorted(EVIDENCE))})),
  valid_from TEXT, superseded_by INTEGER REFERENCES beliefs(id), topic TEXT, note TEXT,
  recorded_at TEXT NOT NULL DEFAULT (datetime('now','localtime')), embedding BLOB);
CREATE INDEX idx_beliefs_status ON beliefs(status);
CREATE INDEX idx_beliefs_source ON beliefs(source_file);
CREATE INDEX idx_beliefs_topic ON beliefs(topic);"""
HEAD = re.compile(r"^## B(\d{3,}) · (.+?)\s*$")
META = re.compile(r"^- status: (\S+) · evidence: (\S+) · from: (\S+) · superseded_by: (\S+)\s*$")


def parse_ledger():
    """Read the ledger line by line -> (records, errors) - errors are what `check` reports."""
    recs, errs, cur = [], [], None
    for n, line in enumerate(LEDGER.read_text().splitlines(), 1):
        m = HEAD.match(line)
        if m:
            cur = {"id": int(m.group(1)), "topic": m.group(2), "line": n}
            recs.append(cur)
            continue
        if cur is None or not line.startswith("- "):
            continue
        m = META.match(line)
        if m:
            st, ev, vf, sb = m.groups()
            cur.update(status=st, evidence=ev, valid_from=None if vf == "-" else vf,
                       superseded_by=None if sb == "-" else int(sb.lstrip("B")))
            continue
        key, _, val = line[2:].partition(": ")
        if key in ("src", "claim", "note"):
            cur[key] = None if val.strip() == "-" else val.strip()
    ids = [r["id"] for r in recs]
    for r in recs:
        for k in ("status", "evidence", "src", "claim"):
            if not r.get(k):
                errs.append(f"B{r['id']:03d} (line {r['line']}): missing '{k}'")
        if r.get("status") not in STATUS:
            errs.append(f"B{r['id']:03d}: unknown status '{r.get('status')}'")
        if r.get("evidence") not in EVIDENCE:
            errs.append(f"B{r['id']:03d}: unknown evidence type '{r.get('evidence')}'")
        if r.get("superseded_by") and r["superseded_by"] not in ids:
            errs.append(f"B{r['id']:03d}: superseded_by B{r['superseded_by']:03d} is not in the ledger")
    dup = {i for i in ids if ids.count(i) > 1}
    if dup:
        errs.append("duplicate id: " + ", ".join(f"B{i:03d}" for i in sorted(dup)))
    return recs, errs


def old_embeddings():
    """claim -> embedding from the previous DB, so an unchanged claim is never re-encoded."""
    if not DB.exists():
        return {}
    try:
        with sqlite3.connect(DB) as c:
            return dict(c.execute("SELECT claim, embedding FROM beliefs WHERE embedding IS NOT NULL"))
    except sqlite3.Error:
        return {}


def rebuild(embed=False):
    recs, errs = parse_ledger()
    if errs:
        sys.exit("LEDGER HAS ERRORS, db not written:\n  " + "\n  ".join(errs))
    keep = old_embeddings()
    tmp = DB.with_suffix(".db.tmp")
    tmp.unlink(missing_ok=True)
    DB.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(tmp) as c:
        c.executescript(SCHEMA)
        for r in recs:
            c.execute("INSERT INTO beliefs(id,source_file,claim,status,evidence_type,valid_from,"
                      "superseded_by,topic,note,embedding) VALUES (?,?,?,?,?,?,?,?,?,?)",
                      (r["id"], r["src"], r["claim"], r["status"], r["evidence"], r["valid_from"],
                       r["superseded_by"], r["topic"], r.get("note"), keep.get(r["claim"])))
        missing = c.execute("SELECT id, claim FROM beliefs WHERE embedding IS NULL").fetchall()
        if missing and embed:
            from sentence_transformers import SentenceTransformer
            vecs = SentenceTransformer(MODEL_NAME, device="cpu").encode(
                [cl for _, cl in missing], normalize_embeddings=True)
            for (bid, _), v in zip(missing, vecs):
                c.execute("UPDATE beliefs SET embedding=? WHERE id=?", (struct.pack(f"{len(v)}f", *v), bid))
            missing = []
    tmp.replace(DB)
    print(f"beliefs.db rebuilt: {len(recs)} beliefs, {len(missing)} missing an embedding"
          + ("" if not missing else " (run with --embed to fill them in)"))


def report():
    """Deterministic contradiction/evolution report: same topic + opposed status; multiple
    simultaneously-active beliefs on one topic are flagged for a human to look at, not resolved."""
    with sqlite3.connect(DB) as c:
        rows = c.execute("SELECT id,claim,status,topic,valid_from FROM beliefs ORDER BY id").fetchall()
    by = defaultdict(list)
    for r in rows:
        by[r[3]].append(r)
    print("=== CONTRADICTION / EVOLUTION (by topic) ===")
    for tp, items in sorted(by.items()):
        sts = {r[2] for r in items}
        flag = ""
        if sts & {"active", "confirmed"} and sts & {"superseded", "falsified"}:
            flag = "EVOLVED/RESOLVED-CONTRADICTION"
        elif "active" in sts and "expected" in sts:
            flag = "ACTIVE+EXPECTED (watch this one)"
        if flag:
            print(f"\n[{flag}] {tp}")
            for r in sorted(items, key=lambda x: x[4] or ""):
                print(f"  B{r[0]:03d} ({r[2]}, {r[4]}): {r[1][:88]}")
    print("\n=== SAME TOPIC, MULTIPLE ACTIVE (needs a human look) ===")
    for tp, items in sorted(by.items()):
        act = [r for r in items if r[2] == "active"]
        if len(act) >= 2:
            print(f"  {tp}: " + " . ".join(f"B{r[0]:03d}" for r in act))
    print(f"\nbeliefs={len(rows)} topics={len(by)}")


def suggest_topic(claim):
    """The 3 closest existing topics for a new claim - a suggestion only, the call is human."""
    import numpy as np
    from sentence_transformers import SentenceTransformer
    q = SentenceTransformer(MODEL_NAME, device="cpu").encode([claim], normalize_embeddings=True)[0]
    with sqlite3.connect(DB) as c:
        rows = c.execute("SELECT id,topic,embedding FROM beliefs WHERE embedding IS NOT NULL").fetchall()
    scored = sorted(((float(np.dot(q, np.frombuffer(e, dtype="f4"))), t, i) for i, t, e in rows), reverse=True)
    for s, t, i in scored[:3]:
        print(f"{s:.3f}  {t}  (B{i:03d})")


if __name__ == "__main__":
    a = sys.argv[1:]
    cmd = a[0] if a and not a[0].startswith("--") else "rebuild"
    if cmd == "rebuild":
        rebuild(embed="--embed" in a)
    elif cmd == "report":
        report()
    elif cmd == "check":
        recs, errs = parse_ledger()
        print("\n".join(errs) if errs else f"ledger is clean: {len(recs)} beliefs")
        sys.exit(1 if errs else 0)
    elif cmd == "suggest-topic" and len(a) > 1:
        suggest_topic(a[1])
    else:
        sys.exit(__doc__)
