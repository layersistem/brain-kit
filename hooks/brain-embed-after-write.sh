#!/bin/bash
# PostToolUse (Write|Edit) - keep the SQLite index (brain_index.py) fresh whenever a note is
# written, so both BM25 and semantic search see it on the very next prompt. Hash-incremental:
# only the changed file is re-read and re-tokenized.
#
# Fast path (23 Sep 2026): the hook no longer loads the embedding model. Measured over 24 hours of
# transcripts on the author's install: 1453 runs, the ones with a changed file averaged 14.4 s (max 50 s)
# against 0.6 s for the unchanged ones - the whole difference was BGE-M3 being loaded from scratch on
# every edit, 330 minutes a day of the model waiting on its own write hook, all of it on the tool path.
# Now the hook runs `brain_index.py update` without --embed (chunks + BM25 rows, about 1 s; BM25 recall
# sees the note at once) and hands the vectors to a background sweeper: scripts/brain_index_sweep.sh,
# started here when a chunk is left without a vector, and also by the 2-minute timer setup.sh installs
# (scripts/systemd/). Dense recall lags the write by roughly 15 s instead of the write costing 15 s.
# BRAIN_EMBED_SYNC=1 restores the old inline embed for a machine with no timer and no patience.
# With `setup.sh --no-embed` (BRAIN_EMBED=0) the hook still updates the BM25/FTS side and starts nothing.
#
# 1.2.0: the lock wait is 3 s, not 30 (measured before: 29.1 s of waiting, then a skip). The sweeper now holds the
# shared lock only for its own `update` (about a second) and encodes after releasing it, so a long wait means
# something is stuck; the hook then starts the sweeper and reports the write as deferred. macOS has no setsid: the
# sweeper is started with nohup there (setup.sh installs a launchd agent for the 2-minute round on macOS).
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_EMBED (0 = BM25-only update, no encoder), BRAIN_EMBED_SYNC,
#         BRAIN_ISOLATE_DIRS.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
export BRAIN_ROOT BRAIN_DIR
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
PY="$BRAIN_ROOT/.venv/bin/python"
[ -x "$PY" ] || exit 0
EMBED_FLAG=""
[ "${BRAIN_EMBED:-1}" != "0" ] && [ "${BRAIN_EMBED_SYNC:-0}" = "1" ] && EMBED_FLAG="--embed"
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SW="$BRAIN_ROOT/scripts/brain_index_sweep.sh"
start_sweeper(){
  # the systemd unit only when it is THIS install's (setup.sh writes ExecStart with this BRAIN_ROOT);
  # a unit of the same name from another install on the machine is not ours to start
  UNIT="$HOME/.config/systemd/user/brain-index-sweep.service"
  if [ -f "$UNIT" ] && grep -qF "$SW" "$UNIT" 2>/dev/null && command -v systemctl >/dev/null 2>&1; then
    systemctl --user start --no-block brain-index-sweep.service 2>/dev/null
  elif [ -x "$SW" ]; then
    if command -v setsid >/dev/null 2>&1; then (setsid nohup bash "$SW" >/dev/null 2>&1 &)
    else (nohup bash "$SW" >/dev/null 2>&1 &); fi   # macOS: no setsid
  fi
}
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
case "$FP" in
  "$VAULT"/*.md|*/.claude/projects/*/memory/*.md)
    # Fixed cd: the hook inherits the session cwd, which may be unreadable and crash the child.
    # Race lock (mkdir is atomic; no flock on macOS): two Edits landing close together can both
    # trigger this hook and race to write brain.db at once. SQLite itself serializes writers, but
    # two concurrent `update` passes would still re-read the same changed file twice for nothing.
    # The sweeper takes the same lock for its own `update`. Wait up to 3 s (12 x 0.25 s); if it is still held,
    # start the sweeper and skip this run - the sweeper's next round, or the next write's hash-incremental
    # update, closes the gap.
    LOCK="$VAULT/.index/.embed.lock"
    n=0
    while ! mkdir "$LOCK" 2>/dev/null; do
      n=$((n+1))
      if [ "$n" -gt 12 ]; then
        W="the next write's update catches up"
        [ "${BRAIN_EMBED:-1}" != "0" ] && { start_sweeper; W="the sweeper was started; its next round or the next write indexes this one"; }
        jq -n --arg c "brain index: DEFERRED (lock held 3 s - $W)" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
        exit 0
      fi
      sleep 0.25
    done
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    R=$(cd "$BRAIN_ROOT" && "$PY" scripts/brain_index.py update $EMBED_FLAG 2>&1 | grep -aoE "brain.db:.*" | tail -1)
    rmdir "$LOCK" 2>/dev/null; trap - EXIT   # released BEFORE the sweeper starts, or it finds the lock held
    [ -z "$R" ] && R="index did NOT update (showing the truth, not a fake success)"
    TAIL=""
    if [ "${BRAIN_EMBED:-1}" != "0" ] && [ -z "$EMBED_FLAG" ]; then
      case "$R" in
        *"missing embeddings: 0"*) ;;
        *) start_sweeper
           TAIL=" (vectors: background sweeper, ~15 s)" ;;
      esac
    fi
    jq -n --arg c "brain index: $R$TAIL" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
    ;;
esac
exit 0
