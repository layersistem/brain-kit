#!/usr/bin/env python3
"""brain_recall - hybrid recall: BM25 (in-process, brain_bm25) + BGE-M3 dense (brain_searchd daemon over HTTP,
short timeout) fused with reciprocal-rank fusion. Same JSON shape as brain_bm25.py, so the hook needs no change
beyond pointing at this file. If the daemon is down or slow the result is plain BM25 - recall never breaks.

Usage: brain_recall.py "<query>" [k]
Env:   BRAIN_SEARCHD_URL (http://127.0.0.1:8799) . BRAIN_SEARCHD_TIMEOUT (0.3 s) . BRAIN_MEMORY2 (scope slug)
       BRAIN_DENSE_MIN (0.62: dense may answer alone when BM25 is empty only above this cosine)
       BRAIN_DENSE_JOIN (0.55: dense hits below this do not enter the fusion)
Measured on a 15-query set (author's vault): BM25 hit@1 0.80 / MRR 0.89 -> hybrid 0.87 / 0.93."""
import os, sys, json, pathlib, urllib.request, urllib.parse
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import brain_bm25 as bm

URL = os.environ.get("BRAIN_SEARCHD_URL", "http://127.0.0.1:8799")
TIMEOUT = float(os.environ.get("BRAIN_SEARCHD_TIMEOUT", "0.3"))
DENSE_MIN = float(os.environ.get("BRAIN_DENSE_MIN", "0.62"))
DENSE_JOIN = float(os.environ.get("BRAIN_DENSE_JOIN", "0.55"))
SCOPE = pathlib.Path(os.environ.get("BRAIN_MEMORY2", "/x/y")).parent.name   # must match brain_embed's IMEM_TAG
RRF_K = 60


def dense(q, k):
    """Dense hits from the daemon; any error or timeout -> [] (silent)."""
    try:
        u = f"{URL}/search?" + urllib.parse.urlencode({"q": q, "k": k, "scope": SCOPE})
        with urllib.request.urlopen(u, timeout=TIMEOUT) as r:
            return json.load(r)
    except Exception:
        return []


def fuse(sparse, dens, k):
    """Reciprocal-rank fusion; fields merged (hint from BM25, cosine from dense)."""
    sc, item = {}, {}
    for lst, tag in ((sparse, "bm25"), (dens, "dense")):
        for i, r in enumerate(lst):
            n = r["note"]
            sc[n] = sc.get(n, 0.0) + 1.0 / (RRF_K + i + 1)
            cur = item.setdefault(n, dict(r))
            if tag == "bm25":
                cur.update({kk: r[kk] for kk in ("hint", "heading", "path", "text", "root") if kk in r})
                cur["bm25"] = r.get("score")
            else:
                cur["cos"] = r.get("score")
                cur.setdefault("hint", "")
    out = []
    for n, s in sorted(sc.items(), key=lambda x: -x[1])[:k]:
        it = item[n]
        src = ("b" if it.get("bm25") is not None else "") + ("d" if it.get("cos") is not None else "")
        it["score"] = f"{round(s * 100, 1)}{src}"    # e.g. "3.3bd" = found by both engines
        out.append(it)
    return out


def recall(q, k=5):
    sparse = bm.search(q, k * 2)
    dens = dense(q, k * 2)
    if not dens:
        return sparse[:k]
    top = dens[0].get("score", 0.0)
    if not sparse:
        return dens[:k] if top >= DENSE_MIN else []     # BM25 empty: dense rescues only when confident
    dens = [r for r in dens if r.get("score", 0.0) >= DENSE_JOIN]
    return fuse(sparse, dens, k) if dens else sparse[:k]


if __name__ == "__main__":
    q = sys.argv[1] if len(sys.argv) > 1 else ""
    k = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    print(json.dumps(recall(q, k) if q else [], ensure_ascii=False))
