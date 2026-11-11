#!/bin/bash
. "$(dirname "$0")/_dryrun.sh"   # dry-run layer: HOOK_DRY_RUN=1 -> report instead of block
# PostToolUse (Write|Edit) - vault hygiene, three checks on the file just written, all report-only:
#   (a) the note just written is 0 bytes (an empty note is a ghost node in a graph view)
#   (b) [[wikilinks]] IN THE FILE JUST WRITTEN that point at a note which does not exist
#   (c) the note just written has no [[links]] at all (an orphan lands disconnected in the graph)
# All three are about the vault staying navigable; nothing else here is enforced, and nothing is deleted.
# Returns decision:block with a reason, so the agent fixes it instead of moving on. With BRAIN_EXPECT=1 a fourth one,
# (d), looks at the text the write put in and never blocks (see BRAIN_EXPECT below).
#
# 1.2.0: (a) used to delete every 0-byte *.md in the whole vault on each write (a placeholder in another folder was
# removed in a test); it now only reports the file just written. Link targets are looked up in one list of note names
# built once per call; the old code ran one `find` over the vault per link (4.0 s per write at 1,000 notes, 19.7 s at
# 3,000, 45 s at 5,000). [[note#heading]], [[folder/note]] and [[note.md]] resolve to the note, as they do in Obsidian.
# Hidden folders (.trash, .obsidian, sync tools' version folders) are not notes: their files are neither link targets
# nor checked when written.
#
# Why (b) scans only the written file (6 Sep 2026): the earlier vault-wide scan printed the same stale
# list on every write - an alarm nobody could clear, so it was ignored and the rule rotted. The vault-wide
# count is still shown, but as a background figure the writer is not asked to fix right now.
# Code is not a link: fenced blocks and inline backticks are stripped before scanning, and POSIX classes
# like [[:space:]] inside shell snippets are skipped.
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_ISOLATE_DIRS.
#         BRAIN_ORPHAN_EXEMPT - space separated dir names where linkless files are fine by design
#                               (default: "_drafts _archive refs focus"; raw agent output, scratch, working files)
#         BRAIN_WRITING_RULE  - optional path/name of your note-writing rule, quoted in the orphan message
#         BRAIN_POSTWRITE_BUDGET - seconds the vault-wide passes may take together (default 5, 0 = no limit; #17)
#         BRAIN_EXPECT        - `1` adds (d), a reminder that never blocks (issues #18, #19; off by default): when the
#                               text just written to a decision record, a knowledge note, a hub note (moc/) or a focus
#                               file holds prediction wording (BRAIN_EXPECT_RX) and no `@expect` marker, one sentence
#                               goes out as additionalContext, at most once per instance in 15 minutes. The definition
#                               lives in _expect_remind.sh; without that file (d) stays silent. It rides along with a
#                               block that (a)-(c) raise and never turns a clean write into one. Unset or any other
#                               value: (d) is off and adds nothing to the output.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0
case "$FP" in "$VAULT"/*) ;; *) exit 0 ;; esac
case "${FP#"$VAULT"/}" in .*|*/.*) exit 0 ;; esac

# Vault-wide work has a time budget (issue #17). Two passes read the whole vault: the list of note names (for the ghost
# check) and the vault-wide ghost count (for the background figure). On storage where opening a file is slow (a network
# mount, a cloud-synced folder) they cost one open per note on every write: a vault of about 2,900 notes on a network
# mount took 72 s for the name list alone and had not finished the count after 5 minutes, so no check reached the
# model. Now the checks that need only the written file (empty note, orphan) need no pass of their own; the count is
# made only when there is something to report (the figure is printed only then), the name list only when the written
# file has links or the count needs it, and both share one budget, so a report waits at most that long. When it runs
# out, the pass is stopped, the ghost check or the count is skipped for this write, one line says so, and the passes
# are not tried again on this machine for an hour (state in <agent-config-dir>/brain-kit-state/postwrite-slow): an
# alarm that repeats on every write is one nobody reads. On a fast disk the output is byte-identical to 1.5.0.
# The budget is read in base 10 ("08" is 8) and has at most five digits; anything else counts as 5.
BUDGET="${BRAIN_POSTWRITE_BUDGET:-5}"; case "$BUDGET" in ''|*[!0-9]*) BUDGET=5 ;; esac
BUDGET="${BUDGET#"${BUDGET%%[!0]*}"}"; BUDGET="${BUDGET:-0}"; [ "${#BUDGET}" -gt 5 ] && BUDGET=5
SLOWF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state/postwrite-slow"
vault_ok=0; over=0; expired=0; TMPD=""; WD=""; PASS=""; FILES=""; NAMES=""; OUT=""
if [ "$BUDGET" -gt 0 ] && [ -f "$SLOWF" ]; then
  last=$(cat "$SLOWF" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(date +%s) - last )) -lt 3600 ] && vault_ok=2   # over budget within the hour: skip the passes quietly
