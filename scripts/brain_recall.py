#!/usr/bin/env python3
"""brain_recall - hybrid recall: BM25 (in-process, brain_bm25) + BGE-M3 dense (brain_searchd daemon over HTTP,
short timeout) fused with reciprocal-rank fusion. Same JSON shape as brain_bm25.py, so the hook needs no change
beyond pointing at this file. If the daemon is down or slow the result is plain BM25 - recall never breaks.

Usage: brain_recall.py "<query>" [k]
Env:   BRAIN_SEARCHD_URL (http://127.0.0.1:8799) . BRAIN_SEARCHD_TIMEOUT (0.8 s) . BRAIN_MEMORY2 (scope slug)
       BRAIN_DENSE_MIN (0.62: dense may answer alone when BM25 is empty only above this cosine)
       BRAIN_DENSE_JOIN (0.55: dense hits below this do not enter the fusion)
       BRAIN_DENSE_Q_MAX (1500 chars: the query sent to the daemon is cut here - encode time is linear)
       BRAIN_RRF_RECENCY (0: freshness bonus on the fused score, measured worse - see the flag's comment)
Measured on a 15-query set (author's vault): BM25 hit@1 0.80 / MRR 0.89 -> hybrid 0.87 / 0.93.
Telemetry: every daemon call appends one line to <claude-dir>/brain-kit-state/dense_calls.log
(epoch|ok/miss|ms|error-class|instance) - the only way a silent BM25 fallback becomes measurable."""
import os, sys, json, time, pathlib, urllib.request, urllib.parse
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import brain_bm25 as bm
import brain_wiki as bw

URL = os.environ.get("BRAIN_SEARCHD_URL", "http://127.0.0.1:8799")
# 0.3 s was measured too tight (6 Sep 2026): a warm query answers in 90-100 ms, but while the write hook
# is embedding (10-14 s of CPU per note, several sessions on one machine) the daemon answered in 311 ms and
# silently lost the dense half. 0.8 s costs nothing on a quiet machine and keeps hybrid recall under contention.
TIMEOUT = float(os.environ.get("BRAIN_SEARCHD_TIMEOUT", "0.8"))
DENSE_MIN = float(os.environ.get("BRAIN_DENSE_MIN", "0.62"))
DENSE_JOIN = float(os.environ.get("BRAIN_DENSE_JOIN", "0.55"))
# Per-root fusion gate. 0.55 was measured on one vault; a docs root in another language or register can carry its
# gold at 0.50 and the dense hit then never enters the fusion. BRAIN_DENSE_JOIN_ROOTS="wiki=0.48,wiki2=0.50" gives
# each root tag its own gate; anything not listed keeps BRAIN_DENSE_JOIN.
def _root_joins():
    out = {}
    for kv in os.environ.get("BRAIN_DENSE_JOIN_ROOTS", "").replace(";", ",").split(","):
        if "=" in kv:
            k, v = kv.split("=", 1)
            try: out[k.strip()] = float(v)
            except ValueError: pass
    return out
DENSE_JOIN_ROOTS = _root_joins()
def join_for(root): return DENSE_JOIN_ROOTS.get(root or "", DENSE_JOIN)
SCOPE = pathlib.Path(os.environ.get("BRAIN_MEMORY2", "/x/y")).parent.name   # must match brain_embed's IMEM_TAG
RRF_K = 60
# Freshness bonus on the fused score - OFF by default, kept because the measurement that turned it off is
# worth having in the open. Notes written in the last day are the ones that actually get opened (measured on
# the author's install: 17.0% of same-day injections were followed by a Read, 4.3% of notes older than a
# month), so freshness looks like a ranking signal. BM25 already carries it twice (recency boost, age decay);
# applying it to the dense cosine made recall worse in an earlier round; RRF was the one layer that never saw
# it. Measured there too, on the same two gold sets: hit@1 0.633 -> 0.533 and MRR 0.739 -> 0.689 (n=30),
# hit@1 0.600 -> 0.467 and MRR 0.717 -> 0.650 (n=15), hit@3 unchanged in both. A fresh note does reach the
# top - it is just not the one that answers the question. Turn it on with BRAIN_RRF_RECENCY=1 if your own
# gold set says otherwise; the code below is live either way.
RRF_RECENCY = os.environ.get("BRAIN_RRF_RECENCY", "0") == "1"
RRF_REC_1D, RRF_REC_3D = 1.10, 1.03         # <= 1 day x1.10, 2-3 days x1.03, older unchanged


