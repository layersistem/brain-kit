#!/bin/sh
# UserPromptSubmit - AUTO RECALL: run the incoming prompt through brain_recall.py (hybrid: BM25 in-process
# + BGE-M3 dense from the optional brain_searchd daemon, fused by RRF) and inject the top-k vault/memory
# hits into context. Without the daemon this is plain BM25 - zero model, ~100 ms, no network. Any failure
# is silent: recall must never break the session. Score "3.3bd" = RRF x100 + which engines found it (b/d).
#
# Config: BRAIN_ROOT, BRAIN_DIR (via <claude-dir>/brain-kit.env or the environment).
#         BRAIN_RECALL_K   - how many notes to inject (default 5)
#         BRAIN_ISOLATE_DIRS - space separated dir globs where this hook stays quiet.
#         BRAIN_INDEX=sqlite - brain_bm25 reads <vault>/.index/brain.db (brain_index.py) instead
#         of rescanning every file; falls back to the file scan on its own if the DB is missing.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
export BRAIN_ROOT BRAIN_DIR
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
BM="$BRAIN_ROOT/scripts/brain_recall.py"
[ -f "$BM" ] || BM="$BRAIN_ROOT/scripts/brain_bm25.py"   # older installs without the hybrid layer
[ -f "$BM" ] || exit 0
# Third root: the per-project memory directory some agent CLIs manage themselves.
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
export BRAIN_WIKI_DIR   # shared docs root, if brain-kit.env sets one - the printer below resolves wiki hits to real paths
IN=$(cat)
PROMPT=$(printf '%s' "$IN" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("prompt",""))
except Exception: print("")' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0
# Metacognition (17 Aug 2026): a confidence tag per note (STRONG = both engines agreed, or dense cosine >= BRAIN_DENSE_MIN;
# FAIR = one engine only) and a count in the header - so the model knows how much to trust what it was handed. And when
# nothing matched a real question (>= 6 words), say so out loud: "no note on this - say you don't know, label guesses
# as hypotheses" - silence used to be ambiguous between "no record" and "short chatty message".
export RECALL_PROMPT_WORDS=$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')
python3 "$BM" "$PROMPT" "${BRAIN_RECALL_K:-5}" 2>/dev/null | python3 -c '
import sys, json, os
try: r = json.load(sys.stdin)
except Exception: r = []
if not r:
    if int(os.environ.get("RECALL_PROMPT_WORDS","0") or 0) >= 6:
        print("AUTO-RECALL: no matching note - treat this as NOT KNOWN: say so, label any guess as a hypothesis, do not invent; ask if it matters.")
    sys.exit(0)
DM = float(os.environ.get("BRAIN_DENSE_MIN","0.62") or 0.62)
def tier(x):
    s = str(x.get("score",""))
    return "STRONG" if s.endswith("bd") or (x.get("cos") is not None and float(x["cos"]) >= DM) else "FAIR"
tiers = [tier(x) for x in r]
# Dense-daemon health, read off the results themselves (2 Sep 2026): every result score ends in a
# "b"/"d"/"bd" engine tag (brain_recall.single/fuse); if none carries "d" the dense side of hybrid
# recall never answered this turn - the daemon is down, slow, or the index is not built. Surfacing
# that explains a run of "FAIR" tiers instead of leaving it looking like a corpus quality problem.
dense_ok = any("d" in str(x.get("score","")) or x.get("dense_answered") for x in r)  # daemon replied (even if nothing cleared the cosine gate)
# Shared docs root (BRAIN_WIKI_DIR): hits carry root "wiki" and only a basename; resolve to the real file so the
# model can Read it directly instead of guessing where the doc lives. One directory walk, cached per call.
WIKI_DIR = os.environ.get("BRAIN_WIKI_DIR", "")
_WIKI_IDX = None
def wiki_path(name):
    global _WIKI_IDX
    if _WIKI_IDX is None:
        _WIKI_IDX = {}
        for dp, dn, fn in os.walk(WIKI_DIR or "/nonexistent"):
            dn[:] = [d for d in dn if not d.startswith(".") and d != "_archive"]
            for f in fn:
                if f.endswith(".md"): _WIKI_IDX.setdefault(f, os.path.join(dp, f))
    return _WIKI_IDX.get(name, "wiki/" + name)
has_wiki = any(x.get("root") == "wiki" for x in r)
print("AUTO-RECALL (your own notes%s, closest to this message - if one is relevant, use it "
      "before re-deriving or reverse-engineering anything) - confidence: %d strong, %d fair%s:" % (
      " + shared docs (wiki: lines - Read the path)" if has_wiki else "",
      tiers.count("STRONG"), tiers.count("FAIR"),
      "" if dense_ok else " - dense engine did not answer (BM25 only; check brain_searchd on 8799)"))
for x, t in zip(r, tiers):
    h = (x.get("heading") or "").strip()
    if x.get("root") == "wiki": x["path"] = wiki_path(os.path.basename(x["path"]))
    line = "  %s [%s] %s:%s" % (t, x["score"], x["root"], x["note"])
    if h: line += " > " + h
    print(line + "  (" + x["path"] + ")")
    # Diet (17 Aug 2026): low confidence gets less room - FAIR notes are title + address only (Read them if needed),
    # STRONG notes carry the "what" line and the excerpt. Measured: recall block 2.8k -> 1.5k chars per prompt.
    if t != "STRONG": continue
    hint = (x.get("hint") or "").strip()
    if hint: print("      what: " + hint[:130])
    t = " ".join(x.get("text","").split())[:200]
    if t: print("      " + t)
# Belief layer (optional, 2 Sep 2026): if beliefs_rebuild.py has ever been run, .index/beliefs.db
# exists and this shows the active beliefs tied to whatever notes recall just surfaced, plus a
# pointer to anything on the same topic that has since evolved - so a judgement gets made against
# the current belief, not against whatever the recalled note happened to say when it was written.
# Silent if the DB does not exist yet (kit ships the layer opt-in; see docs/BELIEFS.md).
try:
    import subprocess as _sp
    _root = os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain"))
    _o = _sp.run([sys.executable, os.path.join(_root, "scripts", "beliefs_recall.py")] + [x.get("path","") for x in r],
                 capture_output=True, text=True, timeout=1.5).stdout
    if _o.strip(): print(_o.rstrip())
except Exception: pass
# Usage-reinforcement (mirrors a spacing-effect boost from a sibling project): count each note that
# was actually surfaced here into <vault>/.index/recall_counts.json ({basename: {c, ts}}); brain_bm25.py
# reads it back as a small score boost. Best-effort - a write failure must never drop the recall output.
try:
    import json as _j, time as _t
    _vault = os.environ.get("BRAIN_DIR") or os.path.join(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")), "vault")
    _cf = os.path.join(_vault, ".index", "recall_counts.json")
    try: _c = _j.load(open(_cf))
    except Exception: _c = {}
    for x in r:
        _b = os.path.basename(x.get("path",""))
        if not _b: continue
        _e = _c.get(_b) or {"c": 0}
        if not isinstance(_e, dict): _e = {"c": int(_e)}
        _e["c"] = _e.get("c", 0) + 1; _e["ts"] = int(_t.time())
        _c[_b] = _e
    _j.dump(_c, open(_cf, "w"), ensure_ascii=False)
except Exception: pass
' 2>/dev/null
exit 0
