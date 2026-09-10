#!/bin/bash
# _instance.sh - sourced by the other hooks. Resolves which instance this session is.
#
# Resolution order (added 2026-09-10, when two instances had to share one folder):
#   1. the identity bound to THIS session's process by session-instance-bind.sh
#      (~/.claude/brain-kit-state/session-instance/pid-<claude pid>)
#   2. the BRAIN_INSTANCE environment variable
#   3. the nearest .brain-instance file walking up from the project dir
#
# Why the process: hooks and the Bash tool are both descendants of the one `claude`
# process that is this session, so its pid is the only key that is per-session
# rather than per-folder. Walk-up alone gives two sessions in one folder the same
# name, and they then write over each other's focus and notes.
STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state/session-instance"

claude_pid() {
  local p=$$ c n=0
  while [ -n "$p" ] && [ "$p" != "1" ] && [ $n -lt 12 ]; do
    c=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$c" in */claude|claude) printf '%s' "$p"; return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); n=$((n+1))
  done
  return 1
}

pid_instance() {
  local p f; p=$(claude_pid) || return 1
  f="$STATE_DIR/pid-$p"
  [ -f "$f" ] && tr -cd 'a-zA-Z0-9_-' < "$f"
}

brain_instance() {
  local i d="${CLAUDE_PROJECT_DIR:-$PWD}"
  i="$(pid_instance 2>/dev/null)"; [ -z "$i" ] && i="${BRAIN_INSTANCE:-}"
  if [ -z "$i" ]; then
    while [ "$d" != "/" ] && [ -n "$d" ]; do
      if [ -f "$d/.brain-instance" ]; then i=$(head -1 "$d/.brain-instance" | tr -d "[:space:]"); break; fi
      d=$(dirname "$d")
    done
  fi
  printf '%s' "${i:-unknown}"
}
