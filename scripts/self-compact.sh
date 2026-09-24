#!/usr/bin/env bash
# self-compact.sh - the agent compacts its own session and carries on where it left off.
#
# The question it answers: "when my context fills up and nobody is at the keyboard, who compacts?" Without
# this, a session that crossed the hard threshold at 03:00 sits there until someone types /compact, or it
# runs into auto-compaction mid-tool-call with no handover note. With it, the agent writes the handover note
# and the focus summary, then starts this script as the LAST command of its turn and ends the turn. The
# script, outside the model, does the rest:
#
#   1. waits for the turn to end (Claude Code shows "esc to interrupt" in the pane while it is busy)
#   2. sends /compact to the tmux session the agent runs in
#   3. watches the transcript for a new compact boundary (`subtype == compact_boundary` or `isCompactSummary`)
#   4. sends the continuation line - argument 1, or a default - so the fresh context starts working
#
# Usage, from inside the session, after the handover note is written:
#   (S=$(command -v setsid); $S nohup "$BRAIN_ROOT/scripts/self-compact.sh" "<first thing to do after the compact>" >/dev/null 2>&1 &)
#   (macOS has no setsid: $S is then empty and nohup alone starts it)
#
# Needs tmux: the session must run inside a tmux session, because "send keys to the pane" is the only
# channel a process outside the model has into a running Claude Code session. The session name comes from
# SELF_COMPACT_TMUX_SESSION, else <project>/.claude/self-compact-session (setup.sh writes it when you opt in),
# else the session that owns $TMUX_PANE (set when the agent itself was started inside tmux).
#
# SKIP_COMPACT=1   /compact was already issued by hand: skip step 2, only wait for the boundary and send the
#                  continuation line.
# SELF_COMPACT_PROJECT   the project directory the session runs in (default: CLAUDE_PROJECT_DIR, else $PWD).
#                  The transcript directory is derived from it the way Claude Code does:
#                  ~/.claude/projects/<path with every non-alphanumeric character replaced by "-">.
#
# Every step is logged with a timestamp to <agent-config-dir>/brain-kit-state/self-compact.log, and the first
# line ("started") is written immediately - an empty log used to be read as "it never ran". Waits: up to 30 min
# for the turn to end, up to 20 min for the boundary. A second copy for the same project exits at once with
# "already running" - two copies would send two /compact and two continuation lines. The lock is a pid file
# written by this script itself, checked against the live process's own command line, so the shell that
# launched the first copy (whose command line also contains this script's name) can never be mistaken for it.
#
# Exit codes: 1 no tmux / no session / no transcript . 2 the turn did not end in 30 min . 3 no boundary in
# 20 min (continuation NOT sent) . 4 another copy is running for this project (its continuation line was replaced
# by this launch's argument, if one was given).
set -u
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && { set -a; . "$CFG/brain-kit.env" 2>/dev/null; set +a; }
PROJECT="${SELF_COMPACT_PROJECT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
PROJECT="${PROJECT%/}"
SLUG=$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9' '-')
PROJ_DIR="$CFG/projects/$SLUG"
ST="$CFG/brain-kit-state"; mkdir -p "$ST"
LOG="$ST/self-compact.log"
PIDF="$ST/self-compact.$SLUG.pid"
LINEF="$ST/self-compact.$SLUG.line"   # the continuation line the running copy will send; a later launch overwrites it
LASTF="$ST/self-compact.$SLUG.last"   # the line that was actually sent, for hooks that need to tell it from a human message
DEFAULT_CONT="self-compact done: you compacted your own session; nobody is waiting on you. Read the handover note and the focus file, then continue from the NEXT step written there without asking whether to start."
CONT="${1:-$DEFAULT_CONT}"
say(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
fail(){ say "$1"; printf 'self-compact: %s\n' "$1" >&2; exit "$2"; }

# The continuation line goes through a file, so the LATEST launch decides what is sent. Measured: a first copy
# launched with an early line waited 5 minutes for the turn to end; a second launch with the current line hit the
# lock and exited; the stale line was sent. Now the second launch drops its line here and the running copy reads
# the file right before sending.
[ -n "${1:-}" ] && printf '%s' "$1" > "$LINEF"
# double-launch lock: only a live process whose own command line is this script counts
if [ -f "$PIDF" ]; then
  q=$(tr -cd '0-9' < "$PIDF")
  if [ -n "$q" ] && [ "$q" != "$$" ] && kill -0 "$q" 2>/dev/null \
     && ps -o args= -p "$q" 2>/dev/null | grep -qE '(^|/)(bash|sh) [^ ]*self-compact\.sh( |$)|^[^ ]*self-compact\.sh( |$)'; then
    fail "already running for $PROJECT (pid $q), this copy exits${1:+; continuation line updated}" 4
  fi
fi
printf '%s\n' "$$" > "$PIDF"
trap 'rm -f "$PIDF" "$LINEF"' EXIT

command -v tmux >/dev/null 2>&1 || fail "tmux not found - self-compact needs the session to run inside tmux" 1
S="${SELF_COMPACT_TMUX_SESSION:-}"
[ -n "$S" ] || { [ -f "$PROJECT/.claude/self-compact-session" ] && S=$(head -1 "$PROJECT/.claude/self-compact-session" | tr -d '[:space:]'); }
[ -n "$S" ] || { [ -n "${TMUX_PANE:-}" ] && S=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null); }
[ -n "$S" ] || fail "no tmux session name: set SELF_COMPACT_TMUX_SESSION or write it to $PROJECT/.claude/self-compact-session" 1
tmux has-session -t "$S" 2>/dev/null || fail "tmux session '$S' not found" 1
T="$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | grep -v '/agent-' | head -1)"
[ -n "$T" ] || fail "no transcript under $PROJ_DIR - is $PROJECT the directory the session was started in?" 1
say "started: project=$PROJECT session=$S transcript=$(basename "$T") skip_compact=${SKIP_COMPACT:-0} pid=$$"

