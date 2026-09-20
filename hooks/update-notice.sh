#!/bin/bash
# SessionStart - one line when a newer tagged release of brain-kit exists. It installs nothing.
#
# Four rules it keeps on purpose:
#   1. It tells, it does not apply. Hooks run on every session; a hook that pulls and installs remote
#      code on its own is a supply-chain hole. Applying is a separate, explicit step (scripts/update.sh).
#   2. Only a version number reaches the model. Tags are filtered with ^v[0-9]+.[0-9]+.[0-9]+$ and the
#      sentence is written here. Free text from the remote (tag message, release note) never enters
#      context - otherwise whoever controls the remote could write instructions into your session.
#   3. Quiet and rare: at most once a day (stamp file), a 2 s budget, no network means no output, and
#      the hook always exits 0. `git ls-remote` sends nothing about you and needs no account or key.
#   4. BRAIN_UPDATE_CHECK=0 turns it off for good.
# Config: BRAIN_UPDATE_CHECK (1), BRAIN_UPDATE_REMOTE (the https form of the origin setup.sh ran from),
#         BRAIN_UPDATE_TIMEOUT (2 seconds).
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && . "$CFG/brain-kit.env" 2>/dev/null
[ "${BRAIN_UPDATE_CHECK:-1}" = "0" ] && exit 0
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
REMOTE="${BRAIN_UPDATE_REMOTE:-https://github.com/layersistem/brain-kit}"
BUDGET="${BRAIN_UPDATE_TIMEOUT:-2}"

LOCAL=$(head -c 32 "$BRAIN_ROOT/VERSION" 2>/dev/null | tr -d ' \t\r\n')
printf '%s' "$LOCAL" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || exit 0   # no readable VERSION: nothing to compare
command -v git >/dev/null 2>&1 || exit 0

ST="$CFG/brain-kit-state"; mkdir -p "$ST" 2>/dev/null || exit 0
STAMP="$ST/update_check"; TODAY=$(date +%Y-%m-%d)
[ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ] && exit 0
printf '%s\n' "$TODAY" > "$STAMP" 2>/dev/null   # stamp first: a remote that hangs must not be retried all day

# macOS ships no `timeout`, so the budget is enforced here instead of being assumed.
bounded() {
  secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  "$@" & pid=$!
  ( sleep "$secs"; kill -9 "$pid" >/dev/null 2>&1 ) >/dev/null 2>&1 & guard=$!
  wait "$pid" >/dev/null 2>&1; rc=$?
  kill -9 "$guard" >/dev/null 2>&1; wait "$guard" >/dev/null 2>&1
  return $rc
}

TAGS="$ST/update_tags.$$"
# A checkout cloned over ssh makes this an ssh call: BatchMode keeps it from asking for a passphrase or a
# host key in the middle of a session start. It fails quietly instead, like every other path here.
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" bounded "$BUDGET" \
  git ls-remote --tags --refs "$REMOTE" > "$TAGS" 2>/dev/null
[ -s "$TAGS" ] || { rm -f "$TAGS"; exit 0; }    # unreachable, timed out, or no tags: say nothing

# Whole-line match only. v1.2, v1.2.3-rc, a tag carrying free text and a name containing a newline all
# fail this pattern and are dropped; what survives is three integers.
REMOTE_V=$(sed -n 's#^[0-9a-f]\{7,\}[[:space:]]*refs/tags/v\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)$#\1#p' "$TAGS" \
  | awk -F. 'NF==3 { if ($1>a || ($1==a && ($2>b || ($2==b && $3>c)))) { a=$1; b=$2; c=$3 } }
             END { if (a != "") printf "%d.%d.%d", a, b, c }')
rm -f "$TAGS"
[ -n "$REMOTE_V" ] || exit 0

newer() { printf '%s %s' "$1" "$2" |
  awk -F'[ .]' '{ exit !($1>$4 || ($1==$4 && ($2>$5 || ($2==$5 && $3>$6)))) }'; }
newer "$REMOTE_V" "$LOCAL" || exit 0

echo "brain-kit $REMOTE_V is available (installed: $LOCAL). Nothing was downloaded and nothing changed."
echo "If the user wants it: bash \"$BRAIN_ROOT/scripts/update.sh\" - it shows the changes and asks before"
echo "touching anything; UPGRADE.md is the instruction sheet. BRAIN_UPDATE_CHECK=0 stops this check."
exit 0