fi
# Before the first pass: a temp dir for the passes' output and one watchdog for the whole budget, a subshell that
# sleeps BUDGET seconds once and then sends this hook USR1. That is real elapsed time; bash's SECONDS steps at the
# wall clock's second boundaries, so a 1 s budget counted with it could end at once. Told to stop (TERM), the watchdog
# stops its own sleep; no pkill on that path, since pkill reads every process on the machine (about 0.1 s with 850).
# The USR1 trap stops the running pass itself, wherever the hook is when the signal comes (not only inside `wait`), and
# the exit trap does the same, so a hook that is itself killed (TERM) leaves no pass behind.
_tmpdir() {
  [ -n "$TMPD" ] || [ "$BUDGET" -eq 0 ] && return 0
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/postwrite.XXXXXX" 2>/dev/null) || return 0
  trap 'expired=1; _stop_pass' USR1; trap '_stop_pass; _unwatch; rm -rf "$TMPD"' EXIT
  { ( s=""; trap '[ -n "$s" ] && kill "$s"; exit 0' TERM; sleep "$BUDGET" & s=$!
      wait "$s" && kill -USR1 $$ ) >/dev/null 2>&1 & } 2>/dev/null
  WD=$!
}
_unwatch() { [ -n "$WD" ] && { kill "$WD"; wait "$WD"; } 2>/dev/null; WD=""; }
_stop_pass() { [ -n "$PASS" ] && { pkill -P "$PASS"; kill "$PASS"; } 2>/dev/null; PASS=""; }
# _bounded IN CMD...: CMD's stdout into OUT, stdin from the file IN; 1 when the budget ran out first. The USR1 trap stops
# the pass together with its children, which also ends the wait. `expired` is read once more after the fork: the trap
# may have run before PASS was set, and then nothing was stopped yet. Without a budget (or a temp dir) CMD simply runs,
# as in 1.5.0.
_bounded() {
  local in="$1" pid; shift; OUT=""
  if [ -z "$TMPD" ]; then OUT=$("$@" < "$in" 2>/dev/null); return 0; fi
  [ "$expired" = 1 ] && return 1
  { "$@" < "$in" > "$TMPD/out" 2>/dev/null & } 2>/dev/null
  pid=$!; PASS=$pid
  [ "$expired" = 1 ] || wait "$pid" 2>/dev/null
  if [ "$expired" = 1 ]; then _stop_pass; wait "$pid" 2>/dev/null; return 1; fi
  PASS=""; OUT=$(< "$TMPD/out"); return 0
}
# One list of the vault's notes, built at most once per call and only when a check needs it (portable find: no
# -printf, which BSD find lacks).
_names() {
  [ "$vault_ok" != 0 ] && return 0
  _tmpdir
  if _bounded /dev/null find "$VAULT" -mindepth 1 -name '.*' -prune -o -name '*.md' -type f -print; then
    FILES="$OUT"; NAMES=$(printf '%s\n' "$FILES" | sed 's#.*/##; s/\.md$//' | LC_ALL=C sort -u); vault_ok=1
  else
    vault_ok=2; over=1   # 1: the name list was stopped, 2: the count was
  fi
}
_strip_code() { awk '/^[[:space:]]*```/{f=!f;next} !f' "$1" 2>/dev/null | sed 's/`[^`]*`//g'; }
# Link names: [[note|alias]] and [[note#heading]] -> note; [[folder/note]] -> note; a trailing .md is dropped.
_links() { grep -hoE "\[\[[^]]+\]\]" 2>/dev/null | grep -vE '^\[\[:[a-z]+:\]\]$' \
  | sed -E 's/\[\[([^]|#]+).*/\1/; s#.*/##; s/\.md$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | LC_ALL=C sort -u; }

empty=""
case "$FP" in *.md) [ -f "$FP" ] && [ ! -s "$FP" ] && empty=$(basename "$FP") ;; esac
ghosts=""; LINKS=""
case "$FP" in *.md) [ -s "$FP" ] && LINKS=$(_strip_code "$FP" | _links) ;; esac
if [ -n "$LINKS" ]; then
  _names
  [ "$vault_ok" = 1 ] && ghosts=$(printf '%s\n' "$LINKS" | LC_ALL=C comm -23 - <(printf '%s\n' "$NAMES") | tr '\n' ' ')
fi

