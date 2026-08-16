#!/bin/bash
# PostToolUse (Write|Edit) - second half of salience-inject.sh: if a correction signal landed in this session (last 3 h)
# and a decision record is then written WITHOUT a `weight:` line, say so. The amygdala tagged the moment; the hippocampus
# should not file it as routine. Warning only; touches no file.
INPUT=$(cat)
read -r SID FP < <(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    o=json.load(sys.stdin); print(o.get("session_id",""), (o.get("tool_input") or {}).get("file_path",""))
except Exception: print("", "")' 2>/dev/null)
case "$FP" in */decision/*.md) ;; *) exit 0 ;; esac
[ -f "$FP" ] || exit 0
F="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit-state/salience_${SID:-x}"; [ -f "$F" ] || exit 0
NOW=$(date +%s); RECENT=$(awk -F'|' -v n="$NOW" '($1+0) > n-10800 {c++} END{print c+0}' "$F")
[ "$RECENT" -gt 0 ] || exit 0
head -12 "$FP" | grep -qE '^weight: *(lesson|canon|approval|ders|kanon|onay)' && exit 0
echo "SALIENCE: $RECENT correction signal(s) this session and $(basename "$FP") has no weight. If it records the correction, add \`weight: lesson\` + \"## Lesson\" (ranked above routine, never decays). If unrelated, ignore."
