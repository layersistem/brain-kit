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
# BRAIN_EXPECT (issue #18; on by default, `0` turns it off): `@expect YYYY-MM-DD[ HH:MM] text` lines - a prediction written before the
# outcome is known - come back on the same schedule, marked as an expectation whose outcome is to be written. Closed
# lines (`@expect✓ held:`, `@expect✗ missed:`, `@expect✓ void:`) are not seen, like `@due✓`, and neither is an
# expectation inside fenced code or inline backticks: that is a format example, and scripts/brain_expect.py skips the
# same lines by the same rule (backticks paired from the left). @due lines are read as before. Unset or any other
# value: the patterns are the 1.5.0 ones and the output is byte-identical, also on a vault that already holds @expect
# lines.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
. "$(dirname "$0")/_platform.sh" 2>/dev/null   # Windows: python3, jq, path forms; does nothing elsewhere
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
INPUT=$(cat)
. "$(dirname "$0")/_instance.sh" 2>/dev/null; I="$(pid_instance 2>/dev/null)"; [ -z "$I" ] && I="${BRAIN_INSTANCE:-}"   # session-bound identity first (see _instance.sh)
if [ -z "$I" ]; then
  _d="$SESSION_ROOT"
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    if [ -f "$_d/.brain-instance" ]; then I=$(head -1 "$_d/.brain-instance" | tr -d '[:space:]'); break; fi
    _up=$(dirname "$_d"); [ "$_up" = "$_d" ] && break; _d=$_up
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
EXP=0; [ "${BRAIN_EXPECT:-1}" = 1 ] && EXP=1
PATS=(-e '@due [0-9]'); PATLS=(-e '@due [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}')   # one -e per pattern: GNU and BSD grep agree
[ "$EXP" = 1 ] && { PATS+=(-e '@expect [0-9]'); PATLS+=(-e '@expect [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}'); }
FILES=("$VAULT/focus/_FOCUS_$I.txt")
while IFS= read -r f; do
  [ -n "$f" ] && head -8 "$f" | grep -q "^instance: *$I *$" && FILES+=("$f")
done < <(grep -l "${PATS[@]}" "$VAULT"/decision/*.md 2>/dev/null)
# @expect -> @due rewrite, only where the marker is not inside an inline code span. Spans pair the backticks from the
# left, the way scripts/brain_expect.py reads them: on a line split at backticks the even fields are code, except a
# last field after an unclosed backtick. The text itself is kept, code included.
EXPAWK='function conv(s,   o, p) {
  o = ""
  while ((p = match(s, /@expect [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))) {
    o = o substr(s, 1, p - 1) "@due " substr(s, p + 8, 10); s = substr(s, p + RLENGTH)
    if (match(s, /^ [0-9][0-9]:[0-9][0-9]/)) { o = o substr(s, 1, 6); s = substr(s, 7) }
    o = o " EXPECTATION - write the outcome:"
  }
  return o s
}
{ n = split($0, f, "`"); o = ""
  for (i = 1; i <= n; i++) o = o (i > 1 ? "`" : "") ((i % 2 || i == n) ? conv(f[i]) : f[i])
  print o }'
FENCED="|"   # file:line inside fenced code, only with expectation memory on
[ "$EXP" = 1 ] && for f in "${FILES[@]}"; do
  [ -f "$f" ] && FENCED="$FENCED$(awk '/^[[:space:]]*```/{f=!f;next} f{printf "%s:%d|", FILENAME, FNR}' "$f" 2>/dev/null)"
done

OUT=$(grep -Hn "${PATLS[@]}" "${FILES[@]}" 2>/dev/null | while IFS= read -r line; do
  loc=${line%%:*}; rest=${line#*:}; ln=${rest%%:*}; body=${rest#*:}; loc=${loc#$VAULT/}
  # an expectation is rewritten into the @due shape, so the parse below handles both; its text says what to do
  # ([[ ]] and not `case`: bash 3.2 cannot parse a case pattern's `)` inside this $( ... ))
  if [ "$EXP" = 1 ] && [[ "$FENCED" != *"|$VAULT/$loc:$ln|"* ]]; then
    body=$(printf '%s\n' "$body" | awk "$EXPAWK")
  fi
  # several @due on one line -> one entry each (a line-based parse only saw the last one)
  printf '%s\n' "$body" | awk '{gsub(/@due [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/,"\n&"); print}' | grep '^@due ' | while IFS= read -r item; do
  d=${item:5:10}; tail=${item:15}
  hm=$(printf '%s' "$tail" | sed -n 's/^ \([0-9][0-9]:[0-9][0-9]\).*/\1/p')
  txt=$(printf '%s' "$tail" | sed 's/^ \([0-9][0-9]:[0-9][0-9]\)\{0,1\} *//' | cut -c1-140)
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
  done
done)
[ "$FIRST" = 1 ] && echo "$TODAY" > "$DAYF"
[ -n "$OUT" ] || exit 0
HDR="DUE ($I; mark done by changing @due to @due✓; format: '@due YYYY-MM-DD[ HH:MM] text'; week horizon once a day):"
[ "$EXP" = 1 ] && case "$OUT" in *"EXPECTATION - write the outcome:"*) HDR="DUE ($I; mark done by changing @due to @due✓; format: '@due YYYY-MM-DD[ HH:MM] text'; week horizon once a day; close an expectation on its line as '@expect✓ held: <what happened>', '@expect✗ missed: <what happened>' or '@expect✓ void: <why it no longer applies>'):" ;; esac
echo "$HDR"
printf '%s\n' "$OUT"
