#!/usr/bin/env bash
# brain_index_sweep.sh - fill in the vectors the write hook no longer computes.
#
# Since 23 Sep 2026 hooks/brain-embed-after-write.sh only chunks a written note and updates the BM25 rows
# (about 1 s); loading BGE-M3 on every edit cost 14 s per write on the tool path. This sweeper computes
# the vectors in the background instead: started by the hook right after a write that left a chunk
# without a vector, and by a timer every 2 minutes (scripts/systemd/, installed by setup.sh; on macOS
# setup.sh installs a launchd agent, and a cron line does the same). The timer also catches notes written by anything that is not a
# hook: another machine syncing into the vault, an editor, a script.
#
# Two steps, two mkdir locks (1.2.0). `brain_index.py update` (chunks and BM25 rows, about a second) runs under
# the lock the write hook shares (<vault>/.index/.embed.lock); held by the hook = that step is skipped, the hook
# is doing it. The vectors (`brain_index.py embed`: model load and encoding) run after that lock is released, so
# the hook no longer waits behind a whole encode (it waited up to 30 s, 29.1 s measured, and one note's round took
# 12.1 s and 2.4 GB of memory). <vault>/.index/.sweep.lock keeps a second sweeper - the timer and the hook can both
# start one - from loading a second copy of the model: held = exit quietly. The vector step has a round budget
# (BRAIN_EMBED_BUDGET seconds, default 110, under the 2-minute timer; a value that is not a number means 110 and a
# warning in the log) and commits every batch of 16, so a long backlog fills over several rounds and a killed
# round keeps what it wrote. A manual `brain_index.py build|update --embed` has no budget and fills everything.
# A lock older than 30 minutes is a crash leftover and is removed. Nothing to do: no log line.
# Log: <agent-config-dir>/brain-kit-state/index_sweep.log - one line per run that changed something or
# failed. BRAIN_EMBED=0 (setup.sh --no-embed): exit 0, there is no encoder to run.
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_EMBED, BRAIN_EMBED_BUDGET, BRAIN_SWEEP_THREADS (torch/BLAS threads; the
# default of "every core" spins all of them for a worse time - 64 chunks took 10.1 s on 24 threads, 8.8 s on 16).
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && { set -a; . "$CFG/brain-kit.env"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
export BRAIN_ROOT BRAIN_DIR
[ "${BRAIN_EMBED:-1}" != "0" ] || exit 0
PY="$BRAIN_ROOT/.venv/bin/python"
[ -x "$PY" ] || exit 0
LOCK="$VAULT/.index/.embed.lock"; SWL="$VAULT/.index/.sweep.lock"; L="$CFG/brain-kit-state/index_sweep.log"
mkdir -p "$VAULT/.index" "$(dirname "$L")"
find "$LOCK" "$SWL" -maxdepth 0 -type d -mmin +30 -exec rmdir {} \; 2>/dev/null
mkdir "$SWL" 2>/dev/null || exit 0
HELD=""
cleanup(){ [ -n "$HELD" ] && rmdir "$HELD" 2>/dev/null; rmdir "$SWL" 2>/dev/null; }
trap cleanup EXIT
export TOKENIZERS_PARALLELISM=false BRAIN_INSTANCE="${BRAIN_INSTANCE:-sweep}"
# a cached model never needs the hub; without this a timer run on an offline box waits on a connect timeout
[ -d "${HF_HOME:-$HOME/.cache/huggingface}/hub" ] && export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
T="${BRAIN_SWEEP_THREADS:-4}"; export OMP_NUM_THREADS="$T" MKL_NUM_THREADS="$T" OPENBLAS_NUM_THREADS="$T"
R="update skipped (the write hook holds the lock)"
if mkdir "$LOCK" 2>/dev/null; then
  HELD="$LOCK"
  R=$(cd "$BRAIN_ROOT" && nice -n 10 "$PY" scripts/brain_index.py update 2>&1 | grep -aoE "brain.db:.*|Traceback.*|[A-Za-z]*Error.*" | tail -1)
  rmdir "$LOCK" 2>/dev/null; HELD=""
fi
E=$(cd "$BRAIN_ROOT" && nice -n 10 "$PY" scripts/brain_index.py embed 2>&1 | grep -aoE "brain.db embed:.*|Traceback.*|[A-Za-z]*Error.*" | tail -1)
case "$R|$E" in
  *"(0 changed, 0 removed)"*"|brain.db embed: missing 0"*|"update skipped"*"|brain.db embed: missing 0"*) ;;   # quiet run
  *) echo "$(date '+%F %T') ${R:-NO OUTPUT} | ${E:-VECTOR STEP: NO OUTPUT}" >> "$L" ;;
esac
exit 0
