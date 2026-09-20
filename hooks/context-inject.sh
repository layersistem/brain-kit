#!/bin/bash
# UserPromptSubmit - interoception: how full is my context, how fast is it filling, is compaction near.
# The model has no sense of its own body; compaction always arrives as a surprise. This prints, on every
# prompt: current context tokens (%, window), the delta since the previous prompt, and a warning once a
# threshold is crossed - "write the handoff note now, before the blackout".
# CLAUDE CODE ONLY: it reads the `transcript_path` the Claude Code hook passes on stdin and the per-message
# `usage` block in that JSONL (context = input + cache_read + cache_creation). Other agent CLIs do not expose
# this; there the hook exits silently. Measured 16 Aug 2026: pre-compaction peak 356k, post 103k; the number
# matches the app's own "Context window" panel to the token.
# Config: BRAIN_CTX_WINDOW (default from model name: haiku 200k, else 1M); BRAIN_CTX_WARN (default 80% of the
# window - early compaction buys nothing, the warning only exists so the handoff is written before auto-compaction);
# BRAIN_CTX_HARD (no default) adds a second, louder line. Per project, <project>/.claude/ctx-thresholds overrides
# both - `WARN=120000` / `HARD=160k`, plain tokens or a k suffix. A five-file repo and a monorepo do not deserve the
# same threshold, and the file is re-read on every prompt, so changing it needs no restart. Exported variables win.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INPUT=$(cat)
read -r SID TP CWD < <(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    o=json.load(sys.stdin); print(o.get("session_id",""), o.get("transcript_path",""), o.get("cwd",""))
except Exception: print("", "", "")' 2>/dev/null)
[ -n "$TP" ] && [ -f "$TP" ] || exit 0
read -r CTX MDL < <(tail -c 3000000 "$TP" | python3 -c 'import sys,json
ctx=0; mdl=""
for line in sys.stdin:
    if "\"usage\"" not in line: continue
    try: o=json.loads(line)
    except Exception: continue
    if o.get("type")!="assistant": continue
    m=o.get("message",{}); u=m.get("usage") or {}
    c=u.get("input_tokens",0)+u.get("cache_read_input_tokens",0)+u.get("cache_creation_input_tokens",0)
    if c: ctx=c; mdl=m.get("model","")
print(ctx, mdl or "-")' 2>/dev/null)
[ "${CTX:-0}" -gt 0 ] 2>/dev/null || exit 0
W="${BRAIN_CTX_WINDOW:-}"; [ -n "$W" ] || { case "$MDL" in *haiku*) W=200000;; *) W=1000000;; esac; }
CTXF="$CWD/.claude/ctx-thresholds"
thr(){ [ -f "$CTXF" ] || return 0; awk -F= -v k="$1" '
  $1 ~ "^[ \t]*"k"[ \t]*$" { v=$2; sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
    if (v ~ /^[0-9]+[kK]$/) { sub(/[kK]$/, "", v); v = v * 1000 }
    if (v ~ /^[0-9]+$/) out = v }
  END { if (out != "") print out }' "$CTXF"; }
WARN="${BRAIN_CTX_WARN:-}"; HARD="${BRAIN_CTX_HARD:-}"
[ -n "$WARN" ] || WARN=$(thr WARN)
[ -n "$HARD" ] || HARD=$(thr HARD)
[ -n "$WARN" ] || WARN=$((W*80/100))
PCT=$(( CTX*100 / W ))
ST="$CFG/brain-kit-state"; mkdir -p "$ST"; PREV_F="$ST/ctx_$SID"
D=""; if [ -n "$SID" ] && [ -f "$PREV_F" ]; then P=$(cat "$PREV_F"); D=$(( (CTX-P)/1000 )); fi
[ -n "$SID" ] && echo "$CTX" > "$PREV_F"
LINE="CONTEXT ~$((CTX/1000))k (${PCT}% of $((W/1000))k)"
[ -n "$D" ] && LINE="$LINE - since last prompt ${D:+$( [ "$D" -ge 0 ] && printf '+' )}${D}k"
if [ -n "$HARD" ] && [ "$CTX" -ge "$HARD" ] 2>/dev/null; then
  LINE="$LINE  HARD: past $((HARD/1000))k - stop at the next clean boundary, write the handoff note, let it compact"
elif [ "$CTX" -ge "$WARN" ]; then
  LINE="$LINE  WARNING: past $((WARN/1000))k - auto-compaction is near; write the handoff note + focus summary NOW"
fi
echo "$LINE"
