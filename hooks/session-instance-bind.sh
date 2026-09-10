#!/bin/bash
# SessionStart (startup|resume|clear|compact) + UserPromptSubmit: bind an identity to THIS session.
#
# Order: (1) a session_id already bound earlier -> the same identity (resume and
# compact stay stable); (2) a ticket at <claude-dir>/brain-kit-state/next-instance,
# one line "<instance> <folder>", consumed if the session's cwd is under that
# folder; (3) the session's title as the desktop app records it in the transcript
# (`agent-name` / `custom-title`), mapped through BRAIN_TITLE_MAP; (4) otherwise
# the nearest .brain-instance walking up from cwd.
#
# Why it also runs on UserPromptSubmit (2026-09-10): a desktop client continued a
# window under a NEW session_id and SessionStart never fired on that path. No pid
# file, no sid file, so every hook fell back to the folder's name and the session
# spent a quarter of an hour signing as its neighbour. On each prompt this hook now
# checks that the pid file exists and agrees with the sid file; when both hold it
# exits at once, otherwise it re-binds. That is the whole self-heal.
#
# BRAIN_TITLE_MAP: "pattern=instance;pattern=instance" - case-insensitive substring
# match on the recorded title; a pattern may hold alternatives with "|". Unset =
# the title source is skipped. Example: "web|frontend=web;api=api".
#
# The result is written twice: pid-<claude pid> (read by _instance.sh in every
# hook and by anything the Bash tool runs) and sid-<session_id> (so the next
# resume finds it). Dead pid files are pruned. A line is printed only when the
# identity CHANGES; a quiet turn prints nothing. Nothing here is secret.
IN=$(cat 2>/dev/null || true)
py() { printf '%s' "$IN" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }
SID=$(py session_id); CWD=$(py cwd); TP=$(py transcript_path); EV=$(py hook_event_name)
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_instance.sh"
mkdir -p "$STATE_DIR"
CP=$(claude_pid) || exit 0
CUR=""; [ -f "$STATE_DIR/pid-$CP" ] && CUR=$(tr -cd 'a-zA-Z0-9_-' < "$STATE_DIR/pid-$CP")

# Fast path on a prompt: pid file present AND this session's sid file names the same identity.
# Without a sid file there is no fast path - the pid file may have come from the folder walk-up.
if [ "$EV" = "UserPromptSubmit" ] && [ -n "$CUR" ] && [ -n "$SID" ] && [ -f "$STATE_DIR/sid-$SID" ] \
   && [ "$(tr -cd 'a-zA-Z0-9_-' < "$STATE_DIR/sid-$SID")" = "$CUR" ]; then
  exit 0
fi

for f in "$STATE_DIR"/pid-*; do
  [ -f "$f" ] || continue
  p=${f##*/pid-}; kill -0 "$p" 2>/dev/null || rm -f "$f"
done

# Transcript title -> instance, through BRAIN_TITLE_MAP. The title is whatever the client wrote as
# agent-name / custom-title; both are read, lower-cased, and matched as substrings.
title_instance() {
  [ -n "${BRAIN_TITLE_MAP:-}" ] || return 1
  local t; t=$(grep -m2 -oE '"type":"(agent-name|custom-title)","(agentName|customTitle)":"[^"]*"' "$1" 2>/dev/null \
               | sed -E 's/.*":"([^"]*)"$/\1/' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')
  [ -n "$t" ] || return 1
  local rule pat inst alt
  IFS=';' read -ra rules <<< "$BRAIN_TITLE_MAP"
  for rule in "${rules[@]}"; do
    pat=${rule%%=*}; inst=${rule#*=}
    [ -n "$pat" ] && [ -n "$inst" ] && [ "$pat" != "$rule" ] || continue
    IFS='|' read -ra alts <<< "$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')"
    for alt in "${alts[@]}"; do
      case "$t" in *"$alt"*) printf '%s' "$inst" | tr -cd 'a-zA-Z0-9_-'; return 0 ;; esac
    done
  done
  return 1
}

INST=""; SRC=""
TICKET="$STATE_DIR/../next-instance"
if [ -n "$SID" ] && [ -f "$STATE_DIR/sid-$SID" ]; then
  INST=$(tr -cd 'a-zA-Z0-9_-' < "$STATE_DIR/sid-$SID"); SRC=session
elif [ -s "$TICKET" ]; then
  read -r T_INST T_DIR < "$TICKET"
  case "$CWD" in "$T_DIR"|"$T_DIR"/*) INST=$(printf '%s' "$T_INST" | tr -cd 'a-zA-Z0-9_-'); : > "$TICKET"; SRC=ticket ;; esac
fi
if [ -z "$INST" ] && [ -n "$TP" ] && [ -f "$TP" ]; then
  INST=$(title_instance "$TP") && SRC=title || INST=""
fi
if [ -z "$INST" ]; then
  d="$CWD"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -f "$d/.brain-instance" ] && { INST=$(head -1 "$d/.brain-instance" | tr -cd 'a-zA-Z0-9_-'); SRC=folder; break; }
    d=$(dirname "$d")
  done
fi
[ -n "$INST" ] || exit 0
printf '%s' "$INST" > "$STATE_DIR/pid-$CP"
[ -n "$SID" ] && printf '%s' "$INST" > "$STATE_DIR/sid-$SID"
[ -n "${CLAUDE_ENV_FILE:-}" ] && echo "export BRAIN_INSTANCE=$INST" >> "$CLAUDE_ENV_FILE"
[ "$INST" = "$CUR" ] && exit 0
echo "identity bound: $INST (source $SRC, claude pid $CP${SID:+, session ${SID:0:8}}${CUR:+, was $CUR})"
exit 0
