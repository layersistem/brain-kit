#!/bin/bash
# UserPromptSubmit - emotional salience, the amygdala reflex. A person encodes what hurt without deciding to; for an
# agent "what hurt" is a correction from its human. The kit already ranks `weight: lesson` above routine and never lets
# it decay - but somebody had to notice the correction and write the tag. This hook notices: when the incoming prompt
# carries a correction signal ("wrong", "no,", "you broke", "undo", "why did you", "I told you"), it prints one line
# telling the model to give this turn's record `weight: lesson` + a Lesson section, and stamps the session state so
# salience-postwrite.sh can warn if the next decision record is written without a weight. Reminder only; touches no file.
# The pattern list is English by default; set BRAIN_SALIENCE_RX to your own language's markers (extended regex, lower-case).
INPUT=$(cat)
read -r SID PROMPT < <(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    o=json.load(sys.stdin); print(o.get("session_id",""), " ".join(o.get("prompt","").split())[:600])
except Exception: print("", "")' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0
P=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')
RX="${BRAIN_SALIENCE_RX:-(wrong|incorrect|mistake|you broke|broken now|undo|revert|roll back|hallucinat|made up|why did you|why would you|i told you|i said|didn.t i say|stop[ ,.!]|stop$|^no[ ,.!]|[ ,.]no[ ,.!]|not what i asked|again the same|same mistake|you didn.t read)}"
HIT=$(printf '%s' "$P" | grep -oE "$RX" | head -1)
[ -n "$HIT" ] || exit 0
ST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state"; mkdir -p "$ST"; F="$ST/salience_${SID:-x}"
echo "$(date +%s)|$HIT" >> "$F"
N=$(wc -l < "$F" | tr -d ' ')
echo "SALIENCE: correction signal \"$HIT\" - #$N this session. Give this turn's record \`weight: lesson\` + a \"## Lesson\" (what was wrong, what is right, which gate failed). Understand the cause before fixing."
