#!/bin/bash
# UserPromptSubmit - interoception: how full is my context, how fast is it filling, is compaction near.
# The model has no sense of its own body; compaction always arrives as a surprise. This prints, on every
# prompt: current context tokens (%, window), the delta since the previous prompt, and a warning once a
# threshold is crossed - "write the handoff note now, before the blackout".
# CLAUDE CODE ONLY: it reads the `transcript_path` the Claude Code hook passes on stdin and the per-message
# `usage` block in that JSONL (context = input + cache_read + cache_creation). Other agent CLIs do not expose
# this; there the hook exits silently. Measured 16 Aug 2026: pre-compaction peak 356k, post 103k; the number
# matches the app's own "Context window" panel to the token.
#
# Two tiers (23 Sep 2026): WARNING at 50% of the window ("prepare: compact at the next clean boundary") and
# HARD at 65% ("compact now"). The old single 80% line came too late once the window was narrowed: by the time
# it fired, auto-compaction was already one long tool result away. Both defaults are fractions of the window
# W, which is BRAIN_CTX_WINDOW (taken as given), else CLAUDE_CODE_AUTO_COMPACT_WINDOW (the agent's own compaction
# ceiling, set per project in .claude/settings.json `env`; read from the environment, else from that file) clipped
# to the model's window, else the model's window. BRAIN_CTX_WARN / BRAIN_CTX_HARD override the fractions with
# plain token counts.
#
# The model's window (1.2.0): 200k, unless the session shows it is a 1M-context one - a model id ending in "[1m]" in
# ANTHROPIC_MODEL or in the "model" key of the project's or the user's settings, or a context above 200k already
# seen in the transcript. Before 1.2.0 every model except Haiku counted as 1M, so on a 200k model the 50% and 65%
# lines could never fire (a 153k context printed as "15% of 1000k"). The transcript's own model field carries no
# "[1m]", so a 1M session started with `--model <id>[1m]` on the command line is not visible here until it passes
# 200k: set BRAIN_CTX_WINDOW=1000000 for it.
# Per project, <project>/.claude/ctx-thresholds overrides both - `WARN=120000` / `HARD=160k`, plain tokens or
# a k suffix. A five-file repo and a monorepo do not deserve the same threshold, and the file is re-read on
# every prompt, so changing it needs no restart. Exported variables win.
#
# Post-compact turn (23 Sep 2026): when the transcript's last event after the newest `usage` line is a compact
# boundary (`"subtype":"compact_boundary"` or `"isCompactSummary":true`), there is no measurement for the new
# context yet - the only number available is the pre-compaction one, which is exactly the number that crossed
# the hard threshold. Printing it would order a second compaction on the first turn after the first, and with
# self-compact installed that is a loop. The hook says so in one line, gives no threshold order, and forgets
# the previous-context file so the next delta starts clean.
#
# At the hard threshold the order depends on whether self-compact is installed (scripts/self-compact.sh
# present and executable, and BRAIN_SELF_COMPACT not 0): with it, the agent compacts itself - handover note,
# focus summary, then the script as the LAST command of the turn (docs/self-compact.md); without it, the
# older "write the handoff note and let it compact" line.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ENV_FILE="$CFG/brain-kit.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
INPUT=$(cat)
# One python call: session id, transcript path, cwd, the project's own compaction ceiling from
# <cwd>/.claude/settings.json (env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) in case it is not in the environment, and
# whether the configured model is a 1M-context one (settings.local.json, then settings.json, then the user's).
read -r SID TP SW M1 CWD < <(printf '%s' "$INPUT" | python3 -c 'import sys,json,os
try:
    o=json.load(sys.stdin); cwd=o.get("cwd","") or ""; sw="-"; m1="0"
    try:
        v=json.load(open(os.path.join(cwd,".claude","settings.json"))).get("env",{}).get("CLAUDE_CODE_AUTO_COMPACT_WINDOW","")
        if str(v).isdigit(): sw=str(v)
    except Exception: pass
    for f in (os.path.join(cwd,".claude","settings.local.json"), os.path.join(cwd,".claude","settings.json"), os.path.join(sys.argv[1],"settings.json")):
        try: m=json.load(open(f)).get("model")
        except Exception: continue
        if m:
            m1="1" if str(m).lower().endswith("[1m]") else "0"; break
    print(o.get("session_id",""), o.get("transcript_path",""), sw, m1, cwd)   # cwd last: read gives it the rest of the line, spaces and all
except Exception: print("", "", "-", "0", "")' "$CFG" 2>/dev/null)
[ -n "$TP" ] && [ -f "$TP" ] || exit 0
# ctx = the newest assistant usage line; post = 1 when a compact boundary comes AFTER it (no measurement yet);
# peak = the largest context in the tail (above 200k the model's window cannot be a 200k one).
read -r CTX MDL POST PEAK < <(tail -c 3000000 "$TP" | python3 -c 'import sys,json
ctx=0; mdl=""; post=0; peak=0
for line in sys.stdin:
    if "\"isCompactSummary\":true" in line or "\"subtype\":\"compact_boundary\"" in line:
        ctx=0; post=1; continue
    if "\"usage\"" not in line: continue
    try: o=json.loads(line)
    except Exception: continue
    if o.get("type")!="assistant": continue
    m=o.get("message",{}); u=m.get("usage") or {}
    c=u.get("input_tokens",0)+u.get("cache_read_input_tokens",0)+u.get("cache_creation_input_tokens",0)
    if c: ctx=c; mdl=m.get("model",""); post=0; peak=max(peak,c)
print(ctx, mdl or "-", post, peak)' 2>/dev/null)
ST="$CFG/brain-kit-state"; mkdir -p "$ST"; PREV_F="$ST/ctx_$SID"
if [ "${POST:-0}" = "1" ] && [ "${CTX:-0}" -eq 0 ] 2>/dev/null; then
  echo "CONTEXT: first turn after compact, no measurement yet (the number returns next turn; the stale pre-compact figure is not shown)"
  [ -n "$SID" ] && rm -f "$PREV_F"
  exit 0
fi
[ "${CTX:-0}" -gt 0 ] 2>/dev/null || exit 0
MW=200000
case "${ANTHROPIC_MODEL:-}" in *"[1m]"|*"[1M]") M1=1 ;; esac
[ "${M1:-0}" = "1" ] && MW=1000000
[ "${PEAK:-0}" -gt 200000 ] 2>/dev/null && MW=1000000
W="${BRAIN_CTX_WINDOW:-}"
case "$W" in ""|*[!0-9]*) W="";; esac
if [ -z "$W" ]; then
  W="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
  case "$W" in ""|*[!0-9]*) W="";; esac
  [ -n "$W" ] || { case "$SW" in ""|-|*[!0-9]*) ;; *) W="$SW";; esac; }
  [ -n "$W" ] && [ "$W" -gt "$MW" ] && W="$MW"
