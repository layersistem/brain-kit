#!/bin/bash
# Stop hook - PERSEVERATION GUARD: if this turn's final answer is byte-for-byte the same (after
# whitespace trimming) as the previous turn's final answer, block and force a re-read. Root case a
# kit like this exists to prevent: a model stuck in a templated response ("Waiting." x6) can keep
# producing that same template even under a one-character correction from its human, because the
# procedural reflex is stronger than the two-word signal buried in it. This hook makes that whole
# class of failure mechanically impossible rather than relying on the model noticing it. Set
# BRAIN_PERSEVERATION_GUARD=0 to disable.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
INPUT=$(cat)
[ "${BRAIN_PERSEVERATION_GUARD:-1}" = "0" ] && exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
{ [ -z "$TP" ] || [ ! -f "$TP" ]; } && exit 0
# All real user messages (not tool-result echoes) mark the start of a new turn; split on their line numbers.
LINES=$(awk '/"type": ?"user"/ && !/"tool_result"/ {print NR}' "$TP" | tail -2)
N=$(printf '%s\n' "$LINES" | wc -l | tr -d ' ')
[ "$N" -lt 2 ] && exit 0
U1=$(printf '%s\n' "$LINES" | head -1); U2=$(printf '%s\n' "$LINES" | tail -1)
last_text() { sed -n "$1,$2 p" "$TP" | jq -rc 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tail -1; }
PREV=$(last_text "$U1" "$U2")
NOW=$(last_text "$U2" '$')
A=$(printf '%s' "$PREV" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
B=$(printf '%s' "$NOW" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
[ -z "$B" ] && exit 0
[ ${#B} -lt 3 ] && exit 0
[ "$A" != "$B" ] && exit 0
jq -n '{decision:"block",reason:"PERSEVERATION GUARD: this answer is byte-for-byte identical to the previous turn'\''s. STOP - re-read the incoming message (it may be a hook callback, not your human - and a one-character reply can carry a real answer or approval), then write a different, situation-specific response. No templated repeats."}'
exit 0
