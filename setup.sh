#!/usr/bin/env bash
# brain-kit installer - persistent memory + consolidation for Claude Code and other agent CLIs.
# Usage: ./setup.sh [--minimal] [--no-embed]
#   --minimal   recall + embed + compact hooks only (no postwrite check, no consolidation skill)
#   --no-embed  BM25 recall only: no torch, no model download, embedding hook stays idle
# Env: BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . CLAUDE_CONFIG_DIR (~/.claude) .
#      BRAIN_INSTANCE (main).  Idempotent: never overwrites notes, settings or existing skills.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=full; EMBED=1
for a in "$@"; do case "$a" in
  --minimal) PROFILE=minimal ;;
  --no-embed) EMBED=0 ;;
  -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 2 ;;
esac; done
say(){ printf '\n== %s\n' "$1"; }
ok(){ printf '   ok  %s\n' "$1"; }
die(){ printf '\nFAILED: %s\n' "$1" >&2; exit 1; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -t 0 ]; then
  read -r -p "brain root [$BRAIN_ROOT]: " _a || true; [ -n "${_a:-}" ] && BRAIN_ROOT="$_a"
  read -r -p "agent config dir [$CLAUDE_DIR]: " _b || true; [ -n "${_b:-}" ] && CLAUDE_DIR="$_b"
fi
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"; HOOKS="$BRAIN_ROOT/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"; INST="${BRAIN_INSTANCE:-main}"
say "brain-kit installer (profile=$PROFILE, embeddings=$EMBED)"
echo "   root=$BRAIN_ROOT   vault=$VAULT   config=$CLAUDE_DIR   instance=$INST"
PYBIN=""
for c in python3.13 python3.12 python3.11 python3.10 python3; do
  command -v "$c" >/dev/null 2>&1 || continue
  m=$("$c" -c 'import sys;print(sys.version_info[1] if sys.version_info[0]==3 else 0)' 2>/dev/null)
  if [ "${m:-0}" -ge 10 ] 2>/dev/null; then PYBIN="$c"; break; fi
done
[ -n "$PYBIN" ] || die "Python >= 3.10 not found (try: brew install python@3.12)"
command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq) - the write hooks need it"
[ -d "$KIT/scripts" ] && [ -d "$KIT/hooks" ] || die "incomplete checkout: scripts/ or hooks/ missing"
say "(1/6) directories"
mkdir -p "$VAULT"/{decision,knowledge,memory,moc,focus,_drafts,.index} \
         "$BRAIN_ROOT/scripts" "$HOOKS" "$CLAUDE_DIR/skills"
say "(2/6) python environment"
[ -x "$BRAIN_ROOT/.venv/bin/python" ] || "$PYBIN" -m venv "$BRAIN_ROOT/.venv" || die "venv failed"
if [ "$EMBED" = "1" ]; then
  echo "   installing embedding deps (first run downloads torch - minutes)..."
  "$BRAIN_ROOT/.venv/bin/pip" install --quiet -r "$KIT/requirements.txt" || die "pip install failed"
  ok "embedding deps installed"
else
  ok "skipped (--no-embed) - BM25 recall is stdlib-only and needs nothing"
fi
say "(3/6) scripts, hooks, environment file"
cp -f "$KIT"/scripts/*.py "$BRAIN_ROOT/scripts/"
cp -f "$KIT"/hooks/*.sh "$HOOKS/"; chmod +x "$HOOKS"/*.sh
cat > "$CLAUDE_DIR/brain-kit.env" <<EOF
# written by brain-kit setup.sh - every hook sources this. An exported variable still wins.
BRAIN_ROOT="\${BRAIN_ROOT:-$BRAIN_ROOT}"
BRAIN_DIR="\${BRAIN_DIR:-$VAULT}"
BRAIN_EMBED="\${BRAIN_EMBED:-$EMBED}"
EOF
ok "$BRAIN_ROOT/scripts, $HOOKS, $CLAUDE_DIR/brain-kit.env"
say "(4/6) hook wiring in $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp -f "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
W=("UserPromptSubmit::::_focus_inject.sh" "UserPromptSubmit::::_auto_retrieve.sh"
   "UserPromptSubmit::::time-inject.sh" "UserPromptSubmit::::due-inject.sh"
   "PostToolUse::Write|Edit::brain-embed-after-write.sh" "PreCompact::::precompact-snapshot.sh"
   "SessionStart::compact::sessionstart-compact-pointer.sh")
[ "$PROFILE" = "full" ] && W+=("PostToolUse::Write|Edit::postwrite-check.sh"
                               "PostToolUse::Bash|Write|Edit|MultiEdit::observe-mutations.sh")
"$PYBIN" - "$SETTINGS" "$HOOKS" "${W[@]}" <<'PY' || die "settings merge failed (restore the .bak)"
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); hd = sys.argv[2]
cfg = json.loads(p.read_text() or "{}"); hooks = cfg.setdefault("hooks", {})
for spec in sys.argv[3:]:
    ev, mt, sc = spec.split("::"); cmd = "bash '%s/%s'" % (hd, sc)
    arr = hooks.setdefault(ev, [])
    if any(h.get("command") == cmd for g in arr for h in g.get("hooks", [])):
        continue                                   # already wired - idempotent re-run
    grp = next((g for g in arr if g.get("matcher", "") == mt), None)
    if grp is None:
        grp = {"matcher": mt, "hooks": []} if mt else {"hooks": []}; arr.append(grp)
    grp["hooks"].append({"type": "command", "command": cmd})
p.write_text(json.dumps(cfg, indent=2))
print("   ok  %d hook entries total (yours were kept)" % sum(len(g.get("hooks", [])) for e in hooks.values() for g in e))
PY
say "(5/6) skills"
for sk in caveman five-gates brain-consolidate; do
  [ "$PROFILE" = "minimal" ] && [ "$sk" = "brain-consolidate" ] && continue
  if [ -e "$CLAUDE_DIR/skills/$sk" ]; then ok "$sk already installed - left alone"
  else cp -R "$KIT/skills/$sk" "$CLAUDE_DIR/skills/$sk"; ok "$sk installed"; fi
done
say "(6/6) vault seed and operating rules"
ID_FILE="$VAULT/.brain-instance"                   # instance name, read by focus + compact hooks
[ -f "$ID_FILE" ] || printf '%s\n' "$INST" > "$ID_FILE"
[ -f "$VAULT/focus/_FOCUS_$INST.txt" ] || cp "$KIT/vault-seed/focus/_FOCUS_main.txt" "$VAULT/focus/_FOCUS_$INST.txt"
cp -n "$KIT"/vault-seed/decision/*.md "$VAULT/decision/" 2>/dev/null || true
CM="$CLAUDE_DIR/CLAUDE.md"
if grep -q "brain-kit-operating-rules" "$CM" 2>/dev/null; then ok "CLAUDE.md block already there"
else sed "s|<vault>|$VAULT|g" "$KIT/docs/CLAUDE_BLOCK.md" >> "$CM"; ok "operating rules appended to $CM"; fi
say "done - restart your agent session so the hooks load, then read README.md"
echo "   smoke test: BRAIN_ROOT=\"$BRAIN_ROOT\" python3 \"$BRAIN_ROOT/scripts/brain_bm25.py\" \"example decision\" 3"
echo "   semantic index (needs embeddings): \"$BRAIN_ROOT/.venv/bin/python\" \"$BRAIN_ROOT/scripts/brain_embed.py\""
