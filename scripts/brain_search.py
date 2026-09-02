#!/usr/bin/env python3
"""brain_search - local semantic search over the vault, two stages (BGE-M3 -> reranker).

This is the heavier counterpart to brain_bm25.py: run it by hand when keyword recall misses
and you need meaning-match. Requires an index built by brain_embed.py. Fully local (CPU),
no API key. Models are cached at module level so repeated calls in one process are cheap.

Usage: brain_search.py "query" [-k 5] [--no-rerank]
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_EMBED_MODEL .
       BRAIN_RERANK_MODEL . BRAIN_RETRIEVE_K (candidates fed to the reranker)
"""
import os, sys, pathlib

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
EMB_MODEL = os.environ.get("BRAIN_EMBED_MODEL", "BAAI/bge-m3")
RERANK_MODEL = os.environ.get("BRAIN_RERANK_MODEL", "BAAI/bge-reranker-v2-m3")
RETRIEVE_K = int(os.environ.get("BRAIN_RETRIEVE_K", "20"))
EMB_FILE = VAULT / ".index" / "brain.db"

_CACHE = {}   # entries / matrix / embedder / cross-encoder - loaded once per process


def _entries():
    """Reads brain_index.py's SQLite index directly (chunks.embedding, one row per section)."""
    if "entries" not in _CACHE:
        import sqlite3, numpy as np
        ent = []
        if EMB_FILE.exists():
            with sqlite3.connect(f"file:{EMB_FILE}?mode=ro", uri=True) as c:
                for rel, note, heading, cid, text, blob in c.execute(
                        "SELECT c.rel, f.note, c.heading, c.chunk_id, c.embed_text, c.embedding "
                        "FROM chunks c JOIN files f ON f.rel = c.rel WHERE c.embedding IS NOT NULL ORDER BY c.id"):
                    ent.append({"path": rel, "note": note, "heading": heading or "", "chunk_id": cid,
                               "text": text or "", "vector": np.frombuffer(blob, dtype="float32")})
        _CACHE["entries"] = ent
    return _CACHE["entries"]


def search(query, k=6, rerank=True):
    """-> [{note, heading, path, text, score, cos}]. Local models, CPU."""
    import numpy as np
    entries = _entries()
    if not entries:
        return []
    mat = _CACHE.get("mat")
    if mat is None:
        mat = np.array([e["vector"] for e in entries], dtype="float32"); _CACHE["mat"] = mat
    if "emb" not in _CACHE:
        from sentence_transformers import SentenceTransformer
        _CACHE["emb"] = SentenceTransformer(EMB_MODEL, device="cpu")
    q = np.array(_CACHE["emb"].encode([query], normalize_embeddings=True)[0], dtype="float32")
    cos = mat @ q
    cand = cos.argsort()[::-1][:RETRIEVE_K]
    if rerank:
        if "ce" not in _CACHE:
            from sentence_transformers import CrossEncoder
            _CACHE["ce"] = CrossEncoder(RERANK_MODEL, device="cpu")
        logits = np.array(_CACHE["ce"].predict([(query, entries[i]["text"]) for i in cand]),
                          dtype="float32")
        rs = 1.0 / (1.0 + np.exp(-logits))
        order = rs.argsort()[::-1]
        ranked = [(cand[j], float(rs[j]), float(cos[cand[j]])) for j in order][:k]
    else:
        ranked = [(i, float(cos[i]), float(cos[i])) for i in cand[:k]]
    out = []
    for idx, score, c in ranked:
        e = entries[idx]
        out.append({"note": e["note"], "heading": e.get("heading", ""), "path": e["path"],
                    "text": e["text"], "score": score, "cos": c})
    return out


def main():
    args = list(sys.argv[1:])
    k, rerank = 5, True
    if "--no-rerank" in args:
        rerank = False; args.remove("--no-rerank")
    if "-k" in args:
        i = args.index("-k"); k = int(args[i + 1]); del args[i:i + 2]
    query = " ".join(args).strip()
    if not query:
        print('usage: brain_search.py "query" [-k N] [--no-rerank]'); sys.exit(1)
    if not EMB_FILE.exists():
        print(f"no index at {EMB_FILE} - run brain_index.py build --embed first"); sys.exit(1)
    res = search(query, k=k, rerank=rerank)
    label = "rerank" if rerank else "cosine"
    print(f"\nquery: {query}   [{label}, retrieve={RETRIEVE_K}]\n" + "=" * 64)
    for rank, r in enumerate(res, 1):
        extra = f"  (cos {r['cos']:.3f})" if rerank else ""
        print(f"\n{rank}. [{r['score']:.3f}]{extra} {r['note']}  >  {r['heading']}")
        print(f"   {r['path']}\n   {' '.join(r['text'].split())[:150]}...")


if __name__ == "__main__":
    main()
