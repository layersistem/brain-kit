#!/usr/bin/env python3
"""brain_index_search - brain_bm25.search()'s SQLite/FTS5 path.

Same output shape, same scoring formula as brain_bm25.py: FTS5 only narrows the candidate set
(an OR-query over the tokens, capped at CAND rows); the actual score is brain_bm25's own BM25
(k1/b, idf) times its entity/recency/superseded/weight/usage/age multipliers, computed from the
token strings brain_index.py already stored per chunk. That keeps this path rank-identical to
the file-scan one it replaces - verify with a side-by-side run if you change either formula.

Entry point: brain_bm25.search() calls into this module when BRAIN_INDEX=sqlite is set. Falls
back to [] (which brain_bm25.py then turns into a plain file-scan) if brain.db does not exist.
"""
import os, re, math, sqlite3
from collections import Counter
import brain_bm25 as bm
import brain_embed as be

DB = be.INDEX_DIR / "brain.db"
CAND = 200


def _df(con, term):
    return con.execute("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH ?", (f'"{term}"',)).fetchone()[0]


def _display_root(root):
    return "memory" if root.startswith(("memory", "imem")) else root


def search(query, k=5, k1=1.5, b=0.75):
    q = [bm.stem(t) for t in re.findall(r"[a-z0-9]+", query.translate(bm._TR).lower()) if t not in bm.STOP]
    qset = set(q)
    if not q or not DB.exists():
        return []
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    N = con.execute("SELECT count(*) FROM chunks").fetchone()[0]
    avgdl = float(con.execute("SELECT v FROM meta WHERE k='avgdl'").fetchone()[0] or 1)
    dmin, dmax = con.execute("SELECT min(dord), max(dord) FROM files WHERE dord IS NOT NULL").fetchone()
    drange = (dmax - dmin) if dmin is not None and dmax != dmin else 1
    tod = bm._date_ord(bm.datetime.date.today().isoformat())
    ap = bm.active_project()
    df = {t: _df(con, t) for t in qset}
    idf = {t: math.log(1 + (N - df[t] + 0.5) / (df[t] + 0.5)) for t in qset}
    match = " OR ".join(f'"{t}"' for t in qset if df[t])
    if not match:
        return []
    rows = con.execute(
        "SELECT c.id, c.rel, c.chunk_id, c.heading, c.text600, c.ctx_tok, c.name_tok, c.hw, f.root, f.note, f.hint, f.dord, f.sup, f.project "
        "FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN files f ON f.rel = c.rel "
        "WHERE chunks_fts MATCH ? AND (f.root NOT LIKE 'imem/%' OR f.root = ?) ORDER BY chunks_fts.rank LIMIT ?",
        (match, be.IMEM_TAG, CAND)).fetchall()
    scored = []
    for cid, rel, chunk_id, h, text600, ctx_tok, name_tok, hw, root, note, hint, dord, sup, project in rows:
        if ap and project not in (ap, "general"):
            continue
        toks = ctx_tok.split(); tf = Counter(toks); dl = len(toks); s = 0.0
        for t in q:
            if t in tf:
                s += idf[t] * tf[t] * (k1 + 1) / (tf[t] + k1 * (1 - b + b * dl / avgdl))
        if s <= 0:
            continue
        name = set(name_tok.split()); tag = _display_root(root)
        ent = sum(1 for t in (qset & name) if idf[t] >= 2.0)
        s *= (1 + bm.ENT_W * ent)
        if dord and tag != "memory":
            s *= (1 + bm.REC_W * (dord - dmin) / drange)
        if sup:
            s *= bm.SUP_W
        s *= hw
        uc = bm._USE.get(os.path.basename(rel), 0)
        if uc:
            s *= 1 + 0.15 * min(1.0, math.log1p(uc) / math.log1p(5))
        if dord and tag != "memory" and hw <= 1.0:
            s *= max(bm.AGE_FLOOR, 1 - bm.AGE_W * (tod - dord) / 372)
        scored.append((s, {"root": tag, "note": note, "heading": h, "path": f"{tag}/{os.path.basename(rel)}",
                           "score": round(s, 2), "hint": hint, "text": text600, "tok": toks}))
    scored.sort(key=lambda x: -x[0])
    seen, uniq = set(), []
    for s, d in scored:
        if d["note"] in seen:
            continue
        seen.add(d["note"]); uniq.append(d)
        if len(uniq) >= k:
            break
    if uniq:  # min-relevance gate, identical to brain_bm25.search()
        tt = set(uniq[0]["tok"]); rare = [t for t in qset & tt if df[t] > 0 and idf[t] >= 2.0]
        if len(qset & tt) / max(len(qset), 1) < 0.45 and len(rare) < 2:
            return []
    for d in uniq:
        d.pop("tok", None)
    return uniq


if __name__ == "__main__":
    import sys, json
    print(json.dumps(search(sys.argv[1] if len(sys.argv) > 1 else "", int(sys.argv[2]) if len(sys.argv) > 2 else 5), ensure_ascii=False))
