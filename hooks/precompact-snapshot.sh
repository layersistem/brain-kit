#!/bin/bash
# PreCompact - deterministic hand-brake before context compaction.
# A compact summary is model-written and lossy. This hook writes a zero-model snapshot instead:
# the last 15 user messages, the last assistant message and the current focus summary, into
# <vault>/_drafts/compact_snapshot_<instance>.md
# _drafts is excluded from both BM25 and the embedding index, so raw chat never pollutes recall.
# The file is not auto-injected either; the post-compact hook only points at it.
# Privacy: message text is truncated to 300 chars and stays on this machine.
ENV_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"
# Identity and scope derive from the SESSION project dir (CLAUDE_PROJECT_DIR), never from the shell cwd:
# a `cd` into another project inside a session must not change who you are or whose memory you read.
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
INPUT=$(cat)
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
mkdir -p "$VAULT/_drafts"
HOOK_INPUT="$INPUT" python3 - "$VAULT/_drafts/compact_snapshot_$I.md" "$VAULT/focus/_FOCUS_$I.txt" "$I" <<'PY'
import sys, json, datetime, os
try: inp = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception: inp = {}
out, focus, inst = sys.argv[1], sys.argv[2], sys.argv[3]
tp = inp.get("transcript_path", ""); trig = inp.get("trigger", "?")
users, last_asst = [], ""
def texts(content):
    if isinstance(content, str): return [content]
    return [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
try:
    with open(tp, encoding="utf-8", errors="ignore") as f:
        for line in f:
            try: d = json.loads(line)
            except Exception: continue
            m = d.get("message") or {}
            if d.get("type") == "user":
                t = " ".join(x for x in texts(m.get("content", "")) if x).strip()
                if t and not t.startswith("<") and "local-command-caveat" not in t: users.append(t)
            elif d.get("type") == "assistant":
                t = " ".join(x for x in texts(m.get("content", "")) if x).strip()
                if t: last_asst = t
except Exception as e:
    users.append(f"(transcript unreadable: {e})")
users = users[-15:]
summary = ""
try: summary = open(focus, encoding="utf-8").readline().strip()
except Exception: pass
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
L = [f"# Compact snapshot - {inst} - {now} (trigger={trig})", "",
     "> Written automatically by the PreCompact hook, no model involved. If the compact summary",
     "> lost something, the raw truth is here. A decision record plus the focus file remain the",
     "> real sources; this is only a backup.", "",
     "## Focus summary at compact time", summary or "(no focus file)", "",
     "## Last user messages (newest last, truncated to 300 chars)",
     *[f"{i+1}. {u[:300]}" for i, u in enumerate(users)], "",
     "## Last assistant message (600 chars)", last_asst[:600] or "(none)", ""]
open(out, "w", encoding="utf-8").write("\n".join(L))
print(f"compact snapshot written: {out} ({len(users)} messages)")
PY
exit 0
