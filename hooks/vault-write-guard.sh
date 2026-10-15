#!/bin/sh
# PreToolUse (Write|Edit) - PRIVATE MODE, write side (issue #14). With a brain-write.off file in <project>/.claude/ or
# in the agent config dir, a Write or Edit whose target lies inside the vault (BRAIN_DIR, symlinks resolved) is denied,
# with the flag's path in the reason so the model can tell the user how to lift it. The flag takes effect on the next
# tool call, no restart. Its read-side twin, brain-recall.off, lives in _auto_retrieve.sh.
# Without the flag file this hook reads nothing and prints nothing: two file tests, then exit 0.
# Scope: Write and Edit only. A shell command that writes into the vault is not seen here.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
OFF=""
for f in "$SESSION_ROOT/.claude/brain-write.off" "$CFG/brain-write.off"; do
  [ -f "$f" ] && { OFF="$f"; break; }
done
[ -n "$OFF" ] || exit 0
ENV_FILE="$CFG/brain-kit.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"
python3 -c 'import json, os, sys
try:
    p = (json.load(sys.stdin).get("tool_input") or {}).get("file_path") or ""
    v = os.path.realpath(sys.argv[1])
    t = os.path.realpath(p) if p else ""
    if t and (t == v or t.startswith(v + os.sep)):
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
              "permissionDecisionReason": "Vault writes are off in private mode: %s exists. Delete that file to write to %s again." % (sys.argv[2], v)}}))
except Exception:
    pass' "$VAULT" "$OFF" 2>/dev/null
exit 0
