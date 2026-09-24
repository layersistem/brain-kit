#!/bin/bash
# UserPromptSubmit - FOCUS FIRST: inject this instance's focus file verbatim, plus (optionally)
# open tasks and recent git state. The focus file is the one thing you must keep current; a stale
# focus misdirects every session.
#
# Config: BRAIN_ROOT, BRAIN_DIR (via <claude-dir>/brain-kit.env or the environment)
#         BRAIN_INSTANCE      - instance name (else .brain-instance, else "main")
#         BRAIN_FOCUS_DIRS    - only inject while cwd is under one of these globs (empty = always)
#         BRAIN_ISOLATE_DIRS  - dir globs where this hook stays quiet
#         BRAIN_TODO          - optional task file with a "## OPEN" section
#         BRAIN_PROJECT_GIT   - optional repo path; prints last commits + dirty files
#         BRAIN_FOCUS_MAX     - cap on the whole output in characters (default 8500)
#         BRAIN_FOCUS_LINE_MAX - longest SUMMARY / NOW line before a warning, and the clip for one line when the
#                               focus is truncated (default 1500 characters)
#
# 1.2.0 - the cap. Claude Code does not hand a hook's output to the model when it is longer than about 10,000
# characters: it saves it to a file and the model gets a 2 KB preview. The old cap was 12,000 bytes and its warning
# was the LAST line, so a long focus reached the model as a preview with the warning cut off (measured: a 12,432
# character output, warning at character 12,318). Now the whole output - focus, tasks, git - stays within
# BRAIN_FOCUS_MAX characters (8,500, under the 9,000 the other hooks keep to), and when the focus does not fit, the
# warning is the FIRST line: how long the file is,
# how much of it is shown, and the path to Read for the rest. Characters are counted, not bytes.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"

for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
if [ -n "${BRAIN_FOCUS_DIRS:-}" ]; then
  hit=0
  for d in $BRAIN_FOCUS_DIRS; do
    case "$SESSION_ROOT" in $d|$d/*) hit=1; break ;; esac
  done
  [ "$hit" = "0" ] && exit 0
fi

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

FOCUS="$VAULT/focus/_FOCUS_$I.txt"
if [ ! -f "$FOCUS" ]; then
  echo "FOCUS: instance '$I' has no focus file yet - create $FOCUS (first line: SUMMARY: ...)."
  exit 0
fi
# The focus file is the CURRENT state plus pointers; history belongs in decision records. A focus that grows into a
# diary is re-sent on every prompt (measured: a 59 KB summary line cost 96 KB per prompt across every instance).
# Tasks and git come first in the budget (their own cap: 1,500 characters), the focus gets the rest.
FOCUS_TAIL=$(
  if [ -n "${BRAIN_TODO:-}" ] && [ -f "$BRAIN_TODO" ]; then
    echo ""
    echo "-- OPEN TASKS --"
    awk '/^## OPEN/{f=1;next} /^## (DONE|CLOSED|CANCELLED)/{f=0} f&&/^### /{print "  - " substr($0,5)}' \
      "$BRAIN_TODO" 2>/dev/null | head -6
  fi
  if [ -n "${BRAIN_PROJECT_GIT:-}" ] && [ -d "$BRAIN_PROJECT_GIT/.git" ]; then
    echo ""
    echo "-- RECENT GIT (mutation evidence; compare it against the open tasks) --"
    git -C "$BRAIN_PROJECT_GIT" log --oneline -4 2>/dev/null | sed 's/^/  /'
    git -C "$BRAIN_PROJECT_GIT" status --porcelain 2>/dev/null | head -6 | sed 's/^/  dirty: /'
  fi
)
export FOCUS_TAIL
# The renderer prints everything in one write at its very end, so a failure prints nothing and the fallback below
# takes over. The here-document is not inside $( ): bash 3.2 (macOS /bin/bash) scans a command substitution's text
# for quotes and parentheses, here-document or not.
if ! python3 - "$FOCUS" "$I" "${FOCUS#$VAULT/}" <<'PY' 2>/dev/null
import os, sys
path, inst, rel = sys.argv[1], sys.argv[2], sys.argv[3]
def num(name, d):
    v = os.environ.get(name, "").strip()
    return int(v) if v.isdigit() and int(v) > 0 else d
lim, lmax = num("BRAIN_FOCUS_MAX", 8500), num("BRAIN_FOCUS_LINE_MAX", 1500)
with open(path, encoding="utf-8", errors="replace") as fh:
    text = fh.read()
lines = text.splitlines()
tail = os.environ.get("FOCUS_TAIL", "")
if len(tail) > 1500:
    tail = tail[:1500] + "\n  ... [tasks/git trimmed]"
head = "CURRENT FOCUS (%s) - from %s; update it whenever the focus changes:" % (inst, rel)
rule = []
first = lines[0] if lines else ""
now = next((l for l in lines if l.startswith("NOW")), "")
long_ = [n for n, l in (("SUMMARY", first), ("NOW", now)) if len(l) > lmax]
if long_:
    rule.append("WARNING: focus rule - the %s line%s longer than %d characters (%s). Shorten it; history belongs in "
                "a decision record: %s" % (" and ".join(long_), "s are" if len(long_) > 1 else " is", lmax,
                ", ".join("%s %d" % (n, len(first if n == "SUMMARY" else now)) for n in long_), path))
def assemble(warns, shown, end):
    return "\n".join(warns + [head] + shown + ([end] if end else []) + ([tail] if tail else [])) + "\n"
out = assemble(rule, ["  " + l for l in lines], "")
if len(out) > lim:
    clipped = ["  " + (l if len(l) <= lmax else l[:lmax] + "... [line clipped]") for l in lines]
    end = "  ... TRUNCATED: the whole focus (%d characters) is not in this context - Read %s" % (len(text), path)
    def build(n):
        shown = clipped[:n]
        warn = ("WARNING: focus truncated - %s has %d characters and %d of them fit in this output (hook output cap %d). "
                "The rest is NOT in this context: Read %s. Move history into a decision record." %
                (rel, len(text), sum(len(x) + 1 for x in shown), lim, path))
        return assemble([warn] + rule, shown, end)
    lo, hi = 0, len(clipped)          # largest n whose output fits
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(build(mid)) <= lim:
            lo = mid
        else:
            hi = mid - 1
    out = build(lo)[:lim]
sys.stdout.buffer.write(out.encode("utf-8"))
PY
then   # no python3: a byte cap on the whole output (a byte count is never below the character count), warning first
  OUT=$(echo "CURRENT FOCUS ($I) - from ${FOCUS#$VAULT/}; update it whenever the focus changes:"
        sed 's/^/  /' "$FOCUS" 2>/dev/null
        [ -n "$FOCUS_TAIL" ] && printf '%s\n' "$FOCUS_TAIL")
  if [ "$(printf '%s\n' "$OUT" | wc -c)" -gt 8000 ]; then
    echo "WARNING: focus truncated to 8000 bytes of output - Read $FOCUS for the rest."
    printf '%s\n' "$OUT" | head -c 8000; echo
  else
    printf '%s\n' "$OUT"
  fi
fi
exit 0
