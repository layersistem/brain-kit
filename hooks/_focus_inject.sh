#!/bin/bash
# UserPromptSubmit - FOCUS FIRST: inject this instance's focus file verbatim, plus (optionally)
# open tasks and recent git state. The focus file is the one thing you must keep current; a stale
# focus misdirects every session.
#
# Config: BRAIN_ROOT, BRAIN_DIR (via <claude-dir>/brain-kit.env or the environment)
#         BRAIN_INSTANCE      - instance name (else .brain-instance, else "main")
#         BRAIN_FOCUS_DIRS    - only inject while cwd is under one of these globs (empty = always)
#         BRAIN_ISOLATE_DIRS  - dir globs where this hook stays quiet
#         BRAIN_TODO          - optional task file with a "## OPEN" section
#         BRAIN_PROJECT_GIT   - optional repo path; prints last commits + dirty files
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"

for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
if [ -n "${BRAIN_FOCUS_DIRS:-}" ]; then
  hit=0
  for d in $BRAIN_FOCUS_DIRS; do
    case "$SESSION_ROOT" in $d|$d/*) hit=1; break ;; esac
  done
  [ "$hit" = "0" ] && exit 0
fi

I="${BRAIN_INSTANCE:-}"
if [ -z "$I" ]; then
  _d="$SESSION_ROOT"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -f "$_d/.brain-instance" ]; then I=$(head -1 "$_d/.brain-instance" | tr -d '[:space:]'); break; fi
    _d=$(dirname "$_d")
  done
fi
[ -z "$I" ] && [ -f "$VAULT/.brain-instance" ] && I=$(head -1 "$VAULT/.brain-instance" | tr -d '[:space:]')
[ -z "$I" ] && I="main"

FOCUS="$VAULT/focus/_FOCUS_$I.txt"
if [ ! -f "$FOCUS" ]; then
  echo "FOCUS: instance '$I' has no focus file yet - create $FOCUS (first line: SUMMARY: ...)."
  exit 0
fi
echo "CURRENT FOCUS ($I) - from ${FOCUS#$VAULT/}; update it whenever the focus changes:"
# Injection cap. The focus file is the CURRENT state plus pointers; history belongs in decision
# records. A focus that grows into a diary is re-sent on every prompt (measured: a 59 KB summary
# line cost 96 KB per prompt across every instance). Over the cap it is truncated with a warning;
# the full file is still on disk. Override with BRAIN_FOCUS_MAX (bytes).
_FMAX=${BRAIN_FOCUS_MAX:-12000}
_fsz=$(wc -c < "$FOCUS")
if [ "$_fsz" -gt "$_FMAX" ]; then
  head -c "$_FMAX" "$FOCUS" | sed 's/^/  /'
  echo ""
  echo "  WARNING: focus truncated ($_fsz > $_FMAX bytes). Move history into a decision record and shorten the summary line."
else
  sed 's/^/  /' "$FOCUS" 2>/dev/null
fi

if [ -n "${BRAIN_TODO:-}" ] && [ -f "$BRAIN_TODO" ]; then
  echo ""
  echo "-- OPEN TASKS --"
  awk '/^## OPEN/{f=1;next} /^## (DONE|CLOSED|CANCELLED)/{f=0} f&&/^### /{print "  - " substr($0,5)}' \
    "$BRAIN_TODO" 2>/dev/null | head -6
fi

if [ -n "${BRAIN_PROJECT_GIT:-}" ] && [ -d "$BRAIN_PROJECT_GIT/.git" ]; then
  echo ""
  echo "-- RECENT GIT (mutation evidence; compare it against the open tasks) --"
  git -C "$BRAIN_PROJECT_GIT" log --oneline -4 2>/dev/null | sed 's/^/  /'
  git -C "$BRAIN_PROJECT_GIT" status --porcelain 2>/dev/null | head -6 | sed 's/^/  dirty: /'
fi
exit 0
