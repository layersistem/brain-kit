#!/bin/bash
# PostToolUse (Write|Edit) - keep the SQLite index (brain_index.py) fresh whenever a note is
# written, so both BM25 and semantic search see it on the very next prompt. Hash-incremental:
# only the changed file is re-read and re-tokenized. With embeddings installed this also encodes
# the new/changed sections locally (CPU, no API); with `setup.sh --no-embed` it still updates the
# BM25/FTS side (BRAIN_EMBED=0 just drops the --embed flag, it does not skip the hook).
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_EMBED (0 = BM25-only update, no encoder), BRAIN_ISOLATE_DIRS.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
export BRAIN_ROOT BRAIN_DIR
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
PY="$BRAIN_ROOT/.venv/bin/python"
[ -x "$PY" ] || exit 0
EMBED_FLAG=""
[ "${BRAIN_EMBED:-1}" != "0" ] && EMBED_FLAG="--embed"
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
case "$FP" in
  "$VAULT"/*.md|*/.claude/projects/*/memory/*.md)
    # Fixed cd: the hook inherits the session cwd, which may be unreadable and crash the child.
    # Race lock (mkdir is atomic; no flock on macOS): two Edits landing close together can both
    # trigger this hook and race to write brain.db at once. SQLite itself serializes writers, but
    # two concurrent `update` passes would still re-read the same changed file twice for nothing.
    # Wait up to 30s for the lock; if it's still held, skip this run - the next write's update is
    # hash-incremental and closes the gap.
    LOCK="$VAULT/.index/.embed.lock"
    n=0
    while ! mkdir "$LOCK" 2>/dev/null; do
      n=$((n+1))
      if [ "$n" -ge 30 ]; then
        jq -n '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"brain index: SKIPPED (lock held 30s - next write will catch up)"}}'
        exit 0
      fi
      sleep 1
    done
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    R=$(cd "$BRAIN_ROOT" && "$PY" scripts/brain_index.py update $EMBED_FLAG 2>&1 | grep -aoE "brain.db:.*" | tail -1)
    [ -z "$R" ] && R="index did NOT update (showing the truth, not a fake success)"
    jq -n --arg c "brain index: $R" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
    ;;
esac
exit 0
