#!/bin/bash
. "$(dirname "$0")/_dryrun.sh"   # dry-run layer: HOOK_DRY_RUN=1 -> report instead of block
# Stop hook - UNSEARCHED-ABSENCE GATE. Blocks a turn whose final answer claims that something named is
# missing, unknown or waited for ("no record of X", "I don't have X", "waiting for X") when nothing in
# the turn searched for that name.
#
# The failure it exists for (23 Sep 2026): an agent was asked about five rules by description, resolved
# their names from a config file, and answered "I would need the device" for all five. Its own closed
# issues, PRs and a measurement note for each of them sat in the vault and on GitHub, findable by name
# in one query - the names were never searched, only the words of the prompt were. Cost of a false
# positive here: two searches. Cost of a miss: re-proposing work you finished last month.
#
# RULE: if the last assistant text of the turn (a) contains an absence/waiting claim and (b) contains at
# least one kebab-case name (two or more hyphens, eight or more characters, at least two alphabetic parts),
# then every such name must appear in the input of a search-shaped tool call earlier in the same turn:
# brain-search / brain_recall / brain_bm25 / brain_search / grep / rg / a Grep or Glob tool / gh ... --search /
# gh issue|pr list / desk-ledger. Otherwise: block, with the name and the two commands to run.
#
# Brake: at most BRAIN_ABSENCE_MAX_BLOCKS (2) blocks per turn; after that the gate passes and writes a
# "brake" line to the log, so a claim the model keeps making after searching never locks the session.
# Every decision is logged (pass/block/brake) to <agent-config-dir>/brain-kit-state/absence-gate.log.
#
# Claim phrases: English built in (the same list as patterns/absence-claims.en.txt). Your own language or
# phrasing: <project>/.claude/absence-patterns, or BRAIN_ABSENCE_RX_FILE=<file> - one extended regex per
# line, joined with "|", replacing the built-in list. A Turkish set ships as patterns/absence-claims.tr.txt.
# BRAIN_ABSENCE_GATE=0 disables the hook.
#
# Speed: this runs on every Stop, so the expensive parts are lazy - one jq call reads both fields, only the
# last 4 MB of the transcript are read (a tool_result line can be megabytes; `tail -n` on a 60 MB file took
# 730 ms), the turn segment is kept in a temp file rather than a multi-MB shell variable, and the instance
# name is resolved only when a log line is written.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ "${BRAIN_ABSENCE_GATE:-1}" = "0" ] && exit 0
INPUT=$(cat)
read -r SID TP CWD <<EOF
$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.transcript_path // ""), (.cwd // "")] | @tsv' 2>/dev/null)
EOF
{ [ -z "$TP" ] || [ ! -f "$TP" ]; } && exit 0

# The turn segment: everything after the last REAL human message (not a tool result, not a meta line,
# not a slash-command expansion, not a system notification). First line of the tail may be cut; dropped.
TURN=$(mktemp -t absence.XXXXXX) || exit 0
trap 'rm -f "$TURN"' EXIT
tail -c 4000000 "$TP" | tail -n +2 | awk '
  /"type":"user"/ && $0 !~ /"tool_result"/ && $0 !~ /"isMeta":true/ \
    && $0 !~ /<command-name>|<local-command-stdout>|<local-command-caveat>|"content":"Tool loaded/ \
    && ($0 !~ /"origin":/ || $0 ~ /"origin":\{"kind":"human"/) { n = NR }
  { line[NR] = $0 }
  END { for (i = (n ? n : 1); i <= NR; i++) print line[i] }' > "$TURN"
