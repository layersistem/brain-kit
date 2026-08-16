#!/bin/bash
# UserPromptSubmit - a clock for the model. The harness only stamps the DATE at session start
# (no time of day, no session age); this prints, on every prompt: now (local, with weekday),
# how long this session has been open, and how long since the previous prompt.
# Source of session start: ~/.claude/sessions/<pid>.json (sessionId -> startedAt, epoch ms).
# Why: without it a long session cannot resolve "yesterday" or "an hour ago", and after a
# compaction it does not know how much wall-clock time passed. Injecting beats instructing:
# the model has no clock inside; a "figure out the time" instruction produces a guess.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null)
NOW=$(date +%s)
LINE="⏱ NOW $(date '+%F %a %H:%M %Z')"
if [ -n "$SID" ]; then
  START=$(grep -l "\"sessionId\":\"$SID\"" "$CFG"/sessions/*.json 2>/dev/null | head -1 \
    | xargs -I{} python3 -c 'import sys,json;print(int(json.load(open("{}")).get("startedAt",0)//1000))' 2>/dev/null)
  if [ -n "$START" ] && [ "$START" -gt 0 ] 2>/dev/null; then
    E=$((NOW-START)); LINE="$LINE · session +$((E/3600))h $(( (E%3600)/60 ))m (started $(date -r "$START" '+%H:%M'))"
  fi
  ST="$CFG/brain-kit-state"; mkdir -p "$ST"; LAST_F="$ST/last_prompt_$SID"
  if [ -f "$LAST_F" ]; then
    L=$(cat "$LAST_F"); G=$((NOW-L))
    if [ "$G" -ge 3600 ]; then LINE="$LINE · since last prompt +$((G/3600))h $(( (G%3600)/60 ))m"
    elif [ "$G" -ge 120 ]; then LINE="$LINE · since last prompt +$((G/60))m"; fi
  fi
  echo "$NOW" > "$LAST_F"
fi
echo "$LINE  (resolve relative dates against this line, write them absolute)"
exit 0
