#!/bin/bash
# context_budget.sh - measure what this kit puts into the context window, and what it costs.
#
# Not a hook, not a skill: run it by hand after any change to skills, CLAUDE.md, hooks or the focus
# file. It reports four items. Three are paid once per session (skill descriptions, CLAUDE.md
# chain, plugin/MCP count); one is paid on EVERY prompt - the focus file - and that is the lever
# people miss. Measured 2026-09-09: cutting 150 skills to a 10-skill core dropped the per-session
# cost by 90%, and the next measurement showed the focus file alone cost ~1,200 tokens per prompt.
# Token estimate is words x 1.3 (order of magnitude, not a tokenizer).
#
#   bash scripts/context_budget.sh [instance]     # instance: $1, else BRAIN_INSTANCE, else .brain-instance, else main
ROOT="${BRAIN_ROOT:-$HOME/brain}"; VAULT="${BRAIN_DIR:-$ROOT/vault}"; CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && . "$CFG/brain-kit.env"
I="${1:-${BRAIN_INSTANCE:-}}"
[ -z "$I" ] && [ -f "$PWD/.brain-instance" ] && I=$(head -1 "$PWD/.brain-instance" | tr -d '[:space:]')
[ -z "$I" ] && I=main
tok() { awk '{n+=NF} END{print int(n*1.3)}' "$@" 2>/dev/null; }
desc_words() { awk '/^description:/{f=1} f&&!/^---/{print} /^---/&&f{exit}' "$1" 2>/dev/null | wc -w | tr -d ' '; }
W=(); warn() { W+=("$1"); }

# (1) skill descriptions - loaded every session: personal (~/.claude/skills) + project (.claude/skills)
S_N=0; S_DESC=0; S_BIG=0
for d in "$CFG"/skills/*/ "$PWD"/.claude/skills/*/; do
  f="$d/SKILL.md"; [ -f "$f" ] || continue
  S_N=$((S_N+1)); w=$(desc_words "$f"); S_DESC=$((S_DESC+w))
  [ "$w" -gt 60 ] && warn "skill description over 60 words: $(basename "$d") ($w) - it is loaded every session"
  [ "$(wc -l < "$f")" -gt 400 ] && S_BIG=$((S_BIG+1))
done
S_TOK=$((S_DESC*13/10))
[ "$S_BIG" -gt 0 ] && warn "$S_BIG skill(s) over 400 lines (loaded on demand, not a per-session cost)"

# (2) CLAUDE.md chain
C_TOK=0; C_N=0
for f in "$CFG/CLAUDE.md" "$PWD/CLAUDE.md"; do [ -f "$f" ] && { C_N=$((C_N+1)); C_TOK=$((C_TOK+$(tok "$f"))); }; done
[ "$C_TOK" -gt 3000 ] && warn "CLAUDE.md chain over 3000 tokens"

# (3) focus - injected verbatim on EVERY prompt
F="$VAULT/focus/_FOCUS_$I.txt"; F_TOK=0; F_LINES=""
if [ -f "$F" ]; then
  F_TOK=$(tok "$F")
  F_LINES=$(awk '{n=split($0,w," "); t=int(n*1.3); lbl=substr($0,1,10); printf "      %-2d %-12s %5d\n", NR, lbl, t}' "$F")
  sz=$(head -1 "$F" | wc -c | tr -d ' ')
  [ "$sz" -gt 700 ] && warn "SUMMARY line is $sz chars (>700: other instances see it truncated; keep it to 3-4 sentences)"
  [ "$F_TOK" -gt 500 ] && warn "focus is $F_TOK tokens PER PROMPT (>500): move history to a decision record; focus = current state + pointers"
fi

# (4) plugins / MCP servers (tool schemas are the largest lever when they are not deferred)
P_N=$(python3 -c "import json,io;d=json.load(io.open('$CFG/settings.json',encoding='utf-8'));print(len(d.get('enabledPlugins',{})))" 2>/dev/null || echo "?")
M_N=$(python3 -c "import json,io;d=json.load(io.open('$HOME/.claude.json',encoding='utf-8'));print(len(d.get('mcpServers',{})))" 2>/dev/null || echo "?")

TOT=$((S_TOK+C_TOK))
echo "Context budget - instance: $I - $(date '+%Y-%m-%d %H:%M')"
echo "======================================================="
printf "  %-34s %6s  %8s\n" "component" "count" "~tokens"
printf "  %-34s %6s  %8s   (per session, fixed)\n" "skill descriptions" "$S_N" "$S_TOK"
printf "  %-34s %6s  %8s   (per session, fixed)\n" "CLAUDE.md chain" "$C_N" "$C_TOK"
printf "  %-34s %6s  %8s   (EVERY PROMPT - the lever)\n" "focus/_FOCUS_$I.txt" "-" "$F_TOK"
printf "  %-34s %6s  %8s   (schemas cost only when not deferred)\n" "plugins / mcpServers" "$P_N / $M_N" "-"
echo "  ---------------------------------------------------"
printf "  %-34s        %8s   + focus %s x prompts\n" "fixed per-session total" "$TOT" "$F_TOK"
[ -n "$F_LINES" ] && { echo "  focus, line by line:"; echo "$F_LINES"; }
if [ ${#W[@]} -gt 0 ]; then echo "  WARNINGS (${#W[@]}):"; for w in "${W[@]}"; do echo "   ! $w"; done; else echo "  no warnings"; fi
