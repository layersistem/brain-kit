#!/bin/bash
# PostToolUse (Bash|Write|Edit|MultiEdit) - continuous observation stream.
# Appends one line per mutation (file path, or the head of a state-changing shell command) to
#   <vault>/_drafts/observations_<instance>_<YYYY-MM-DD>.md
# Excluded from retrieval. Read by brain_consolidate.py: anything here that no decision record
# explains is flagged "[NO-DR]" in the proposal - work that happened but was never written down.
# Zero model calls, append-only, secrets masked, <=160 chars per line.
INPUT=$(cat)
ENVF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"; [ -f "$ENVF" ] && { set -a; . "$ENVF"; set +a; }
# Identity derives from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
VAULT="${BRAIN_DIR:-${BRAIN_ROOT:-$HOME/brain}/vault}"
. "$(dirname "$0")/_instance.sh" 2>/dev/null; I="$(pid_instance 2>/dev/null)"; [ -z "$I" ] && I="${BRAIN_INSTANCE:-}"   # session-bound identity first (see _instance.sh)
if [ -z "$I" ]; then                       # walk up from cwd for a .brain-instance marker
  _d="$SESSION_ROOT"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -f "$_d/.brain-instance" ]; then I=$(head -1 "$_d/.brain-instance" | tr -cd 'a-zA-Z0-9_-'); break; fi
    _d=$(dirname "$_d")
  done
fi
[ -z "$I" ] && [ -f "$VAULT/.brain-instance" ] && I=$(head -1 "$VAULT/.brain-instance" | tr -cd 'a-zA-Z0-9_-')
[ -z "$I" ] && exit 0   # no identity resolved -> don't log under a shared "default" bucket, skip
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
    # mask anything that looks like a token or password. 1.2.0: "Authorization: Bearer <token>" kept the token (only the
    # word "Bearer" was masked), a password glued to -p (mysql -pS3cret, sshpass -p S3cret) was not masked at all, and
    # the case-insensitive `I` flag exists only in GNU sed - BSD sed rejects it and the log line came out empty on
    # macOS. Case is now spelled out in bracket classes, which every sed reads the same way.
    HEAD=$(printf '%s' "$HEAD" | tr '\n' ' ' | sed -E \
      -e 's/(sshpass +-p) +[^ ]+/\1 ***/g' \
      -e "s/(^|[ \"'])-p[^ \"']+/\\1-p***/g" \
      -e 's/([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd])?|[Kk][Ee][Yy]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn])[=: ]+([Bb][Ee][Aa][Rr][Ee][Rr] +)?[^ ]+/\1=***/g' \
      -e 's/[Bb][Ee][Aa][Rr][Ee][Rr] +[^ ]+/Bearer ***/g' \
      -e 's/(sk-|ghp_|hvs\.|xox[bp]-)[A-Za-z0-9_-]+/\1***/g')
    LINE="Bash . ${HEAD:0:150}" ;;
  *) exit 0 ;;
esac
[ -z "$LINE" ] && exit 0
mkdir -p "$VAULT/_drafts"
OUT="$VAULT/_drafts/observations_${I}_$(date +%F).md"
[ -f "$OUT" ] || printf '# Observation stream %s - %s (automatic, excluded from retrieval; consolidation input)\n' "$I" "$(date +%F)" > "$OUT"
printf -- '- %s . %s\n' "$(date +%H:%M)" "$LINE" >> "$OUT"
exit 0
