#!/usr/bin/env python3
"""brain_recall - hybrid recall: BM25 (in-process, brain_bm25) + BGE-M3 dense (brain_searchd daemon over HTTP,
short timeout) fused with reciprocal-rank fusion. Same JSON shape as brain_bm25.py, so the hook needs no change
beyond pointing at this file. If the daemon is down or slow the result is plain BM25 - recall never breaks.

Usage: brain_recall.py "<query>" [k]
Env:   BRAIN_SEARCHD_URL (http://127.0.0.1:8799) . BRAIN_SEARCHD_TIMEOUT (0.8 s) . BRAIN_MEMORY2 (scope slug)
       BRAIN_DENSE_MIN (0.62: dense may answer alone when BM25 is empty only above this cosine)
       BRAIN_DENSE_JOIN (0.55: dense hits below this do not enter the fusion)
Measured on a 15-query set (author's vault): BM25 hit@1 0.80 / MRR 0.89 -> hybrid 0.87 / 0.93.
Telemetry: every daemon call appends one line to <claude-dir>/brain-kit-state/dense_calls.log
(epoch|ok/miss|ms|error-class|instance) - the only way a silent BM25 fallback becomes measurable."""
import os, sys, json, time, pathlib, urllib.request, urllib.parse
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import brain_bm25 as bm

URL = os.environ.get("BRAIN_SEARCHD_URL", "http://127.0.0.1:8799")
# 0.3 s was measured too tight (6 Sep 2026): a warm query answers in 90-100 ms, but while the write hook
# is embedding (10-14 s of CPU per note, several sessions on one machine) the daemon answered in 311 ms and
# silently lost the dense half. 0.8 s costs nothing on a quiet machine and keeps hybrid recall under contention.
TIMEOUT = float(os.environ.get("BRAIN_SEARCHD_TIMEOUT", "0.8"))
DENSE_MIN = float(os.environ.get("BRAIN_DENSE_MIN", "0.62"))
DENSE_JOIN = float(os.environ.get("BRAIN_DENSE_JOIN", "0.55"))
SCOPE = pathlib.Path(os.environ.get("BRAIN_MEMORY2", "/x/y")).parent.name   # must match brain_embed's IMEM_TAG
RRF_K = 60


_BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(_BRAIN_ROOT / "vault"))).resolve()


def daemon_serves_my_vault():
    """True only if the daemon on URL reports the same vault this recall runs against.
    Two installs on one machine share the default port; without this check the second install
    quietly returned the first one's notes (isolated-install test, 2026-09-03). Older daemons
    that report no `vault` field are trusted (single-install, pre-fix)."""
    try:
        with urllib.request.urlopen(f"{URL}/health", timeout=TIMEOUT) as r:
            h = json.load(r)
    except Exception:
        return False
    v = h.get("vault")
    return v is None or pathlib.Path(v).resolve() == VAULT


def _dense_log(ok, ms, why=""):
    """One line per daemon call. Before this, a timeout was invisible: recall just came back BM25-only and
    the hook's warning was the only trace, counted nowhere. ~50 bytes per call; never breaks recall."""
    try:
        p = pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))) / "brain-kit-state"
        p.mkdir(parents=True, exist_ok=True)
        with open(p / "dense_calls.log", "a") as f:
            f.write("%d|%s|%d|%s|%s\n" % (int(time.time()), "ok" if ok else "miss", ms, why[:40],
                                          os.environ.get("BRAIN_INSTANCE", "?")))
    except Exception:
        pass


def dense(q, k):
    """Dense hits from the daemon; any error, timeout or foreign-vault daemon -> [] (silent, but logged)."""
    if not daemon_serves_my_vault():
        _dense_log(False, 0, "foreign-or-down")
        return []
    t0 = time.time()
    try:
        u = f"{URL}/search?" + urllib.parse.urlencode({"q": q, "k": k, "scope": SCOPE})
        with urllib.request.urlopen(u, timeout=TIMEOUT) as r:
            out = json.load(r)
        _dense_log(True, (time.time() - t0) * 1000)
        return out
    except Exception as e:
        _dense_log(False, (time.time() - t0) * 1000, type(e).__name__)
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


def single(lst, k, tag, dense_answered=False):
    """One engine's own results, relabelled onto fuse()'s scale (same RRF-rank score plus an engine
    letter) instead of that engine's raw score (a BM25 score can be in the thousands; a bare cosine
    looks like a dense hit even when it was never fused). This way a caller reading the "score"
    field can always tell which engine(s) answered from the trailing letter alone - including the
    case where the dense daemon never answered at all, which the hook uses to warn about that.
    `dense_answered` separates "the daemon replied but nothing cleared the cosine gate" (normal for a
    short or chatty prompt) from "the daemon never replied" - the hook must only warn on the latter."""
    out = []
    for i, r in enumerate(lst[:k]):
        it = dict(r)
        it["bm25" if tag == "b" else "cos"] = r.get("score")
        it["score"] = f"{round(100.0 / (RRF_K + i + 1), 1)}{tag}"
        if dense_answered:
            it["dense_answered"] = True
        out.append(it)
    return out


def recall(q, k=5):
    sparse = bm.search(q, k * 2)
    dens = dense(q, k * 2)
    if not dens:
        return single(sparse, k, "b")
    top = dens[0].get("score", 0.0)
    if not sparse:
        return single(dens, k, "d") if top >= DENSE_MIN else []  # BM25 empty: dense rescues only when confident
    dens = [r for r in dens if r.get("score", 0.0) >= DENSE_JOIN]
    return fuse(sparse, dens, k) if dens else single(sparse, k, "b", dense_answered=True)


def wiki_pull(q, out, k=40):
    """Trust order (7 Sep 2026): shared docs (BRAIN_WIKI_DIR) rank above notes for *how the system works*
    questions. If the fused top-k carries no docs hit, the best docs hit is appended anyway (flagged
    `wiki_pull`), provided it ranks within BRAIN_RECALL_WIKI_PULL_RANK (default 10) of either engine —
    so a marginally relevant doc is surfaced as a pointer, an irrelevant one is not. The hook prints it in
    its own SOURCE block. Case that motivated it: the right doc existed, recall showed only notes, a note
    carrying an inference was repeated as fact and cost a long correction. BM25 first (index, ~7 ms), dense
    second. Disable with BRAIN_RECALL_WIKI_PULL=0."""
    if os.environ.get("BRAIN_RECALL_WIKI_PULL", "1") != "1" or any(x.get("root") == "wiki" for x in out):
        return out
    if int(os.environ.get("RECALL_PROMPT_WORDS", "9") or 9) < 4:  # no docs-pull for one-word / chat prompts (an unrelated doc is worse than none)
        return out
    floor = int(os.environ.get("BRAIN_RECALL_WIKI_PULL_RANK", "10") or 10)
    for lst, tag in ((bm.search(q, k), "b"), (dense(q, k), "d")):
        for i, r in enumerate((lst or [])[:floor]):
            if r.get("root") == "wiki":
                it = dict(r); it["bm25" if tag == "b" else "cos"] = r.get("score")
                it["score"] = f"{round(100.0 / (RRF_K + i + 1), 1)}{tag}"; it["wiki_pull"] = True
                return out + [it]
    return out


if __name__ == "__main__":
    q = sys.argv[1] if len(sys.argv) > 1 else ""
    k = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    print(json.dumps(wiki_pull(q, recall(q, k)) if q else [], ensure_ascii=False))
