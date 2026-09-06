#!/usr/bin/env python3
"""brain_index - the SQLite backing store for recall: one file, two engines.

The file-scan recall in brain_bm25.py re-reads and re-tokenizes every note on every query
(fine for a few hundred files, slow past a couple thousand). This module builds and maintains
<vault>/.index/brain.db instead: `files` (one row per note, sha-hashed so an unchanged file is
never re-read), `chunks` (one row per section - BM25 tokens, a 600-char excerpt, the BGE-M3
vector as a BLOB) and `chunks_fts` (an FTS5 shadow of the BM25 tokens, for fast candidate
retrieval). A section is the same unit brain_bm25._sections() and brain_embed.chunk_file()
already agree on, so one table serves both the sparse and the dense engine.

brain_bm25.search() takes this path automatically when BRAIN_INDEX=sqlite is set (see
brain_index_search.py for the actual query, which reuses brain_bm25's own scoring formula -
FTS5 only narrows the candidate set). brain_searchd.py and brain_search.py read the `embedding`
column directly for the dense side. Any failure here should never break recall: `update` is
called by the write hook so an unchanged file costs one hash comparison, not a re-embed.

Usage: brain_index.py build [--embed] | update [--embed] | stats
  build   - full rebuild (drops the existing DB first)
  update  - incremental: only files whose sha changed since the last run are touched
  --embed - also encode any chunk missing a vector (needs the embed extras, see requirements.txt)
  stats   - print row counts and file size
"""
import os, sys, json, struct, sqlite3, pathlib, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain_bm25 as bm
import brain_embed as be

DB = be.INDEX_DIR / "brain.db"
ROOTS = list(be.ROOTS) + [(bm.WIKI, "wiki")]
SCHEMA = """
CREATE TABLE IF NOT EXISTS files (rel TEXT PRIMARY KEY, root TEXT, note TEXT, sha TEXT, hint TEXT, dord INTEGER,
  sup INTEGER, w REAL, project TEXT, mtime REAL, indexed_at TEXT DEFAULT (datetime('now','localtime')));
CREATE TABLE IF NOT EXISTS chunks (id INTEGER PRIMARY KEY, rel TEXT NOT NULL REFERENCES files(rel) ON DELETE CASCADE,
  chunk_id INTEGER, heading TEXT, text600 TEXT, ctx_tok TEXT, name_tok TEXT, hw REAL, embed_text TEXT, embedding BLOB);
CREATE INDEX IF NOT EXISTS idx_chunks_rel ON chunks(rel);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(ctx_tok, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 0');
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);"""


def md_files():
    """Same filter brain_embed._corpus() used to apply, plus the wiki root: (root, tag, path, rel)."""
    for root, tag in ROOTS:
        if not root.exists():
            continue
        for p in root.rglob("*.md"):
            parts = p.relative_to(root).parts
            if any(x.startswith(".") for x in parts) or "_drafts" in parts or "_archive" in parts or p.name == "MEMORY.md":
                continue
            try:
                if "noindex: true" in p.read_text(encoding="utf-8", errors="ignore")[:2000]:
                    continue  # frontmatter opt-out: this note never enters recall
            except OSError:
                continue
            yield root, tag, p, f"{tag}/{p.relative_to(root)}"


def file_rows(text, f, tag):
    """One file's `files` row plus its `chunks` rows (embedding filled in separately)."""
    hint, date, sup, w = bm._meta(text)
    dord = bm._date_ord(date)
    tokens_all = bm._toks(text[:20000])
    frow = (tag, f.stem, be.sha(text), hint, dord, int(sup), w, bm.note_project(text, tokens_all, f.stem), f.stat().st_mtime)
    crows = []
    for i, ((h, b), (_, etext)) in enumerate(zip(bm._sections(text), be.chunk_file(text))):
        hw = max(w, bm.W_MAP["lesson"]) if bm.MARK.search(h) else w
        ctx = (f.stem + " " + h + " " + hint + " " + b)[:4000]
        crows.append((i, h, b[:600], " ".join(bm._toks(ctx)), " ".join(set(bm._toks(f.stem + " " + h + " " + hint))), hw, etext))
    return frow, crows


def old_vectors():
    """One-time migration: embeddings.jsonl (retired) -> {(rel, chunk_id, text): BLOB}, if it still exists."""
    out = {}
    if be.EMB_FILE.exists():
        for line in be.EMB_FILE.read_text().splitlines():
            if line.strip():
                e = json.loads(line)
                if "vector" in e:
                    out[(e["path"], e["chunk_id"], e["text"])] = struct.pack(f"{len(e['vector'])}f", *e["vector"])
    return out