orphan=""
exempt=0
for d in ${BRAIN_ORPHAN_EXEMPT:-_drafts _archive refs focus}; do
  case "$FP" in */"$d"/*) exempt=1 ;; esac
done
case "$FP" in */CLAUDE.md|*/MEMORY.md|*/README.md) exempt=1 ;; esac  # instruction files are not notes
if [ "$exempt" -eq 0 ]; then
  case "$FP" in *.md) [ -s "$FP" ] && ! grep -q '\[\[' "$FP" && orphan=$(basename "$FP") ;; esac
fi

msg=""
[ -n "$empty" ] && msg="The note you just wrote is empty (0 bytes): $empty. An empty note is a ghost node in the graph; \
fill it or delete it yourself (nothing was deleted). "
[ -n "$ghosts" ] && msg="${msg}Ghost [[links]] in the file you just wrote - no such note in the vault, \
so they create empty nodes. Fix: make the reference plain text (or backticks, if it is an example), or create the note. Ghosts: $ghosts "
[ -n "$orphan" ] && msg="${msg}Orphan note: $orphan has no [[links]] at all, so it lands disconnected \
in the graph. Give it front matter and a closing 'Related' section with 2-5 links to notes that exist, one of them \
its hub.${BRAIN_WRITING_RULE:+ Rule: $BRAIN_WRITING_RULE.} "
# The vault-wide count is only ever printed after a report, so it is only computed then.
if [ -n "$msg" ]; then
  _names
  if [ "$vault_ok" = 1 ] && [ -n "$FILES" ]; then
    if [ -n "$TMPD" ]; then
      printf '%s\n' "$FILES" | tr '\n' '\000' > "$TMPD/files0"
      _bounded "$TMPD/files0" xargs -0 grep -hoE "\[\[[^]]+\]\]" || over=2
    else
      OUT=$(printf '%s\n' "$FILES" | tr '\n' '\000' | xargs -0 grep -hoE "\[\[[^]]+\]\]" 2>/dev/null)
    fi
    if [ "$over" = 0 ]; then
      ghosts_all=$(printf '%s\n' "$OUT" | _links | LC_ALL=C comm -23 - <(printf '%s\n' "$NAMES") | wc -l | tr -d ' ')
      [ "${ghosts_all:-0}" -gt 0 ] && msg="${msg}(Vault-wide ghost targets, background only: $ghosts_all.)"
    fi
  fi
fi
_unwatch
slow=""
if [ "$over" != 0 ]; then
  what="vault-wide ghost count"; [ "$over" = 1 ] && [ -n "$LINKS" ] && what="ghost-link check"
  slow="postwrite-check: the vault-wide pass did not finish within $BUDGET s (slow storage?). The $what was skipped \
for this write, and the vault-wide passes will not be tried again on this machine for an hour; the empty-note and \
orphan checks ran."
fi
_slow_seen() { mkdir -p "$(dirname "$SLOWF")" 2>/dev/null; date +%s > "$SLOWF" 2>/dev/null; }
[ -n "$msg" ] && dry_guard "postwrite-check" "vault-hygiene"

# (d) Expectation reminder, BRAIN_EXPECT=1 only, on the text this write put in (content, or new_string for an Edit).
# After the dry-run exit, so a reported block leaves the quiet period untouched.
expect=""
if [ "${BRAIN_EXPECT:-0}" = 1 ] && [ -f "$(dirname "$0")/_expect_remind.sh" ]; then
  case "$FP" in "$VAULT"/decision/*.md|"$VAULT"/knowledge/*.md|"$VAULT"/moc/*.md|"$VAULT"/focus/*.txt)
    . "$(dirname "$0")/_expect_remind.sh"; . "$(dirname "$0")/_instance.sh" 2>/dev/null
    expect=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null \
             | expect_remind "$(basename "$FP")" 2>/dev/null) ;;
  esac
fi

# After the report, in this order: the slow-storage line (#17), then the reminder (d). With no report, both go out
# together as context.
if [ -n "$msg" ]; then
  [ -n "$slow" ] && msg="${msg%"${msg##*[! ]}"} $slow (Budget: BRAIN_POSTWRITE_BUDGET.)"
  [ -n "$expect" ] && msg="${msg% } $expect"
  [ -n "$slow" ] && _slow_seen
  jq -n --arg r "$msg" '{decision:"block",reason:$r}'
elif [ -n "$slow$expect" ]; then
  ctx=""
  [ -n "$slow" ] && { _slow_seen; ctx="$slow Not a block; carry on. (Budget: BRAIN_POSTWRITE_BUDGET.)"; }
  [ -n "$expect" ] && ctx="${ctx:+$ctx }$expect"
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
fi
exit 0