LAST=$(jq -rc 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$TURN" 2>/dev/null | tail -c 6000)
[ -z "$LAST" ] && exit 0

# Claim phrases. Fenced code blocks are dropped first, so a hook or pattern file quoted in the answer
# does not trigger the gate on its own description.
TEXT=$(printf '%s' "$LAST" | sed 's/```[^`]*```//g')
RX_FILE="${BRAIN_ABSENCE_RX_FILE:-$CWD/.claude/absence-patterns}"
if [ -n "$RX_FILE" ] && [ -f "$RX_FILE" ]; then
  CLAIM=$(grep -v '^[[:space:]]*#' "$RX_FILE" | grep -v '^[[:space:]]*$' | paste -sd '|' -)
fi
[ -n "${CLAIM:-}" ] || CLAIM="(there is|there's|i have|i've got|we have|i see|i found|found) (no|nothing|not a single) (record|note|trace|entry|issue|pr|pull request|mention|match|result)|no (record|note|trace|entry|issue|pr|pull request|mention|match|result)s? (of|for|on|about)|(not|never) (found|recorded|documented|written down|mentioned|seen)|(doesn't|does not|don't|do not) (exist|appear|show up|seem to exist)|(is|are|was|were) (not|no longer|nowhere) (in|on) (the )?(vault|brain|notes|record|records|repo|tree|codebase|index)|i (don't|do not|can't|cannot) (have|find|see|locate|access) (it|that|this|the|a|any)|(no|without) (access|device|hardware|credentials|key|token) (to|for)|(i need|i would need|we need|need) (the|a|an) (device|hardware|box|credentials|address|access)|(waiting|i'll wait|i will wait|i am waiting|i'm waiting) (for|on|until)|(nothing|no) (came|comes|turned|turns) (back|up)|(unknown|not known|no idea|no information|no data) (to me|about|on)"
printf '%s' "$TEXT" | grep -qiE "$CLAIM" || exit 0

# Named things: kebab-case, two or more hyphens, eight or more characters, at least two alphabetic parts of
# three or more letters (so a date or a timestamp like build-20260917-142159 does not count). A file
# extension is stripped. At most six names are checked.
NAMES=$(printf '%s' "$TEXT" \
  | grep -oE '[a-z0-9]+(-[a-z0-9]+){2,}(\.[a-z]{2,4})?' \
  | sed -E 's/\.[a-z]{2,4}$//' \
  | awk 'length($0) >= 8 {
      n = split($0, p, "-"); c = 0
      for (i = 1; i <= n; i++) if (p[i] ~ /^[a-z]{3,}$/) c++
      if (c >= 2) print
    }' | sort -u | head -6)
[ -z "$NAMES" ] && exit 0

# Searches run in this turn: Bash / Grep / Glob tool_use inputs that look like a search.
SEARCHED=$(jq -rc 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")
  | select(.name=="Bash" or .name=="Grep" or .name=="Glob") | .input | tostring' "$TURN" 2>/dev/null \
  | grep -aiE 'brain-search|brain_bm25|brain_recall|brain_search|_auto_retrieve|\bgrep\b|\brg\b|ripgrep|--search|gh (issue|pr|search)|desk-ledger|"pattern"|"glob"')
MISSING=""
for name in $NAMES; do
  printf '%s' "$SEARCHED" | grep -qF "$name" || { MISSING="$name"; break; }
done

# Per-turn block counter: keyed by the session and the uuid of the turn's human message.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; ST="$CFG/brain-kit-state"; mkdir -p "$ST" 2>/dev/null
L="$ST/absence-gate.log"; TS=$(date '+%F %T')
# Instance name for the log line. _instance.sh's claude_pid walk forks `ps` at every step (about 300 ms on a
# turn that gets this far); on Linux the same walk reads /proc with shell builtins and forks nothing. Same
# source, same order (the identity bound to this session's process); elsewhere it falls back to the helper.
fast_instance() {
  local p=$$ n=0 c s f
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ $n -lt 14 ]; do
    [ -r "/proc/$p/comm" ] || return 1
    c=$(< "/proc/$p/comm")
    if [ "$c" = "claude" ]; then
      f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state/session-instance/pid-$p"
      [ -f "$f" ] && { tr -cd 'a-zA-Z0-9_-' < "$f"; return 0; }
      return 1
    fi
    s=$(< "/proc/$p/stat") || return 1
    s=${s#*") "}          # the comm field may hold spaces or parentheses: skip past ")"
    set -- $s             # $1 = state, $2 = ppid
    p=$2; n=$((n + 1))
  done
  return 1
}
INST="${BRAIN_INSTANCE:-}"
[ -n "$INST" ] || INST=$(fast_instance 2>/dev/null)
if [ -z "$INST" ]; then
  . "$(dirname "$0")/_instance.sh" 2>/dev/null
  INST=$(brain_instance 2>/dev/null || echo unknown)
fi
if [ -z "$MISSING" ]; then
  printf '%s|%s|%s|pass\n' "$TS" "$INST" "$(printf '%s' "$NAMES" | tr '\n' ',')" >> "$L" 2>/dev/null
  exit 0
fi
TURN_KEY=$(head -1 "$TURN" | grep -oE '"uuid":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$TURN_KEY" ] || TURN_KEY=$(head -1 "$TURN" | grep -oE '"timestamp":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$TURN_KEY" ] || TURN_KEY=$(head -c 2000 "$TURN" | cksum | cut -d' ' -f1)   # no uuid on the line: the line itself is the key
CF="$ST/absence_$(printf '%s' "${SID:-nosid}" | tr -cd 'A-Za-z0-9_-')"
COUNT=0
if [ -f "$CF" ]; then
  read -r K C < "$CF"
  [ "$K" = "$TURN_KEY" ] && COUNT="${C:-0}"
fi
MAX="${BRAIN_ABSENCE_MAX_BLOCKS:-2}"
if [ "$COUNT" -ge "$MAX" ] 2>/dev/null; then
  printf '%s|%s|%s|brake (%s blocks this turn, passing)\n' "$TS" "$INST" "$MISSING" "$COUNT" >> "$L" 2>/dev/null
  exit 0
fi
printf '%s %s\n' "$TURN_KEY" "$((COUNT+1))" > "$CF"
printf '%s|%s|%s|block\n' "$TS" "$INST" "$MISSING" >> "$L" 2>/dev/null
R="UNSEARCHED ABSENCE: this answer says '$MISSING' is missing, unknown or waited for, but nothing in this turn searched for that name. Run \`brain-search \"$MISSING\"\` (the vault, your memory, the shared docs) and \`gh issue list --search \"$MISSING\"\` / \`gh pr list --search \"$MISSING\"\` where a repo is involved, then answer with the delta only."
R="$R Why: a name resolved during the work (a rule, a plugin, a branch, a file) is searched AGAIN by that name - searching with the prompt's words is not enough. Work you closed yourself lives in the vault as knowledge/desk-ledger-*.md when the ledger is installed."
dry_guard "unsearched-absence-stop" "absence claim about an unsearched name"
jq -n --arg r "$R" '{decision:"block",reason:$r}'
exit 0
