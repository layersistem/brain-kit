#!/bin/bash
# SessionStart (startup|resume|clear|compact): bind an identity to THIS session.
#
# Order: (1) a session_id already bound earlier -> the same identity (resume and
# compact stay stable); (2) a ticket at <claude-dir>/brain-kit-state/next-instance,
# one line "<instance> <folder>", consumed if the session's cwd is under that
# folder; (3) otherwise the nearest .brain-instance walking up from cwd.
#
# The result is written twice: pid-<claude pid> (read by _instance.sh in every
# hook and by anything the Bash tool runs) and sid-<session_id> (so the next
# resume finds it). Dead pid files are pruned on every run. Nothing here is secret.
IN=$(cat 2>/dev/null || true)
SID=$(printf '%s' "$IN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
CWD=$(printf '%s' "$IN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_instance.sh"
mkdir -p "$STATE_DIR"
CP=$(claude_pid) || exit 0

for f in "$STATE_DIR"/pid-*; do
  [ -f "$f" ] || continue
  p=${f##*/pid-}; kill -0 "$p" 2>/dev/null || rm -f "$f"
done

INST=""
TICKET="$STATE_DIR/../next-instance"
if [ -n "$SID" ] && [ -f "$STATE_DIR/sid-$SID" ]; then
  INST=$(tr -cd 'a-zA-Z0-9_-' < "$STATE_DIR/sid-$SID")
elif [ -s "$TICKET" ]; then
  read -r T_INST T_DIR < "$TICKET"
  case "$CWD" in "$T_DIR"|"$T_DIR"/*) INST=$(printf '%s' "$T_INST" | tr -cd 'a-zA-Z0-9_-'); : > "$TICKET" ;; esac
fi
if [ -z "$INST" ]; then
  d="$CWD"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -f "$d/.brain-instance" ] && { INST=$(head -1 "$d/.brain-instance" | tr -cd 'a-zA-Z0-9_-'); break; }
    d=$(dirname "$d")
  done
fi
[ -n "$INST" ] || exit 0
printf '%s' "$INST" > "$STATE_DIR/pid-$CP"
[ -n "$SID" ] && printf '%s' "$INST" > "$STATE_DIR/sid-$SID"
[ -n "${CLAUDE_ENV_FILE:-}" ] && echo "export BRAIN_INSTANCE=$INST" >> "$CLAUDE_ENV_FILE"
echo "identity bound: $INST (claude pid $CP${SID:+, session ${SID:0:8}})"
exit 0
