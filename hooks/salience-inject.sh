#!/bin/bash
# UserPromptSubmit - emotional salience, the amygdala reflex. A person encodes what hurt without deciding to; for an
# agent "what hurt" is a correction from its human. The kit already ranks `weight: lesson` above routine and never lets
# it decay - but somebody had to notice the correction and write the tag. This hook notices: when the incoming prompt
# carries a correction signal ("wrong", "you broke", "undo", "why did you", "I told you"), it prints one line
# telling the model to give this turn's record `weight: lesson` + a Lesson section, and stamps the session state so
# salience-postwrite.sh can warn if the next decision record is written without a weight. Reminder only; touches no file.
# The pattern list is English by default; set BRAIN_SALIENCE_RX to your own language's markers (extended regex, lower-case).
#
# Machine text is not a correction (1.2.0). The continuation line scripts/self-compact.sh types into the window after a
# compaction arrives here as a prompt, but it is the agent's own note to itself; "fix the failing test" in it is not the
# human correcting anyone. self-compact.sh records the line it sent (brain-kit-state/self-compact.<project>.last), and a
# prompt equal to that line is skipped.
INPUT=$(cat)
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"; _PROJ="${_PROJ%/}"
LASTF="$CFG/brain-kit-state/self-compact.$(printf '%s' "$_PROJ" | tr -c 'A-Za-z0-9' '-').last"
read -r SID PROMPT < <(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    o=json.load(sys.stdin); p=" ".join((o.get("prompt","") or "").split())
    try: last=" ".join(open(sys.argv[1],encoding="utf-8").read().split())
    except Exception: last=""
    if last and p==last: p=""
    print(o.get("session_id",""), p[:600])
except Exception: print("", "")' "$LASTF" 2>/dev/null)
[ -n "$PROMPT" ] || exit 0
P=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')
# Not a correction when the "prompt" is a harness notification (background task / monitor event): agent text
# saying "wrong" or "mistake" about its own work is not the human correcting us. Skip, or the day counter inflates.
NOTIF_RX="system notification - not user input|<task-notification>|monitor event:"
printf '%s' "$P" | grep -qE "$NOTIF_RX" && exit 0
# 1.2.0: " no ", "stop" and "i said" left the list. In a test, three ordinary prompts set it off three times out of three
# ("There is no config file yet, can you create one", "I said earlier that we use postgres; add the migration", "Please
# stop the dev server and start it on port 8080"), and the third came back as the hard pattern-analysis line.
RX="${BRAIN_SALIENCE_RX:-(wrong|incorrect|mistake|you broke|broken now|undo|revert|roll back|hallucinat|made up|why did you|why would you|i told you|didn.t i say|not what i asked|again the same|same mistake|you didn.t read)}"
# Negation veto (6 Sep 2026): "nothing wrong", "not a mistake", "you didn't break it" carry a marker word but
# are the opposite of a correction. They are blanked before matching. BRAIN_SALIENCE_NEG_RX overrides the list.
NEG="${BRAIN_SALIENCE_NEG_RX:-(nothing wrong|not wrong|isn.t wrong|wasn.t wrong|no mistake|not a mistake|didn.t break|not broken|no need to (undo|revert)|don.t (undo|revert))}"
HIT=$(printf '%s' "$P" | sed -E "s/$NEG/ /g" | grep -oE "$RX" | head -1)
[ -n "$HIT" ] || exit 0
ST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state"; mkdir -p "$ST"; F="$ST/salience_${SID:-x}"
echo "$(date +%s)|$HIT" >> "$F"
N=$(wc -l < "$F" | tr -d ' ')
# Day counter for the record, but the hard warning fires on a BURST, not on the day's total (6 Sep 2026):
# a cumulative daily threshold turned into a lock - once a day crossed it, every remaining turn came up red,
# 26 turns in a row on the day it was measured. A gate that is really being missed shows up as several
# corrections close together, so the hard line now needs BRAIN_SALIENCE_BURST signals (3) inside
# BRAIN_SALIENCE_WINDOW seconds (5400 = 90 min).
DG="$ST/salience_day_$(date +%Y%m%d)"; echo "$(date +%s)|$HIT" >> "$DG"; NG=$(wc -l < "$DG" | tr -d ' ')
BURST="${BRAIN_SALIENCE_BURST:-3}"; WINDOW="${BRAIN_SALIENCE_WINDOW:-5400}"
RECENT=$(awk -F'|' -v n="$(date +%s)" -v w="$WINDOW" '($1+0) > n-w {c++} END{print c+0}' "$DG")
if [ "$RECENT" -ge "$BURST" ]; then
  echo "SALIENCE-HARD (signal \"$HIT\" - $RECENT in the last $((WINDOW/60)) min, #$NG today): a single-case lesson is not enough - slow down, run a PATTERN ANALYSIS: what gate keeps failing across these signals (read $DG, group them), write a pattern section into the root-cause record, then fix."
else
  echo "SALIENCE: correction signal \"$HIT\" - #$N this session, #$NG today. Give this turn's record \`weight: lesson\` + a \"## Lesson\" (what was wrong, what is right, which gate failed). Understand the cause before fixing."
fi
