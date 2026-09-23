#!/usr/bin/env bash
# brain_index_sweep.sh - fill in the vectors the write hook no longer computes.
#
# Since 23 Sep 2026 hooks/brain-embed-after-write.sh only chunks a written note and updates the BM25 rows
# (about 1 s); loading BGE-M3 on every edit cost 14 s per write on the tool path. This sweeper runs
# `brain_index.py update --embed` in the background instead: started by the hook right after a write
# that left a chunk without a vector, and by a timer every 2 minutes (scripts/systemd/, installed by
# setup.sh; a cron line does the same). The timer also catches notes written by anything that is not a
# hook: another machine syncing into the vault, an editor, a script.
#
# Same mkdir lock as the hook (<vault>/.index/.embed.lock). Lock held: exit quietly, the next run gets
# it. A lock older than 30 minutes is a crash leftover and is removed. Nothing to embed: no log line.
# Log: <agent-config-dir>/brain-kit-state/index_sweep.log - one line per run that changed something or
# failed. BRAIN_EMBED=0 (setup.sh --no-embed): exit 0, there is no encoder to run.
#
# Config: BRAIN_ROOT, BRAIN_DIR, BRAIN_EMBED, BRAIN_SWEEP_THREADS (torch/BLAS threads; the default of
# "every core" spins all of them for a worse time - 64 chunks took 10.1 s on 24 threads, 8.8 s on 16).
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && . "$CFG/brain-kit.env"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
export BRAIN_ROOT BRAIN_DIR
[ "${BRAIN_EMBED:-1}" != "0" ] || exit 0
PY="$BRAIN_ROOT/.venv/bin/python"
[ -x "$PY" ] || exit 0
LOCK="$VAULT/.index/.embed.lock"; L="$CFG/brain-kit-state/index_sweep.log"
mkdir -p "$VAULT/.index" "$(dirname "$L")"
find "$LOCK" -maxdepth 0 -type d -mmin +30 -exec rmdir {} \; 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
export TOKENIZERS_PARALLELISM=false BRAIN_INSTANCE="${BRAIN_INSTANCE:-sweep}"
# a cached model never needs the hub; without this a timer run on an offline box waits on a connect timeout
[ -d "${HF_HOME:-$HOME/.cache/huggingface}/hub" ] && export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
T="${BRAIN_SWEEP_THREADS:-4}"; export OMP_NUM_THREADS="$T" MKL_NUM_THREADS="$T" OPENBLAS_NUM_THREADS="$T"
R=$(cd "$BRAIN_ROOT" && nice -n 10 "$PY" scripts/brain_index.py update --embed 2>&1 | grep -aoE "brain.db:.*|Traceback.*|[A-Za-z]*Error.*" | tail -1)
case "$R" in
  *"(0 changed, 0 removed)"*"embedded: "*) echo "$(date '+%F %T') $R" >> "$L" ;;   # the hook chunked it, we vectorised it
  *"(0 changed, 0 removed)"*) ;;                                                     # quiet run
  *) echo "$(date '+%F %T') ${R:-NO OUTPUT}" >> "$L" ;;
esac
exit 0
