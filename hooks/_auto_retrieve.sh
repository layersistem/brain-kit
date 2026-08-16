#!/bin/sh
# UserPromptSubmit - AUTO RECALL: run the incoming prompt through brain_bm25.py and inject
# the top-k vault/memory hits into context. Zero model, ~100ms, no network. Any failure is
# silent: recall must never break the session.
#
# Config: BRAIN_ROOT, BRAIN_DIR (via <claude-dir>/brain-kit.env or the environment).
#         BRAIN_RECALL_K   - how many notes to inject (default 5)
#         BRAIN_ISOLATE_DIRS - space separated dir globs where this hook stays quiet.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
export BRAIN_ROOT BRAIN_DIR
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${PWD:-}" in $d|$d/*) exit 0 ;; esac
done
BM="$BRAIN_ROOT/scripts/brain_bm25.py"
[ -f "$BM" ] || exit 0
# Third root: the per-project memory directory some agent CLIs manage themselves.
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${PWD:-}" | tr '/ _' '---')/memory}"
IN=$(cat)
PROMPT=$(printf '%s' "$IN" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("prompt",""))
except Exception: print("")' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0
python3 "$BM" "$PROMPT" "${BRAIN_RECALL_K:-5}" 2>/dev/null | python3 -c '
import sys, json
try: r = json.load(sys.stdin)
except Exception: r = []
if not r: sys.exit(0)
print("AUTO-RECALL (your own notes, closest to this message - if one is relevant, use it "
      "before re-deriving or reverse-engineering anything):")
for x in r:
    h = (x.get("heading") or "").strip()
    line = "  [%s] %s:%s" % (x["score"], x["root"], x["note"])
    if h: line += " > " + h
    print(line + "  (" + x["path"] + ")")
    hint = (x.get("hint") or "").strip()
    if hint: print("      what: " + hint[:130])
    t = " ".join(x.get("text","").split())[:200]
    if t: print("      " + t)
' 2>/dev/null
exit 0
