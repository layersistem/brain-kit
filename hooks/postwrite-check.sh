#!/bin/bash
. "$(dirname "$0")/_dryrun.sh"   # dry-run layer: HOOK_DRY_RUN=1 -> report instead of block
# PostToolUse (Write|Edit) - vault hygiene, three checks only, all on the file just written and all report-only:
#   (a) the note just written is 0 bytes (an empty note is a ghost node in a graph view)
#   (b) [[wikilinks]] IN THE FILE JUST WRITTEN that point at a note which does not exist
#   (c) the note just written has no [[links]] at all (an orphan lands disconnected in the graph)
# All three are about the vault staying navigable; nothing else here is enforced, and nothing is deleted.
# Returns decision:block with a reason, so the agent fixes it instead of moving on.
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
# model. Now the checks that need only the written file (empty note, orphan) need no pass; the name list is built only
# when the written file has links, the count only when there is something to report (the figure is printed only
# then), and both share one budget. When it runs out, the pass is stopped, the ghost check is skipped for this write,
# one line says so, and the passes are not tried again on this machine for an hour (state in
# <agent-config-dir>/brain-kit-state/postwrite-slow): an alarm that repeats on every write is one nobody reads. On a
# fast disk the output is byte-identical to 1.5.0.
BUDGET="${BRAIN_POSTWRITE_BUDGET:-5}"; case "$BUDGET" in ''|*[!0-9]*) BUDGET=5 ;; esac
SLOWF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state/postwrite-slow"
DEADLINE=$((SECONDS + BUDGET)); vault_ok=0; over=0; TMPD=""; FILES=""; NAMES=""; OUT=""
if [ "$BUDGET" -gt 0 ] && [ -f "$SLOWF" ]; then
  last=$(cat "$SLOWF" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(date +%s) - last )) -lt 3600 ] && vault_ok=2   # over budget within the hour: skip the passes quietly
fi
_tmpdir() {
  [ -n "$TMPD" ] || [ "$BUDGET" -eq 0 ] && return 0
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/postwrite.XXXXXX" 2>/dev/null) && trap 'rm -rf "$TMPD"' EXIT
}
# _bounded IN CMD...: CMD's stdout into OUT, stdin from the file IN, within what is left of the budget; 1 when it was
# stopped. The watchdog marks and stops only if its sleep ran out; a sleep killed early leaves no mark. When CMD ends in
# time the watchdog is told to stop its own sleep (a trap), not found with pkill: pkill reads every process on the
# machine (about 0.1 s with 850 processes). Without a budget (or a temp dir) CMD simply runs, as in 1.5.0.
_bounded() {
  local in="$1" left pid wd; shift; OUT=""
  if [ "$BUDGET" -eq 0 ] || [ -z "$TMPD" ]; then OUT=$("$@" < "$in" 2>/dev/null); return 0; fi
  left=$((DEADLINE - SECONDS)); [ "$left" -le 0 ] && return 1
  { "$@" < "$in" > "$TMPD/out" 2>/dev/null & } 2>/dev/null
  pid=$!
  { ( s=""; trap '[ -n "$s" ] && kill "$s"; exit 0' TERM; sleep "$left" & s=$!
      wait "$s" && { : > "$TMPD/stopped"; pkill -P "$pid"; kill "$pid"; } ) >/dev/null 2>&1 & } 2>/dev/null
  wd=$!
  wait "$pid" 2>/dev/null
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ -f "$TMPD/stopped" ] && return 1
  OUT=$(< "$TMPD/out"); return 0
}
# One list of the vault's notes, built at most once per call and only when a check needs it (portable find: no
# -printf, which BSD find lacks).
_names() {
  [ "$vault_ok" != 0 ] && return 0
  _tmpdir
  if _bounded /dev/null find "$VAULT" -mindepth 1 -name '.*' -prune -o -name '*.md' -type f -print; then
    FILES="$OUT"; NAMES=$(printf '%s\n' "$FILES" | sed 's#.*/##; s/\.md$//' | LC_ALL=C sort -u); vault_ok=1
  else
    vault_ok=2; over=1
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
      _bounded "$TMPD/files0" xargs -0 grep -hoE "\[\[[^]]+\]\]" || over=1
    else
      OUT=$(printf '%s\n' "$FILES" | tr '\n' '\000' | xargs -0 grep -hoE "\[\[[^]]+\]\]" 2>/dev/null)
    fi
    if [ "$over" = 0 ]; then
      ghosts_all=$(printf '%s\n' "$OUT" | _links | LC_ALL=C comm -23 - <(printf '%s\n' "$NAMES") | wc -l | tr -d ' ')
      [ "${ghosts_all:-0}" -gt 0 ] && msg="${msg}(Vault-wide ghost targets, background only: $ghosts_all.)"
    fi
  fi
fi
slow=""
[ "$over" = 1 ] && slow="postwrite-check: the vault-wide pass did not finish within $BUDGET s (slow storage?). The \
ghost-link check was skipped for this write and will not be tried again on this machine for an hour; the empty-note \
and orphan checks ran. Not a block; carry on. (Budget: BRAIN_POSTWRITE_BUDGET.)"
_slow_seen() { mkdir -p "$(dirname "$SLOWF")" 2>/dev/null; date +%s > "$SLOWF" 2>/dev/null; }
if [ -n "$msg" ]; then
  [ -n "$slow" ] && msg="${msg% } $slow"
  dry_guard "postwrite-check" "vault-hygiene"
  [ -n "$slow" ] && _slow_seen
  jq -n --arg r "$msg" '{decision:"block",reason:$r}'
elif [ -n "$slow" ]; then
  _slow_seen
  jq -n --arg c "$slow" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
fi
exit 0