fi
[ "${W:-0}" -gt 0 ] 2>/dev/null || W="$MW"
CTXF="$CWD/.claude/ctx-thresholds"
thr(){ [ -f "$CTXF" ] || return 0; awk -F= -v k="$1" '
  $1 ~ "^[ \t]*"k"[ \t]*$" { v=$2; sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
    if (v ~ /^[0-9]+[kK]$/) { sub(/[kK]$/, "", v); v = v * 1000 }
    if (v ~ /^[0-9]+$/) out = v }
  END { if (out != "") print out }' "$CTXF"; }
WARN="${BRAIN_CTX_WARN:-}"; HARD="${BRAIN_CTX_HARD:-}"
[ -n "$WARN" ] || WARN=$(thr WARN)
[ -n "$HARD" ] || HARD=$(thr HARD)
[ -n "$WARN" ] || WARN=$((W*50/100))
[ -n "$HARD" ] || HARD=$((W*65/100))
PCT=$(( CTX*100 / W ))
D=""; if [ -n "$SID" ] && [ -f "$PREV_F" ]; then P=$(cat "$PREV_F"); D=$(( (CTX-P)/1000 )); fi
[ -n "$SID" ] && echo "$CTX" > "$PREV_F"
LINE="CONTEXT ~$((CTX/1000))k (${PCT}% of $((W/1000))k)"
[ -n "$D" ] && LINE="$LINE - since last prompt ${D:+$( [ "$D" -ge 0 ] && printf '+' )}${D}k"
SC="$BRAIN_ROOT/scripts/self-compact.sh"
if [ "$CTX" -ge "$HARD" ] 2>/dev/null; then
  if [ "${BRAIN_SELF_COMPACT:-1}" != "0" ] && [ -x "$SC" ]; then
    LINE="$LINE  HARD: past $((HARD/1000))k - hard threshold reached, self-compact now: write the handover note + focus summary, then launch self-compact as the LAST command of the turn ($BRAIN_ROOT/docs/self-compact.md), then call no other tool and end the turn"
  else
    LINE="$LINE  HARD: past $((HARD/1000))k - stop at the next clean boundary, write the handoff note, let it compact"
  fi
elif [ "$CTX" -ge "$WARN" ]; then
  LINE="$LINE  WARNING: past $((WARN/1000))k - compact at the next clean boundary; prepare the handoff note + focus summary now"
fi
echo "$LINE"
