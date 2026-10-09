#!/bin/sh
# PreToolUse (Write|Edit) - DECISION-TIME RECALL. Prompt recall (_auto_retrieve.sh) runs on the user's words and only
# when the user types; a decision record is written in a tool turn, where nothing recalled anything until this hook.
# When a Write or Edit targets <vault>/decision/*.md, scripts/brain_decision_recall.py returns two views: A TOPIC (the
# closest notes) and B OBJECTION (the research notes among them, so a lesson that argues against the decision is not
# outranked by routine notes). Claude Code hands a PreToolUse hook's context to the model with the tool's result, so the
# model reads the list right after the record is written and corrects it with an Edit if a note argues against it. The logic lives in that script for the reason
# _auto_retrieve.sh gives: no Python inside a hook file.
# Off: touch <agent-config-dir>/brain-decision-recall.disabled, or BRAIN_DECISION_RECALL=0 in brain-kit.env.
# Never blocks: no permission decision, exit 0 on every path, silent on any error. Works without the dense daemon
# (plain BM25 then, like prompt recall).
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-decision-recall.disabled" ] && exit 0
ENV_FILE="$CFG/brain-kit.env"
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"          # scope from the session's project, never the shell cwd
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
[ "${BRAIN_DECISION_RECALL:-1}" = "0" ] && exit 0
IN=$(cat)
# Cheap filter first: this runs on every Write and Edit, and only a decision record is worth a Python start.
case "$IN" in *'/decision/'*) ;; *) exit 0 ;; esac
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
export BRAIN_ROOT BRAIN_DIR
for d in ${BRAIN_ISOLATE_DIRS:-}; do
  case "${SESSION_ROOT:-}" in $d|$d/*) exit 0 ;; esac
done
DR="$BRAIN_ROOT/scripts/brain_decision_recall.py"
[ -f "$DR" ] || exit 0
# Same memory root and docs roots as prompt recall (_auto_retrieve.sh), so both see the same notes.
export BRAIN_MEMORY2="${BRAIN_MEMORY2:-$HOME/.claude/projects/$(printf '%s' "${SESSION_ROOT:-}" | tr '/ _' '---')/memory}"
export BRAIN_WIKI_DIR BRAIN_WIKI_DIRS BRAIN_WIKI_SCOPE_RX BRAIN_WIKI_SCOPE_RXS
printf '%s' "$IN" | python3 "$DR" 2>/dev/null
exit 0
