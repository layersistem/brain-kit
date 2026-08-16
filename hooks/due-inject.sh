#!/bin/bash
# UserPromptSubmit - prospective memory ("remember to do X on Monday at 11:30").
# The focus file says what you are in the middle of; nothing says what is DUE. This hook scans this
# instance's focus file and its own decision records for lines carrying
#     @due YYYY-MM-DD[ HH:MM] free text
# and prints, on every prompt: overdue items (with days late), today's (with a "NOW" tag once the
# hour has passed) and tomorrow's. Once per day - on the first prompt of the day - it also lists the
# coming week (2-7 days out), the way a person scans "what's on this week" over the first coffee and
# then stops thinking about it; the far horizon stays blurry on purpose. Done: change `@due` to `@due✓`
# on that line - the hook stops seeing it. Silent when nothing is due. Companion of time-inject.sh:
# the clock says what time it is, this says what that time means for you.
# Config: BRAIN_ROOT/BRAIN_DIR/BRAIN_INSTANCE as in _focus_inject.sh; day-state in <config>/brain-kit-state.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
INPUT=$(cat)
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

TODAY=$(date +%F); NOWM=$(date +%H:%M)
TOM=$(date -v+1d +%F 2>/dev/null || date -d tomorrow +%F)
WEEK=$(date -v+7d +%F 2>/dev/null || date -d '+7 days' +%F)
DAYS=(Sun Mon Tue Wed Thu Fri Sat)
epoch() { date -j -f %F "$1" +%s 2>/dev/null || date -d "$1" +%s; }
ST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state"; mkdir -p "$ST"; DAYF="$ST/due_day_$I"
FIRST=0; [ "$(cat "$DAYF" 2>/dev/null)" = "$TODAY" ] || FIRST=1
FILES=("$VAULT/focus/_FOCUS_$I.txt")
while IFS= read -r f; do
  [ -n "$f" ] && head -8 "$f" | grep -q "^instance: *$I *$" && FILES+=("$f")
done < <(grep -l '@due [0-9]' "$VAULT"/decision/*.md 2>/dev/null)

OUT=$(grep -Hn '@due [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "${FILES[@]}" 2>/dev/null | while IFS= read -r line; do
  loc=${line%%:*}; rest=${line#*:}; ln=${rest%%:*}; body=${rest#*:}
  d=$(printf '%s' "$body" | sed -n 's/.*@due \([0-9-]\{10\}\).*/\1/p')
  hm=$(printf '%s' "$body" | sed -n 's/.*@due [0-9-]\{10\} \([0-9][0-9]:[0-9][0-9]\).*/\1/p')
  txt=$(printf '%s' "$body" | sed 's/.*@due [0-9-]\{10\}\( [0-9][0-9]:[0-9][0-9]\)\{0,1\} *//' | cut -c1-140)
  loc=${loc#$VAULT/}
  if [[ "$d" < "$TODAY" ]]; then
    printf '  OVERDUE %sd (%s%s) %s  (%s:%s)\n' "$(( ( $(epoch "$TODAY") - $(epoch "$d") ) / 86400 ))" "$d" "${hm:+ $hm}" "$txt" "$loc" "$ln"
  elif [ "$d" = "$TODAY" ]; then
    if [ -n "$hm" ] && [[ "$hm" < "$NOWM" || "$hm" == "$NOWM" ]]; then tag="NOW ($hm)"; else tag="today${hm:+ $hm}"; fi
    printf '  %s - %s  (%s:%s)\n' "$tag" "$txt" "$loc" "$ln"
  elif [ "$d" = "$TOM" ]; then
    printf '  tomorrow%s - %s  (%s:%s)\n' "${hm:+ $hm}" "$txt" "$loc" "$ln"
  elif [ "$FIRST" = 1 ] && [[ "$d" < "$WEEK" || "$d" == "$WEEK" ]]; then
    dow=${DAYS[$(date -j -f %F "$d" +%w 2>/dev/null || date -d "$d" +%w)]}
    printf '  this week %s %s%s - %s  (%s:%s)\n' "$dow" "${d:5}" "${hm:+ $hm}" "$txt" "$loc" "$ln"
  fi
done)
[ "$FIRST" = 1 ] && echo "$TODAY" > "$DAYF"
[ -n "$OUT" ] || exit 0
echo "DUE ($I; mark done by changing @due to @due✓; format: '@due YYYY-MM-DD[ HH:MM] text'; week horizon once a day):"
printf '%s\n' "$OUT"
