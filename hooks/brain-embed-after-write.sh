#!/bin/bash
# PostToolUse (Write|Edit) - re-embed the vault whenever a note is written, so semantic search
# never goes stale. Hash-incremental: only the changed file is re-encoded. Local CPU, no API.
# Quietly does nothing when embeddings are not installed (setup.sh --no-embed).
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_EMBED (0 disables), BRAIN_ISOLATE_DIRS.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
export BRAIN_ROOT BRAIN_DIR
[ "${BRAIN_EMBED:-1}" = "0" ] && exit 0
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
PY="$BRAIN_ROOT/.venv/bin/python"
[ -x "$PY" ] || exit 0
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
case "$FP" in
  "$VAULT"/*.md|*/.claude/projects/*/memory/*.md)
    # Fixed cd: the hook inherits the session cwd, which may be unreadable and crash the child.
    R=$(cd "$BRAIN_ROOT" && "$PY" scripts/brain_embed.py 2>&1 | grep -aoE "OK -.*" | tail -1)
    [ -z "$R" ] && R="embed did NOT run (showing the truth, not a fake success)"
    jq -n --arg c "brain embed: $R" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
    ;;
esac
exit 0
