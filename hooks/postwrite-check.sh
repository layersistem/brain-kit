#!/bin/bash
# PostToolUse (Write|Edit) - vault hygiene, three checks only:
#   (a) 0-byte *.md stubs are deleted (an empty note is a ghost node in a graph view)
#   (b) [[wikilinks]] IN THE FILE JUST WRITTEN that point at a note which does not exist are reported back
#   (c) a note written with no [[links]] at all is reported back (an orphan lands disconnected in the graph)
# All three are about the vault staying navigable; nothing else here is enforced.
# Returns decision:block with a reason, so the agent fixes it instead of moving on.
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
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0
case "$FP" in "$VAULT"/*) ;; *) exit 0 ;; esac

deleted=""
while IFS= read -r f; do
  [ -n "$f" ] && rm -f "$f" && deleted="$deleted $(basename "$f" .md)"
done < <(find "$VAULT" -name "*.md" -type f -size 0 2>/dev/null)

_strip_code() { awk '/^[[:space:]]*```/{f=!f;next} !f' "$1" 2>/dev/null | sed 's/`[^`]*`//g'; }
_ghosts_of() {  # $1 = file to scan; prints link names with no matching note
  _strip_code "$1" | grep -hoE "\[\[[^]]+\]\]" 2>/dev/null | grep -vE '^\[\[:[a-z]+:\]\]$' \
    | sed -E 's/\[\[([^]|]+).*/\1/' | sort -u | while read -r n; do
        n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
        [ -z "$n" ] && continue
        find "$VAULT" -name "$n.md" -type f 2>/dev/null | grep -q . || echo "$n"
      done | tr '\n' ' '
}
ghosts=""
case "$FP" in *.md) [ -f "$FP" ] && ghosts=$(_ghosts_of "$FP") ;; esac
ghosts_all=$(grep -rhoE "\[\[[^]]+\]\]" "$VAULT" --include="*.md" 2>/dev/null \
  | grep -vE '^\[\[:[a-z]+:\]\]$' | sed -E 's/\[\[([^]|]+).*/\1/' | sort -u | while read -r n; do
      n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
      [ -z "$n" ] && continue
      find "$VAULT" -name "$n.md" -type f 2>/dev/null | grep -q . || echo x
    done | grep -c x)

orphan=""
exempt=0
for d in ${BRAIN_ORPHAN_EXEMPT:-_drafts _archive refs focus}; do
  case "$FP" in */"$d"/*) exempt=1 ;; esac
done
case "$FP" in */CLAUDE.md|*/MEMORY.md|*/README.md) exempt=1 ;; esac  # instruction files are not notes
if [ "$exempt" -eq 0 ]; then
  case "$FP" in *.md) [ -f "$FP" ] && ! grep -q '\[\[' "$FP" && orphan=$(basename "$FP") ;; esac
fi

msg=""
[ -n "$deleted" ] && msg="Empty 0-byte notes were deleted:$deleted. "
[ -n "$ghosts" ] && msg="${msg}Ghost [[links]] in the file you just wrote - no such note in the vault, \
so they create empty nodes. Fix: make the reference plain text (or backticks, if it is an example), or create the note. Ghosts: $ghosts "
[ -n "$orphan" ] && msg="${msg}Orphan note: $orphan has no [[links]] at all, so it lands disconnected \
in the graph. Give it front matter and a closing 'Related' section with 2-5 links to notes that exist, one of them \
its hub.${BRAIN_WRITING_RULE:+ Rule: $BRAIN_WRITING_RULE.} "
[ -n "$msg" ] && [ "${ghosts_all:-0}" -gt 0 ] && msg="${msg}(Vault-wide ghost targets, background only: $ghosts_all.)"
if [ -n "$msg" ]; then
  jq -n --arg r "$msg" '{decision:"block",reason:$r}'
fi
exit 0
