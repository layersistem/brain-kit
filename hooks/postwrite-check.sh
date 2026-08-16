#!/bin/bash
# PostToolUse (Write|Edit) - vault hygiene, two checks only:
#   (a) 0-byte *.md stubs are deleted (an empty note is a ghost node in a graph view)
#   (b) [[wikilinks]] pointing at a note that does not exist are reported back for a fix
# Both are about the vault staying navigable; nothing else here is enforced.
# Returns decision:block with a reason, so the agent fixes it instead of moving on.
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_ISOLATE_DIRS.
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

ghosts=$(grep -rhoE "\[\[[^]]+\]\]" "$VAULT" --include="*.md" 2>/dev/null \
  | sed -E 's/\[\[([^]|]+).*/\1/' | sort -u | while read -r n; do
      n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
      [ -z "$n" ] && continue
      find "$VAULT" -name "$n.md" -type f 2>/dev/null | grep -q . || echo "$n"
    done | tr '\n' ' ')

msg=""
[ -n "$deleted" ] && msg="Empty 0-byte notes were deleted:$deleted. "
[ -n "$ghosts" ] && msg="${msg}Ghost [[links]] - no such note in the vault, so they create empty \
nodes. Fix: make the reference plain text, or create the note. Ghosts: $ghosts"
if [ -n "$msg" ]; then
  jq -n --arg r "$msg" '{decision:"block",reason:$r}'
fi
exit 0