def sync(full=False, embed=False):
    t0 = time.time(); DB.parent.mkdir(parents=True, exist_ok=True)
    if full and DB.exists():
        DB.unlink()
    con = sqlite3.connect(DB); con.execute("PRAGMA foreign_keys=ON"); con.executescript(SCHEMA)
    have = dict(con.execute("SELECT rel, sha FROM files"))
    vecs = {(r, c, t): v for r, c, t, v in con.execute("SELECT rel, chunk_id, embed_text, embedding FROM chunks WHERE embedding IS NOT NULL")}
    if not vecs:
        vecs = old_vectors()
    seen, changed = set(), 0
    for root, tag, f, rel in md_files():
        seen.add(rel); text = f.read_text(encoding="utf-8", errors="ignore")
        if have.get(rel) == be.sha(text):
            continue  # sha unchanged -> don't even re-tokenize (keeps incremental updates cheap)
        frow, crows = file_rows(text, f, tag)
        changed += 1
        con.execute("DELETE FROM chunks WHERE rel=?", (rel,))
        con.execute("INSERT OR REPLACE INTO files(rel,root,note,sha,hint,dord,sup,w,project,mtime) VALUES (?,?,?,?,?,?,?,?,?,?)", (rel,) + frow)
        for c in crows:
            v = vecs.get((rel, c[0], c[6]))
            con.execute("INSERT INTO chunks(rel,chunk_id,heading,text600,ctx_tok,name_tok,hw,embed_text,embedding) VALUES (?,?,?,?,?,?,?,?,?)", (rel,) + c + (v,))
    gone = [r for r in have if r not in seen and not (r.startswith("imem/") and not r.startswith(be.IMEM_TAG + "/"))]  # another instance's own imem rows are left alone
    for r in gone:
        con.execute("DELETE FROM files WHERE rel=?", (r,))
    # missing = every vectorless vault/memory chunk in the DB right now, not just the ones this pass touched -
    # so an interrupted or partial embed run is topped up on the next call instead of staying stuck.
    # The shared docs root (BRAIN_WIKI_DIR) is embedded too since 6 Sep 2026: it used to be BM25-only, which
    # meant dense recall never saw it and its hits came back labelled as if they were vault notes. Set
    # BRAIN_WIKI_EMBED=0 to keep a very large docs tree out of the encoder (it stays searchable by BM25).
    wiki_filter = "" if os.environ.get("BRAIN_WIKI_EMBED", "1") != "0" else " AND f.root!='wiki'"
    missing = con.execute("SELECT c.id, c.embed_text FROM chunks c JOIN files f ON f.rel=c.rel WHERE c.embedding IS NULL" + wiki_filter).fetchall()
    if missing and not embed and be.EMB_FILE.exists():  # migration window: an old jsonl on disk can still supply a vector
        jv = old_vectors(); fill = [(rid, t) for rid, t in missing if any(k[2] == t for k in jv)]
        for rid, t in fill:
            rel_c = con.execute("SELECT rel, chunk_id FROM chunks WHERE id=?", (rid,)).fetchone()
            v = jv.get((rel_c[0], rel_c[1], t))
            if v is not None:
                con.execute("UPDATE chunks SET embedding=? WHERE id=?", (v, rid)); missing = [m for m in missing if m[0] != rid]
    if missing and embed:
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer(be.MODEL_NAME, device="cpu")
        new = list(zip(missing, model.encode([t for _, t in missing], normalize_embeddings=True, batch_size=16)))
        for (rid, _), v in new:
            con.execute("UPDATE chunks SET embedding=? WHERE id=?", (struct.pack(f"{len(v)}f", *v), rid))
        print(dedup_report(con, new), flush=True); missing = []
    con.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
    n, avgdl = con.execute("SELECT count(*), avg(length(ctx_tok) - length(replace(ctx_tok,' ',''))+1) FROM chunks").fetchone()
    con.execute("INSERT OR REPLACE INTO meta VALUES ('avgdl',?)", (str(avgdl or 0),))
    con.execute("INSERT OR REPLACE INTO meta VALUES ('synced_at',?)", (time.strftime("%Y-%m-%d %H:%M:%S"),))
    con.commit(); con.close()
    print(f"brain.db: {len(seen)} files ({changed} changed, {len(gone)} removed) - {n} chunks - missing embeddings: {len(missing)}"
          + (" (run with --embed to fill in)" if missing else "") + f" - {time.time()-t0:.1f}s")


def dedup_report(con, new, thr=0.90, top=3):
    """brain_embed's old dedup_report, ported to the DB: warn when a freshly-embedded chunk is a
    near-duplicate (>= thr cosine) of an existing chunk in a DIFFERENT file - the usual sign of a
    note copy-pasted instead of linked, or the same lesson written down twice under different names."""
    import numpy as np
    rows = con.execute("SELECT id, rel, heading, embedding FROM chunks WHERE embedding IS NOT NULL").fetchall()
    ids = {r[0]: (r[1], r[2]) for r in rows}; mat = np.vstack([np.frombuffer(r[3], dtype="float32") for r in rows]); rel_of = np.array([r[1] for r in rows])
    hits, seen = [], set()
    for (rid, _), v in new:
        rel = ids[rid][0]; sims = mat @ np.asarray(v, dtype="float32"); sims[rel_of == rel] = -1
        j = int(sims.argmax())
        if sims[j] >= thr and (rel, rows[j][1]) not in seen:
            seen.add((rel, rows[j][1])); hits.append((float(sims[j]), rel, rows[j][1], rows[j][2] or ""))
    hits.sort(reverse=True)
    return (" | DEDUP possible-duplicate: " + " . ".join(f"{a} ~{s:.2f} {b}#{h[:30]}" for s, a, b, h in hits[:top])) if hits else ""


def stats():
    con = sqlite3.connect(DB)
    print("files", con.execute("SELECT count(*) FROM files").fetchone()[0], "- chunks", con.execute("SELECT count(*) FROM chunks").fetchone()[0],
          "- embedded", con.execute("SELECT count(*) FROM chunks WHERE embedding IS NOT NULL").fetchone()[0],
          "- roots", dict(con.execute("SELECT root, count(*) FROM files GROUP BY root")), "- meta", dict(con.execute("SELECT k, v FROM meta")),
          "- size", f"{DB.stat().st_size/1e6:.1f} MB")


if __name__ == "__main__":
    a = sys.argv[1:]; cmd = a[0] if a else "update"
    if cmd == "build":
        sync(full=True, embed="--embed" in a)
    elif cmd == "update":
        sync(full=False, embed="--embed" in a)
    elif cmd == "stats":
        stats()
    else:
        sys.exit(__doc__)
