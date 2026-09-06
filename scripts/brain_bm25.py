#!/usr/bin/env python3
"""brain_bm25 - lightweight recall over a markdown vault. No model, no network, ~100ms.
Score = BM25 over (filename + heading + frontmatter hint + section body), times entity boost,
recency boost, superseded penalty, frontmatter weight, usage-reinforcement and age decay; then a
relevance gate that returns nothing rather than noise. Semantic counterpart: brain_search.py.
Usage: brain_bm25.py "query" [k]
Env: BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_MEMORY . BRAIN_MEMORY2 .
     BRAIN_WIKI_DIR . BRAIN_STOPWORDS (extra stopwords, comma/space separated) .
     BRAIN_INDEX=sqlite - route through brain_index_search.py's SQLite/FTS5 build instead of
     re-scanning every file on disk (same formula, same output shape; see brain_index.py)."""
import os, sys, re, math, pathlib, datetime
from collections import Counter
from brain_stem import stem                               # Turkish-aware suffix stripper
from brain_project import note_project, active_project    # scope filter

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
MEMORY = pathlib.Path(os.environ.get("BRAIN_MEMORY", str(BRAIN_ROOT / "memory")))
MEMORY2 = pathlib.Path(os.environ.get("BRAIN_MEMORY2", "/nonexistent"))  # agent-managed memory dir
WIKI = pathlib.Path(os.environ.get("BRAIN_WIKI_DIR", "/nonexistent"))    # optional shared docs root
ROOTS = ((VAULT, "vault"), (MEMORY, "memory"), (MEMORY2, "memory"), (WIKI, "wiki"))
_TR = str.maketrans("çğıöşüâîûÇĞİÖŞÜ", "cgiosuaiuCGIOSU")   # de-accent so Turkish tokens match
ENT_W, REC_W, SUP_W = 0.5, 0.3, 0.5         # entity boost, recency boost, superseded penalty
W_MAP = {"canon": 1.5, "lesson": 1.3, "approval": 1.15, "decision": 1.15, "routine": 0.85, "hub": 0.85}  # frontmatter weight:
AGE_W, AGE_FLOOR = 0.4, 0.6                 # dated + unweighted notes fade to 0.6 over a year
MARK = re.compile(r"CANON|LESSON|NEVER|\U0001F534")  # heading markers implying weight: lesson
USE_W, USE_CAP = 0.15, 5   # usage-reinforcement: notes actually surfaced-and-read earn a small,
# capped recency-independent boost. hooks/_auto_retrieve.sh appends a basename to
# .index/recall_counts.json ({basename: {c, ts}}) each time a note is injected into a prompt;
# read it here as a log-scaled multiplier so a note's own recall history nudges its future rank.
try:
    import json as _json
    _USE = {k: (v.get("c", 0) if isinstance(v, dict) else v)
            for k, v in _json.loads((VAULT / ".index" / "recall_counts.json").read_text()).items()}
except Exception:
    _USE = {}
STOP = {"the", "a", "an", "and", "or", "of", "to", "in", "is", "are", "was", "were", "for", "on",
        "with", "that", "this", "it", "as", "at", "by", "from", "be", "how", "what", "why", "when",
        "which", "do", "does", "did", "i", "you", "we", "my", "our", "not", "no", "can", "should",
        "would", "if", "so", "but", "have", "has", "there", "about",
        # Turkish stopwords - recall is bilingual on purpose (see README)
        "hangi", "nereden", "neden", "nasil", "ne", "icin", "ile", "bu", "su", "o", "da", "de",
        "ki", "mi", "mu", "veya", "ama", "bir", "ben", "sen", "var", "yok", "cok", "daha", "gibi",
        "icinde", "uzerine", "kadar", "sonra", "once", "midir"}
_SWF = BRAIN_ROOT / ".brain-stopwords"      # per-install extra stopwords; env adds on top
STOP |= {w for w in re.split(r"[,\s]+", ((_SWF.read_text() if _SWF.exists() else "") + " " +
         os.environ.get("BRAIN_STOPWORDS", "")).translate(_TR).lower()) if w}

def _toks(s):
    return [stem(t) for t in re.findall(r"[a-z0-9]+", s.translate(_TR).lower())]

def _meta(text):
    """frontmatter -> (recall hint, date, superseded flag, weight multiplier)."""
    e = text.find("\n---", 3) if text.startswith("---") else -1
    if e == -1:
        return "", "", False, 1.0
    fm, hint = text[3:e], ""
    for key in ("recall_hint", "description", "topic"):
        m = re.search(r"(?mi)^%s:[ \t]*(.+)$" % key, fm)
        if m:
            hint = m.group(1).strip(); break
    md = re.search(r"(?mi)^date:[ \t]*(\d{4}-\d{2}-\d{2})", fm)
    sl = re.search(r"(?mi)^status:[ \t]*(.+)$", fm)
    sup = bool((sl and re.search(r"supersed|rejected|closed|reopened|dead|replaced|obsolete",
                                 sl.group(1).lower())) or re.search(r"(?mi)^superseded[- ]?by:", fm))
    mw = re.search(r"(?mi)^weight:[ \t]*(\w+)", fm)
    return hint, (md.group(1) if md else ""), sup, (W_MAP.get(mw.group(1).lower(), 1.0) if mw else 1.0)

