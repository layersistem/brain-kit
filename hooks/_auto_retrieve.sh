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
#         BRAIN_WIKI_DIR   - optional shared docs root; with it set, output follows the trust order
#         DOCS -> CODE -> everything else UNVERIFIED (see scripts/brain_recall_print.py).
#
# 7 Sep 2026: the output renderer moved to scripts/brain_recall_print.py. It used to be an inline single-quoted
# `python3 -c '...'` block here; one apostrophe in a comment broke the quoting and, this being a global
# UserPromptSubmit hook, every session on the machine got "A hook blocked your prompt" until it was fixed.
# No Python lives in this file any more.
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
PR="$BRAIN_ROOT/scripts/brain_recall_print.py"
[ -f "$PR" ] || exit 0
# Third root: the per-project memory directory some agent CLIs manage themselves.
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
export BRAIN_WIKI_DIR   # shared docs root, if brain-kit.env sets one - the renderer resolves docs hits to real paths
IN=$(cat)
PROMPT=$(printf '%s' "$IN" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("prompt",""))
except Exception: print("")' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0
# Metacognition (17 Aug 2026): confidence tag per note (STRONG/FAIR) and a count in the header; when nothing matched a
# real question (>= 6 words) the renderer says so out loud instead of staying silent.
export RECALL_PROMPT_WORDS=$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')
export RECALL_PROMPT_TEXT="$PROMPT"                      # hashed only - docs-topic marker for an optional Stop gate
export RECALL_INSTANCE="${BRAIN_INSTANCE:-}"             # marker file name, if the install names its instances
python3 "$BM" "$PROMPT" "${BRAIN_RECALL_K:-5}" 2>/dev/null | python3 "$PR" 2>/dev/null
exit 0
