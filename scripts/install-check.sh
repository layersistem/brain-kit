#!/usr/bin/env bash
# install-check.sh - is the kit installed, and do its hooks do their work on this machine?
#
# Usage: bash <brain-root>/scripts/install-check.sh        (Windows: in Git Bash)
#
# Five checks, one line each, PASS or FAIL with the reason; exit code 0 only when all five pass. It exists because
# a broken install can look healthy: on Windows the kit once wired 20 hooks that all exited 0 while a new note never
# reached the index (issue #27). So the checks do not ask whether files are in place, they hand the hooks a real
# payload and look at what comes back:
#   1. the hooks are wired into the agent's settings.json
#   2. the hooks' Python runs and is 3.10 or newer
#   3. the hygiene check speaks: a test note without links is reported as an orphan
#   4. the write hook puts that note into the index
#   5. recall finds the note by its words
# The payload spells the note's path the way the agent does on this system (C:\... on Windows). The test note is
# written to <vault>/decision/ and removed again at the end, pass or fail, and the index forgets it.
# Private mode (brain-write.off, brain-recall.off) and BRAIN_ISOLATE_DIRS silence hooks on purpose; with one of them
# in effect for your home folder, checks 3 to 5 report FAIL for that reason.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && { set -a; . "$CFG/brain-kit.env"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"; VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"; HOOKS="$BRAIN_ROOT/hooks"
[ -f "$HOOKS/_platform.sh" ] && . "$HOOKS/_platform.sh"   # Windows: python3, jq, path forms
export BRAIN_ROOT BRAIN_DIR
cd "$HOME" || exit 1
unset CLAUDE_PROJECT_DIR
fails=0
pass(){ printf 'PASS %s\n' "$1"; }
fail(){ printf 'FAIL %s\n' "$1"; fails=$((fails+1)); }
native(){ if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# 1. wiring
n=0
if [ -f "$CFG/settings.json" ]; then
  for h in "$HOOKS"/*.sh; do
    b=${h##*/}; c=$(grep -c "/$b'" "$CFG/settings.json" 2>/dev/null); n=$((n + ${c:-0}))
  done
fi
if [ "$n" -ge 16 ]; then pass "1 hooks wired: $n entries in $CFG/settings.json"
else fail "1 hooks wired: $n entries in $CFG/settings.json (a full install has 20, --minimal 16) - run setup.sh again"; fi

# 2. interpreter
v=$(python3 -c 'import sys;print("%d.%d" % sys.version_info[:2]); sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$v" ]; then pass "2 hooks' Python: $v ($(command -v python3))"
else fail "2 hooks' Python: python3 does not run or is older than 3.10 (found: ${v:-nothing}) - run setup.sh again"; fi

# 3-5. a real write
NOTE="$VAULT/decision/DR-brain-kit-install-check.md"
mkdir -p "$VAULT/decision"
printf -- '---\ninstance: main\n---\n# brain-kit install check\nThe harbour lantern protocol was verified during the install check.\n' > "$NOTE"
P=$(jq -cn --arg fp "$(native "$NOTE")" '{hook_event_name:"PostToolUse",tool_name:"Write",session_id:"install-check",tool_input:{file_path:$fp,content:"The harbour lantern protocol was verified."}}' 2>/dev/null)
if [ -z "$P" ]; then
  fail "3 hygiene check: jq did not build the payload - is jq installed?"; fail "4 index update: not run"; fail "5 recall: not run"
else
  o=$(printf '%s' "$P" | bash "$HOOKS/postwrite-check.sh" 2>/dev/null)
  if [ ! -f "$HOOKS/postwrite-check.sh" ] || ! grep -q "postwrite-check.sh" "$CFG/settings.json" 2>/dev/null; then
    pass "3 hygiene check: not part of this install (--minimal)"
  elif printf '%s' "$o" | grep -q "Orphan note"; then pass "3 hygiene check: the linkless test note was reported as an orphan"
  else fail "3 hygiene check: no report for a note without links (output: ${o:-none})"; fi

  o=$(printf '%s' "$P" | bash "$HOOKS/brain-embed-after-write.sh" 2>/dev/null)
  case "$o" in
    *"brain.db: "*" files ("*) pass "4 index update: $(printf '%s' "$o" | grep -oE 'brain\.db: [0-9]+ files \([0-9]+ changed, [0-9]+ removed\)')" ;;
    *) fail "4 index update: the write hook did not update the index (output: ${o:-none})" ;;
  esac

  o=$(BRAIN_RECALL_FORCE=1 sh "$BRAIN_ROOT/scripts/brain-search" "harbour lantern protocol install check" 2>/dev/null)
  if printf '%s' "$o" | grep -q "DR-brain-kit-install-check"; then pass "5 recall: the test note was found by its words"
  else fail "5 recall: the test note was not in the recall block ($(printf '%s' "$o" | head -1 | cut -c1-80))"; fi
fi

# clean up, pass or fail
rm -f "$NOTE"
PY="$BRAIN_ROOT/.venv/bin/python"; [ -x "$PY" ] || PY="$BRAIN_ROOT/.venv/Scripts/python.exe"
[ -x "$PY" ] && (cd "$BRAIN_ROOT" && "$PY" scripts/brain_index.py update >/dev/null 2>&1)
[ -x "$PY" ] && printf '     index: %s\n' "$(cd "$BRAIN_ROOT" && "$PY" scripts/brain_index.py stats 2>/dev/null | grep -oE 'files [0-9]+ - chunks [0-9]+ - embedded [0-9]+')"
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED - restart the agent session so the hooks load"; exit 0
else echo "$fails CHECK(S) FAILED - the install is not done"; exit 1; fi