def _date_ord(d):
    try:
        y, m, dd = map(int, d.split("-")); return y * 372 + m * 31 + dd
    except Exception:
        return None

def _sections(text):
    """Split a note into (heading, body) units so recall points at a section, not a whole file."""
    body, e = text, (text.find("\n---", 3) if text.startswith("---") else -1)
    if e != -1:
        body = text[e + 4:].lstrip("\n")
    title = next((l[2:].strip() for l in text.splitlines() if l.startswith("# ")), "")
    parts = re.split(r"(?m)^## ", body)
    out = [(title or "intro", parts[0].strip())] if parts[0].strip() else []
    for p in parts[1:]:
        out.append(((p.splitlines()[0].strip() if p.strip() else ""), "## " + p.strip()))
    return out or [(title, text)]

def _corpus():
    docs = []
    for root, tag in ROOTS:
        if not root.exists():
            continue
        for f in root.rglob("*.md"):
            rel = f.relative_to(root).parts
            if any(p.startswith(".") for p in rel) or f.name == "MEMORY.md" \
               or "_drafts" in rel or "_archive" in rel:
                continue                     # hidden, index, drafts and archive stay out
            try:
                txt = f.read_text(errors="ignore")
            except Exception:
                continue
            rtag = "memory" if (tag == "vault" and rel[:1] == ("memory",)) else tag
            hint, date, sup, w = _meta(txt)
            dord = _date_ord(date)
            for h, b in _sections(txt):
                tok = _toks((f.stem + " " + h + " " + hint + " " + b)[:4000])
                docs.append({"root": rtag, "note": f.stem, "heading": h,
                             "path": f"{rtag}/{f.relative_to(root)}",
                             "text": b[:600], "tok": tok, "hint": hint, "dord": dord, "sup": sup,
                             "name": set(_toks(f.stem + " " + h + " " + hint)),
                             "project": note_project(txt, tok, f.stem),
                             "w": max(w, W_MAP["lesson"]) if MARK.search(h) else w})
    return docs

def search(query, k=5, k1=1.5, b=0.75):
    if os.environ.get("BRAIN_INDEX") == "sqlite":  # accelerated path: brain_index.py's SQLite/FTS5 build
        try:
            from brain_index_search import search as _sqlite_search
            return _sqlite_search(query, k, k1, b)
        except Exception:
            pass  # index missing or broken -> fall through to the file-scan path below, silently
    q = [t for t in _toks(query) if t not in STOP]; qset = set(q); ap = active_project()
    docs = [d for d in _corpus() if not (ap and d["project"] not in (ap, "general"))]
    if not docs or not q:
        return []
    N = len(docs); avgdl = sum(len(d["tok"]) for d in docs) / N; df = Counter()
    for d in docs:
        for t in set(d["tok"]):
            df[t] += 1
    idf = lambda t: math.log(1 + (N - df[t] + 0.5) / (df[t] + 0.5))
    dords = [d["dord"] for d in docs if d["dord"]]
    dmin, drange = (min(dords), (max(dords) - min(dords)) or 1) if dords else (0, 1)
    tod = _date_ord(datetime.date.today().isoformat())
    scored = []
    for d in docs:
        tf = Counter(d["tok"]); dl = len(d["tok"]); s = 0.0
        for t in q:
            if t in tf:
                s += idf(t) * tf[t] * (k1 + 1) / (tf[t] + k1 * (1 - b + b * dl / avgdl))
        if s <= 0:
            continue
        s *= 1 + ENT_W * sum(1 for t in (qset & d["name"]) if idf(t) >= 2.0)
        if d["dord"] and d["root"] != "memory":     # memory is timeless canon: no recency, no decay
            s *= 1 + REC_W * (d["dord"] - dmin) / drange
            if d["w"] <= 1.0:
                s *= max(AGE_FLOOR, 1 - AGE_W * (tod - d["dord"]) / 372)
        s *= SUP_W if d["sup"] else 1.0
        uc = _USE.get(os.path.basename(d["path"]), 0)
        if uc:
            s *= 1 + USE_W * min(1.0, math.log1p(uc) / math.log1p(USE_CAP))
        scored.append((s * d["w"], d))
    scored.sort(key=lambda x: -x[0])
    seen, uniq = set(), []                          # dedupe: top-k must be distinct notes
    for s, d in scored:
        if d["note"] in seen:
            continue
        seen.add(d["note"]); uniq.append((s, d))
        if len(uniq) >= k:
            break
    if not uniq:
        return []
    tt = set(uniq[0][1]["tok"])
    rare = [t for t in qset & tt if df[t] > 0 and idf(t) >= 2.0]
    if len(qset & tt) / max(len(qset), 1) < 0.45 and len(rare) < 2:
        return []   # gate: neither short-query coverage nor rare-word overlap -> unrelated
    return [{"root": d["root"], "note": d["note"], "heading": d["heading"], "path": d["path"],
             "score": round(s, 2), "hint": d["hint"], "text": d["text"]} for s, d in uniq]

if __name__ == "__main__":
    import json
    print(json.dumps(search(sys.argv[1] if len(sys.argv) > 1 else "",
                            int(sys.argv[2]) if len(sys.argv) > 2 else 5), ensure_ascii=False))
