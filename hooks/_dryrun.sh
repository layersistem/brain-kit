#!/bin/bash
# _dryrun.sh - dry-run layer for the hooks that can block (identical-answer-stop, postwrite-check).
#
# A hook that has never produced a red result is an untested claim, not a gate. This file lets you
# test a gate's negative case without it actually blocking: with HOOK_DRY_RUN set, the hook runs
# its full logic, and at the point where it would block it writes "DRY-RUN [hook] would have
# blocked: <reason>" to stderr, appends one line to the log, and exits 0 so the tool call goes on.
# With HOOK_DRY_RUN empty (the default) nothing changes.
#
#   HOOK_DRY_RUN=1 bash hooks/postwrite-check.sh < payload.json     # one-off test of a gate
#   HOOK_DRY_RUN=1 claude                                           # whole session, every gate silent
#
# Log: <agent-config-dir>/brain-kit-state/hook-dryrun.log, mode 600 - "which gate would have fired,
# on what" in one file. Two rules, both measured on 2026-09-09 before this shipped:
#   1. The REASON argument must never carry command text, argv or file contents - only a fixed label
#      or the hand-written block explanation. What ends up in the log is decided by tomorrow's edit,
#      not today's content; keep the log unable to hold a secret by construction.
#   2. Keep the log 600. A world-readable log is harmless while its lines are fixed text and becomes
#      a leak the day someone puts "$CMD" in a reason.
dry_guard() {
  [ -n "${HOOK_DRY_RUN:-}" ] || return 0
  local h="$1" r="$2" d cfg L
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  L="$cfg/brain-kit-state/hook-dryrun.log"
  d=$(date '+%Y-%m-%d %H:%M:%S')
  umask 077; mkdir -p "$cfg/brain-kit-state" 2>/dev/null
  printf '[%s] %s | %s\n' "$d" "$h" "${r:0:160}" >> "$L" 2>/dev/null; chmod 600 "$L" 2>/dev/null
  printf 'DRY-RUN [%s] would have blocked: %s\n' "$h" "${r:0:200}" >&2
  exit 0
}
