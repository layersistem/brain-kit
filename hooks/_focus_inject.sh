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
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"

for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${PWD:-}" in $d|$d/*) exit 0 ;; esac
done
if [ -n "${BRAIN_FOCUS_DIRS:-}" ]; then
  hit=0
  for d in $BRAIN_FOCUS_DIRS; do
    case "$PWD" in $d|$d/*) hit=1; break ;; esac
  done
  [ "$hit" = "0" ] && exit 0
fi

I="${BRAIN_INSTANCE:-}"
if [ -z "$I" ]; then
  _d="$PWD"
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
sed 's/^/  /' "$FOCUS" 2>/dev/null

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
