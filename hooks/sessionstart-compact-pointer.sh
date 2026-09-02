#!/bin/bash
# SessionStart (matcher: compact) - first context after a compaction.
# Prints ADDRESSES, not content: the newest handoff decision record and the raw snapshot the
# PreCompact hook left behind, plus a reminder to re-read the skills that compaction dropped.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
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
  _d="$SESSION_ROOT"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -f "$_d/.brain-instance" ]; then I=$(head -1 "$_d/.brain-instance" | tr -d '[:space:]'); break; fi
    _d=$(dirname "$_d")
  done
fi
[ -z "$I" ] && [ -f "$VAULT/.brain-instance" ] && I=$(head -1 "$VAULT/.brain-instance" | tr -d '[:space:]')
[ -z "$I" ] && I="main"
SNAP="$VAULT/_drafts/compact_snapshot_$I.md"
# A per-instance hub file (an installer's own convention, e.g. one long-lived handoff record per
# instance instead of the newest dated one) wins if the install provides a lookup for it; that
# dependency is entirely optional here - a missing script just falls through to the plain glob.
HUB=""
INSTANCE_SH="$BRAIN_ROOT/hooks/_instance.sh"
if [ -f "$INSTANCE_SH" ]; then
  . "$INSTANCE_SH" 2>/dev/null
  command -v instance_hub >/dev/null 2>&1 && HUB=$(instance_hub)
fi
[ -z "$HUB" ] && HUB=$(ls -t "$VAULT"/decision/DR-*handoff*.md "$VAULT"/decision/DR-*compact-hub*.md 2>/dev/null | head -1)
echo "AFTER COMPACTION ($I): re-read the skills this session was using - compaction drops their"
echo "bodies. Then summarise where things stand in one message and confirm before continuing."
[ -n "$HUB" ] && echo "   read first, handoff record: ${HUB#$VAULT/}"
[ -f "$SNAP" ] && echo "   raw snapshot (if the summary lost something): ${SNAP#$VAULT/} - $(sed -n 1p "$SNAP")"
exit 0
