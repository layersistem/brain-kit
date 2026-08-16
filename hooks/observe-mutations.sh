#!/bin/bash
# PostToolUse (Bash|Write|Edit|MultiEdit) - continuous observation stream.
# Appends one line per mutation (file path, or the head of a state-changing shell command) to
#   <vault>/_drafts/observations_<instance>_<YYYY-MM-DD>.md
# Excluded from retrieval. Read by brain_consolidate.py: anything here that no decision record
# explains is flagged "[NO-DR]" in the proposal - work that happened but was never written down.
# Zero model calls, append-only, secrets masked, <=160 chars per line.
INPUT=$(cat)
ENVF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"; [ -f "$ENVF" ] && . "$ENVF"
VAULT="${BRAIN_DIR:-${BRAIN_ROOT:-$HOME/brain}/vault}"
I="${BRAIN_INSTANCE:-}"
if [ -z "$I" ]; then                       # walk up from cwd for a .brain-instance marker
  _d="$PWD"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -f "$_d/.brain-instance" ]; then I=$(head -1 "$_d/.brain-instance" | tr -cd 'a-zA-Z0-9_-'); break; fi
    _d=$(dirname "$_d")
  done
fi
[ -z "$I" ] && I="default"
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
LINE=""
case "$TOOL" in
  Write|Edit|MultiEdit)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
    case "$FP" in ""|*/_drafts/*|*/.index/*) exit 0 ;; esac
    LINE="$TOOL . ${FP/#$HOME/~}" ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    HEAD="${CMD%%<<*}"
    printf '%s' "$HEAD" | grep -qE 'git[[:space:]]+(commit|push|checkout|reset)|docker[[:space:]]+(compose|exec|cp|restart|rm)|rsync|scp[[:space:]]|ssh[[:space:]].*(git|docker|python3|sed -i|>)|rm[[:space:]]+-rf?|mv[[:space:]]|gh[[:space:]]+(issue|pr)[[:space:]]+(create|edit|comment|close)' || exit 0
    # mask anything that looks like a token or password
    HEAD=$(printf '%s' "$HEAD" | tr '\n' ' ' | sed -E 's/(TOKEN|SECRET|PASSWORD|PASS|KEY|Authorization)[=: ]+[^ ]+/\1=***/Ig; s/(sk-|ghp_|hvs\.|xox[bp]-)[A-Za-z0-9_-]+/\1***/g')
    LINE="Bash . ${HEAD:0:150}" ;;
  *) exit 0 ;;
esac
[ -z "$LINE" ] && exit 0
mkdir -p "$VAULT/_drafts"
OUT="$VAULT/_drafts/observations_${I}_$(date +%F).md"
[ -f "$OUT" ] || printf '# Observation stream %s - %s (automatic, excluded from retrieval; consolidation input)\n' "$I" "$(date +%F)" > "$OUT"
printf -- '- %s . %s\n' "$(date +%H:%M)" "$LINE" >> "$OUT"
exit 0