# boundaries are counted from the JSON fields, never by text search: a session's own tool output can carry
# the string "compact_boundary" in the transcript (found the hard way: a count of 50 on a fresh session)
boundaries(){ python3 -c 'import json,sys
n=0
for ln in open(sys.argv[1],encoding="utf-8",errors="replace"):
    try: d=json.loads(ln)
    except Exception: continue
    if d.get("subtype")=="compact_boundary" or d.get("isCompactSummary"): n+=1
print(n)' "$1" 2>/dev/null || echo 0; }
send(){ tmux send-keys -t "$S" -l "$1" && tmux send-keys -t "$S" Enter; }
busy(){ tmux capture-pane -p -t "$S" 2>/dev/null | tail -6 | grep -q 'esc to interrupt'; }

N0=$(boundaries "$T"); N0=${N0:-0}
sleep "${SELF_COMPACT_GRACE:-20}"                              # the launching turn is still finishing
i=0; while busy && [ $i -lt 360 ]; do sleep 5; i=$((i+1)); done  # 30 min
busy && fail "the turn did not end within 30 min, giving up" 2
if [ "${SKIP_COMPACT:-0}" = "1" ]; then
  say "SKIP_COMPACT=1: /compact not sent, waiting for the boundary (boundaries so far: $N0)"
else
  send "/compact" || fail "tmux send-keys failed" 1
  say "/compact sent (boundaries so far: $N0)"
fi
N1=$N0; i=0
while [ $i -lt 240 ]; do sleep 5; i=$((i+1))                    # 20 min
  T2="$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | grep -v '/agent-' | head -1)"
  N1=$(boundaries "$T"); [ "$T" = "$T2" ] || N1=$(( ${N1:-0} + $(boundaries "$T2") ))
  [ "${N1:-0}" -gt "$N0" ] && ! busy && break
done
[ "${N1:-0}" -gt "$N0" ] || fail "no compact boundary within 20 min, continuation line NOT sent" 3
sleep 5
[ -s "$LINEF" ] && CONT="$(cat "$LINEF")"
printf '%s' "$CONT" > "$LASTF"
send "$CONT" || fail "tmux send-keys failed after the compact" 1
say "compact done, continuation line sent"
