#!/bin/bash
# SessionStart (matcher: compact) - first context after a compaction.
# Prints ADDRESSES, not content: the newest handoff decision record and the raw snapshot the
# PreCompact hook left behind, plus a reminder to re-read the skills that compaction dropped.
#
# 1.2.0: (1) with self-compact installed the line no longer asks to "confirm before continuing": the agent compacted
# itself so that it could carry on, and the confirm line stopped that autonomous work after every compaction.
# (2) Memory files and CLAUDE.md files changed in the last 60 minutes are listed with a "Read them" line: after a
# compaction Claude Code can hand the session an older copy of CLAUDE.md and of the memory files (anthropics/claude-code
# issue #92949), so what was written just before the compaction would be missing from the new context.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
INPUT=$(cat)
{ read -r SRC; read -r TP; } < <(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    o=json.load(sys.stdin); print(o.get("source","")); print((o.get("transcript_path","") or "").replace("\n",""))
except Exception: print(""); print("")' 2>/dev/null)
[ "$SRC" != "compact" ] && exit 0
. "$(dirname "$0")/_instance.sh" 2>/dev/null; I="$(pid_instance 2>/dev/null)"; [ -z "$I" ] && I="${BRAIN_INSTANCE:-}"   # session-bound identity first (see _instance.sh)
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
if [ "${BRAIN_SELF_COMPACT:-1}" != "0" ] && [ -x "$BRAIN_ROOT/scripts/self-compact.sh" ]; then
  echo "bodies. Then carry on from the next step in the handoff record and the focus file."
else
  echo "bodies. Then summarise where things stand in one message and confirm before continuing."
fi
[ -n "$HUB" ] && echo "   read first, handoff record: ${HUB#$VAULT/}"
[ -f "$SNAP" ] && echo "   raw snapshot (if the summary lost something): ${SNAP#$VAULT/} - $(sed -n 1p "$SNAP")"
MD=""; [ -n "$TP" ] && MD="$(dirname "$TP")/memory"
CHG=$( { [ -d "$MD" ] && find "$MD" -maxdepth 1 -name '*.md' -mmin -60 2>/dev/null
         for c in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md" "$SESSION_ROOT/CLAUDE.md" "$SESSION_ROOT/.claude/CLAUDE.md" "$VAULT/CLAUDE.md"; do
           [ -f "$c" ] && find "$c" -maxdepth 0 -mmin -60 2>/dev/null; done; } | awk '!seen[$0]++' | head -12 )
if [ -n "$CHG" ]; then
  echo "   changed in the last 60 min - Read them, the context after a compaction can carry an older copy (claude-code #92949):"
  printf '%s\n' "$CHG" | sed 's/^/     /'
fi
exit 0