def _recency_mult(it):
    """Small RRF multiplier from the note's frontmatter date (`dord`, brain_bm25._date_ord's scale).
    Memory notes are exempt for the same reason BM25 exempts them: they are timeless canon, not dated news."""
    if not RRF_RECENCY:
        return 1.0
    d = it.get("dord")
    if not d or it.get("root") == "memory":
        return 1.0
    try:
        import datetime
        age = bm._date_ord(datetime.date.today().isoformat()) - int(d)
    except Exception:
        return 1.0
    if age <= 1:
        return RRF_REC_1D
    return RRF_REC_3D if age <= 3 else 1.0


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


DENSE_Q_MAX = int(os.environ.get("BRAIN_DENSE_Q_MAX", "1500"))  # chars; the daemon caps the token side too


def dense(q, k):
    """Dense hits from the daemon; any error, timeout or foreign-vault daemon -> [] (silent, but logged).

    The query is cut to DENSE_Q_MAX characters first. BGE-M3 encodes on CPU in time linear in query length
    (measured 23 Sep 2026 on an idle 24-core box: 20 words 0.38 s, 100 words 1.08 s, 300 words 2.8 s, 800
    words 10.3 s), so a pasted document or a long agent report blows through TIMEOUT - and because the daemon
    is single-threaded, the encode keeps running after this side has given up and every other session's dense
    call queues behind it. One 24-hour window on the author's install: 29 timeouts, all of them long prompts."""
    if not daemon_serves_my_vault():
        _dense_log(False, 0, "foreign-or-down")
        return []
    t0 = time.time()
    try:
        u = f"{URL}/search?" + urllib.parse.urlencode({"q": q[:DENSE_Q_MAX], "k": k, "scope": SCOPE})
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
                cur.update({kk: r[kk] for kk in ("hint", "heading", "path", "text", "root", "dord") if kk in r})
                cur["bm25"] = r.get("score")
            else:
                cur["cos"] = r.get("score")
                cur.setdefault("hint", "")
                cur.setdefault("dord", r.get("dord"))
    for n in sc:                                     # freshness bonus, off unless BRAIN_RRF_RECENCY=1
        sc[n] *= _recency_mult(item[n])
    top_b = float(sparse[0].get("score") or 0.0) if sparse else 0.0   # denominator for the "b" ratio below
    out = []
    # Tie order (9 Sep 2026): equal RRF scores used to fall to whichever list was merged first (BM25), so a BM25-only note
    # beat a dense-only one at 1.6 vs 1.6. A note the dense engine also saw now wins the tie - measured hybrid hit@1 0.60 -> 0.67.
    for n, s in sorted(sc.items(), key=lambda x: (-x[1], 0 if item[x[0]].get("cos") is not None else 1))[:k]:
        it = item[n]
        src = ("b" if it.get("bm25") is not None else "") + ("d" if it.get("cos") is not None else "")
        # 23 Sep 2026: a fused line keeps the RRF number ("3.3bd" = found by both engines). A line only one
        # engine found prints that engine's own measure instead - the cosine, or the BM25 score as a fraction
        # of the best BM25 score for this query. The old number was derived from the rank, which the reader
        # can already see from the line order, so four of five printed scores said nothing (measured: a score
        # of 0.553 AUC at separating notes that were read from notes that were not). The trailing letter is
        # unchanged, because everything downstream reads it: the renderer's confidence tier looks for "bd",
        # and the hook detects a dead dense daemon by the absence of "d".
        if src == "bd":
            it["score"] = f"{round(s * 100, 1)}bd"
        elif src == "d":
            it["score"] = f"{float(it.get('cos') or 0.0):.2f}d"
        else:
            it["score"] = f"{(float(it.get('bm25') or 0.0) / top_b if top_b > 0 else 0.0):.2f}b"
        out.append(it)
    return out


