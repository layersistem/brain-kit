#!/bin/sh
# PostToolUse (Read) - usage reinforcement, counted from the right event. When the model opens a note that
# lives in the vault or in a memory root, scripts/brain_usage_count.py adds one to
# <vault>/.index/recall_counts.json and brain_bm25.py reads that as a small capped boost on the note's rank.
#
# Until 23 Sep 2026 this count was written by the renderer instead, and it counted what recall *printed*.
# A note that kept being injected and kept being ignored therefore rose in the ranking: measured over 1529
# prompt/read pairs, notes at the counter's cap were 71.7% of all injections and were opened 5.4% of the
# time, against 8.3% for notes below the cap. The multiplier did not change - the event behind it did.
#
# Most Read calls are source files, so the payload is checked for a plausible path before anything is
# started; that keeps the common case at one `case` statement and no child process. Prints nothing: a
# PostToolUse stdout lands in the model's context, and a counter has nothing to say there.
#
# Second machine: with BRAIN_RECALL_REMOTE=1 the Python side sends the increment to the dense daemon
# (GET /count on BRAIN_SEARCHD_URL) instead of writing the counter file over a network share - one writer.
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_MEMORY, BRAIN_MEMORY2, BRAIN_RECALL_REMOTE, BRAIN_SEARCHD_URL
#         (via <claude-dir>/brain-kit.env).
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
export BRAIN_ROOT BRAIN_DIR BRAIN_MEMORY BRAIN_RECALL_REMOTE BRAIN_SEARCHD_URL
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
IN=$(cat)
case "$IN" in
  *"$VAULT"*|*"/memory/"*) ;;
  *) exit 0 ;;
esac
CNT="$BRAIN_ROOT/scripts/brain_usage_count.py"
[ -f "$CNT" ] || exit 0
printf '%s' "$IN" | python3 "$CNT" >/dev/null 2>&1
exit 0
