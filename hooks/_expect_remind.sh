#!/bin/bash
# _expect_remind.sh - sourced, not a hook and not wired into settings. The one definition of the expectation reminder
# (issues #18 and #19, BRAIN_EXPECT=1 only). postwrite-check.sh calls it after a note write; a script of your own that
# writes a status line or a ledger entry can call it after its write and shares the same quiet period.
#
#   . <brain root>/hooks/_expect_remind.sh
#   printf '%s' "$text_just_written" | expect_remind "<where it went>" [instance]
#
# Reads the text just written on stdin. Prints one sentence when the text holds prediction wording and no `@expect`
# marker, and nothing otherwise. Never blocks and changes nothing but its own state file.
#
# Why wording and not length (#19): a length trigger on decision records fired on 432 of 1,240 writes in three days and
# saw none of the predictions written elsewhere; a broad forward-looking pattern was right on 2 of 14 sampled matches.
# A short vocabulary is what separates a prediction from a task sentence or a description of how a mechanism behaves.
#
# - Pattern: BRAIN_EXPECT_RX (extended regex, case ignored), default below. Text inside fenced code, inline backticks
#   and double quotes is not scanned: an example or a quotation is not the writer's prediction.
# - Quiet period: at most one reminder per instance in 15 minutes. A write that carries `@expect` restarts the period,
#   so whoever has just written an expectation is not reminded. State: one epoch per instance in
#   <agent-config-dir>/brain-kit-state/expect-reminder/instance-<name>.
# - Instance: the second argument, else brain_instance from _instance.sh when it is loaded, else BRAIN_INSTANCE, else
#   "unknown". It is resolved only when a reminder or a restart is due, so a write with no match costs no process walk.
# - Context text: the fixed sentence, at most four matched words (40 characters each) and the place name.
EXPECT_RX_DEFAULT='expect|estimate|predict|likely|probably|should hold|to watch'

expect_remind() {
  local where="${1:-the vault}" inst="${2:-}" text found now last dir f
  [ "${BRAIN_EXPECT:-0}" = 1 ] || return 0
  text=$(cat)
  [ -n "$text" ] || return 0
  case "$text" in
    *@expect*) ;;
    *) found=$(printf '%s\n' "$text" | awk '/^[[:space:]]*```/{f=!f;next} !f' \
         | sed -e 's/`[^`]*`//g' -e 's/"[^"]*"//g' -e 's/“[^”]*”//g' \
         | grep -oiE "${BRAIN_EXPECT_RX:-$EXPECT_RX_DEFAULT}" 2>/dev/null \
         | awk '{k=tolower($0)} !g[k]++ {print substr($0, 1, 40)}' | head -4 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
       [ -n "$found" ] || return 0 ;;
  esac
  [ -n "$inst" ] || inst=$(brain_instance 2>/dev/null)
  [ -n "$inst" ] || inst="${BRAIN_INSTANCE:-unknown}"
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state/expect-reminder"
  f="$dir/instance-$(printf '%s' "$inst" | tr -cd 'a-zA-Z0-9_-')"
  now=$(date +%s)
  if [ -z "$found" ]; then   # the text carries @expect: restart the period, say nothing
    mkdir -p "$dir" 2>/dev/null; echo "$now" > "$f" 2>/dev/null; return 0
  fi
  last=$(cat "$f" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt 900 ] && return 0
  mkdir -p "$dir" 2>/dev/null; echo "$now" > "$f" 2>/dev/null
  printf '%s' "EXPECTATION (a reminder, not a block; carry on): what you just wrote to $where has prediction wording \
($found) and no @expect line. If it is a prediction, add one line to the work's own record now: @expect YYYY-MM-DD \
<what you expect to happen> · measure: <how it will show> · written: $(date +%F). If it is not, do nothing. (Not \
repeated for this instance within 15 minutes.)"
}
