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

# One list of the vault's notes, built once per call (portable find: no -printf, which BSD find lacks).
FILES=$(find "$VAULT" -mindepth 1 -name '.*' -prune -o -name '*.md' -type f -print 2>/dev/null)
NAMES=$(printf '%s\n' "$FILES" | sed 's#.*/##; s/\.md$//' | LC_ALL=C sort -u)
_strip_code() { awk '/^[[:space:]]*```/{f=!f;next} !f' "$1" 2>/dev/null | sed 's/`[^`]*`//g'; }
# Link names: [[note|alias]] and [[note#heading]] -> note; [[folder/note]] -> note; a trailing .md is dropped.
_links() { grep -hoE "\[\[[^]]+\]\]" 2>/dev/null | grep -vE '^\[\[:[a-z]+:\]\]$' \
  | sed -E 's/\[\[([^]|#]+).*/\1/; s#.*/##; s/\.md$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | LC_ALL=C sort -u; }

empty=""
case "$FP" in *.md) [ -f "$FP" ] && [ ! -s "$FP" ] && empty=$(basename "$FP") ;; esac
ghosts=""
case "$FP" in *.md) [ -s "$FP" ] && ghosts=$(_strip_code "$FP" | _links | LC_ALL=C comm -23 - <(printf '%s\n' "$NAMES") | tr '\n' ' ') ;; esac
ghosts_all=0
[ -n "$FILES" ] && ghosts_all=$(printf '%s\n' "$FILES" | tr '\n' '\000' | xargs -0 grep -hoE "\[\[[^]]+\]\]" 2>/dev/null \
  | _links | LC_ALL=C comm -23 - <(printf '%s\n' "$NAMES") | wc -l | tr -d ' ')

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
[ -n "$msg" ] && [ "${ghosts_all:-0}" -gt 0 ] && msg="${msg}(Vault-wide ghost targets, background only: $ghosts_all.)"
if [ -n "$msg" ]; then
  dry_guard "postwrite-check" "vault-hygiene"
  jq -n --arg r "$msg" '{decision:"block",reason:$r}'
fi
exit 0
