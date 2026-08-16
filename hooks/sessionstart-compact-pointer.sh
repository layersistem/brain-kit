#!/bin/bash
# SessionStart (matcher: compact) - first context after a compaction.
# Prints ADDRESSES, not content: the newest handoff decision record and the raw snapshot the
# PreCompact hook left behind, plus a reminder to re-read the skills that compaction dropped.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
INPUT=$(cat)
SRC=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("source",""))
except Exception: print("")' 2>/dev/null)
[ "$SRC" != "compact" ] && exit 0
I="${BRAIN_INSTANCE:-}"
if [ -z "$I" ]; then
  _d="$PWD"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -f "$_d/.brain-instance" ]; then I=$(head -1 "$_d/.brain-instance" | tr -d '[:space:]'); break; fi
    _d=$(dirname "$_d")
  done
fi
[ -z "$I" ] && [ -f "$VAULT/.brain-instance" ] && I=$(head -1 "$VAULT/.brain-instance" | tr -d '[:space:]')
[ -z "$I" ] && I="main"
SNAP="$VAULT/_drafts/compact_snapshot_$I.md"
HUB=$(ls -t "$VAULT"/decision/DR-*handoff*.md "$VAULT"/decision/DR-*compact-hub*.md 2>/dev/null | head -1)
echo "AFTER COMPACTION ($I): re-read the skills this session was using - compaction drops their"
echo "bodies. Then summarise where things stand in one message and confirm before continuing."
[ -n "$HUB" ] && echo "   read first, handoff record: ${HUB#$VAULT/}"
[ -f "$SNAP" ] && echo "   raw snapshot (if the summary lost something): ${SNAP#$VAULT/}"
exit 0