def single(lst, k, tag, dense_answered=False):
    """One engine's own results, labelled so a caller reading the "score" field can always tell which
    engine(s) answered from the trailing letter alone - including the case where the dense daemon never
    answered at all, which the hook uses to warn about that. `dense_answered` separates "the daemon replied
    but nothing cleared the cosine gate" (normal for a short or chatty prompt) from "the daemon never
    replied" - the hook must only warn on the latter.

    23 Sep 2026: the printed number is the engine's own measure - the cosine for dense ("0.71d"), the BM25
    score over the best BM25 score for this query for sparse ("0.83b"). It used to be the RRF value of that
    rank, which meant every one-engine block printed the same descending sequence (1.6, 1.6, 1.6...) and told
    the reader nothing the line order did not. Raw scores are not printed either: a BM25 score in the
    thousands is unreadable, and a bare cosine looks like a fused hit."""
    out = []
    top = float((lst[0].get("score") if lst else 0.0) or 0.0)
    for i, r in enumerate(lst[:k]):
        it = dict(r)
        v = float(r.get("score") or 0.0)
        it["bm25" if tag == "b" else "cos"] = r.get("score")
        it["score"] = f"{v:.2f}d" if tag == "d" else f"{(v / top if top > 0 else 0.0):.2f}b"
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
    dens = [r for r in dens if r.get("score", 0.0) >= join_for(r.get("root"))]
    return fuse(sparse, dens, k) if dens else single(sparse, k, "b", dense_answered=True)


def wiki_pull(q, out, k=40):
    """Trust order (7 Sep 2026): shared docs (BRAIN_WIKI_DIR, BRAIN_WIKI_DIRS) rank above notes for *how the system works*
    questions. If the fused top-k carries no docs hit, the best docs hit is appended anyway (flagged
    `wiki_pull`), provided it ranks within BRAIN_RECALL_WIKI_PULL_RANK (default 10) of either engine —
    so a marginally relevant doc is surfaced as a pointer, an irrelevant one is not. The hook prints it in
    its own SOURCE block. Case that motivated it: the right doc existed, recall showed only notes, a note
    carrying an inference was repeated as fact and cost a long correction. BM25 first (index, ~7 ms), dense
    second. Disable with BRAIN_RECALL_WIKI_PULL=0."""
    if os.environ.get("BRAIN_RECALL_WIKI_PULL", "1") != "1" or any(bw.is_wiki(x.get("root")) for x in out):
        return out
    if int(os.environ.get("RECALL_PROMPT_WORDS", "9") or 9) < 4:  # no docs-pull for one-word / chat prompts (an unrelated doc is worse than none)
        return out
    floor = int(os.environ.get("BRAIN_RECALL_WIKI_PULL_RANK", "10") or 10)
    for lst, tag in ((bm.search(q, k), "b"), (dense(q, k), "d")):
        top = float((lst[0].get("score") if lst else 0.0) or 0.0)
        for i, r in enumerate((lst or [])[:floor]):
            if bw.is_wiki(r.get("root")):
                it = dict(r); it["bm25" if tag == "b" else "cos"] = r.get("score")
                v = float(r.get("score") or 0.0)     # same measure as single(): cosine, or BM25 as a ratio
                it["score"] = f"{v:.2f}d" if tag == "d" else f"{(v / top if top > 0 else 0.0):.2f}b"
                it["wiki_pull"] = True
                return out + [it]
    return out


if __name__ == "__main__":
    q = sys.argv[1] if len(sys.argv) > 1 else ""
    k = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    print(json.dumps(wiki_pull(q, recall(q, k)) if q else [], ensure_ascii=False))
