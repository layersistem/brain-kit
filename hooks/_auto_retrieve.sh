#!/bin/sh
# UserPromptSubmit - AUTO RECALL: run the incoming prompt through brain_recall.py (hybrid: BM25 in-process
# + BGE-M3 dense from the optional brain_searchd daemon, fused by RRF) and inject the top-k vault/memory
# hits into context. Without the daemon this is plain BM25 - zero model, ~100 ms, no network. Any failure
# is silent: recall must never break the session. Score "3.3bd" = RRF x100 + which engines found it (b/d).
#
# Config: BRAIN_ROOT, BRAIN_DIR (via <claude-dir>/brain-kit.env or the environment).
#         BRAIN_RECALL_K   - how many notes to inject (default 5)
#         BRAIN_ISOLATE_DIRS - space separated dir globs where this hook stays quiet.
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
print("AUTO-RECALL (your own notes, closest to this message - if one is relevant, use it "
      "before re-deriving or reverse-engineering anything) - confidence: %d strong, %d fair:" % (tiers.count("STRONG"), tiers.count("FAIR")))
for x, t in zip(r, tiers):
    h = (x.get("heading") or "").strip()
    line = "  %s [%s] %s:%s" % (t, x["score"], x["root"], x["note"])
    if h: line += " > " + h
    print(line + "  (" + x["path"] + ")")
    hint = (x.get("hint") or "").strip()
    if hint: print("      what: " + hint[:130])
    t = " ".join(x.get("text","").split())[:200]
    if t: print("      " + t)
' 2>/dev/null
exit 0
