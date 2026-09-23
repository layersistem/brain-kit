#!/usr/bin/env bash
# brain-kit installer - persistent memory + consolidation for Claude Code and other agent CLIs.
# Usage: ./setup.sh [--minimal] [--no-embed] [--project=DIR] [--context-window=<N|no>] [--self-compact=<session|no>]
#                   [--desk-repos="owner/a owner/b"] [--no-timers] [--yes-defaults]
#   --minimal          recall + embed + compact hooks only (no postwrite check, no Stop gates, no consolidation skill)
#   --no-embed         BM25 recall only: no torch, no model download, embedding hook and sweeper stay idle
#   --project=DIR      the project whose .claude/settings.json and CLAUDE.md the opt-ins touch (default:
#                      CLAUDE_PROJECT_DIR, else the current directory)
#   --context-window=  N writes CLAUDE_CODE_AUTO_COMPACT_WINDOW=N into <project>/.claude/settings.json (env);
#                      "no" leaves it alone. Asked interactively when the flag is absent; default: no.
#   --self-compact=    a tmux session name installs self-compact for that session; "no" leaves it off. Asked
#                      interactively when the flag is absent; default: no.
#   --desk-repos=      "owner/repo ..." installs the hourly desk ledger for those repos (needs gh); absent = skipped
#   --no-timers        do not install or enable systemd user timers (print the cron lines instead)
#   --yes-defaults     no prompts at all: every question takes its default (the two opt-ins default to no)
# Env: BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . CLAUDE_CONFIG_DIR (~/.claude) .
#      BRAIN_INSTANCE (main).  Idempotent: never overwrites notes, settings or existing skills.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=full; EMBED=1; PROJECT=""; CTXWIN=""; SELFC=""; DESK=""; TIMERS=1; YESDEF=0
for a in "$@"; do case "$a" in
  --minimal) PROFILE=minimal ;;
  --no-embed) EMBED=0 ;;
  --project=*) PROJECT="${a#*=}" ;;
  --context-window=*) CTXWIN="${a#*=}" ;;
  --self-compact=*) SELFC="${a#*=}" ;;
  --desk-repos=*) DESK="${a#*=}" ;;
  --no-timers) TIMERS=0 ;;
  --yes-defaults) YESDEF=1 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 2 ;;
esac; done
say(){ printf '\n== %s\n' "$1"; }
ok(){ printf '   ok  %s\n' "$1"; }
die(){ printf '\nFAILED: %s\n' "$1" >&2; exit 1; }
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECT="${PROJECT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ASK=0; [ -t 0 ] && [ "$YESDEF" = "0" ] && ASK=1
if [ "$ASK" = "1" ]; then
  read -r -p "brain root [$BRAIN_ROOT]: " _a || true; [ -n "${_a:-}" ] && BRAIN_ROOT="$_a"
  read -r -p "agent config dir [$CLAUDE_DIR]: " _b || true; [ -n "${_b:-}" ] && CLAUDE_DIR="$_b"
  read -r -p "project dir (its .claude/settings.json and CLAUDE.md take the opt-ins) [$PROJECT]: " _c || true; [ -n "${_c:-}" ] && PROJECT="$_c"
fi
PROJECT="${PROJECT%/}"
# The two opt-ins (23 Sep 2026). Both default to NO: an empty answer installs nothing, a missing flag on a
# non-terminal stdin installs nothing. The suggested window is the value most of the author's own
# projects run with; the hooks' warning (50%) and hard (65%) lines are fractions of it.
CTX_DEFAULT=500000
if [ -z "$CTXWIN" ]; then
  CTXWIN=no
  if [ "$ASK" = "1" ]; then
    read -r -p "Narrow the context window? This sets CLAUDE_CODE_AUTO_COMPACT_WINDOW in the project's .claude/settings.json so warnings and auto-compact trigger earlier (recommended value $CTX_DEFAULT). [y/N] " _d || true
    case "${_d:-}" in y|Y|yes|YES)
      read -r -p "window size in tokens [$CTX_DEFAULT]: " _e || true
      CTXWIN="${_e:-$CTX_DEFAULT}" ;;
    esac
  fi
fi
case "$CTXWIN" in no|NO|n|N|"") CTXWIN=no ;; *[!0-9]*) die "--context-window takes a number of tokens or 'no' (got '$CTXWIN')" ;; esac
if [ -z "$SELFC" ]; then
  SELFC=no
  if [ "$ASK" = "1" ]; then
    read -r -p "Install self-compact (requires tmux; the agent compacts itself at the hard threshold)? [y/N] " _f || true
    case "${_f:-}" in y|Y|yes|YES)
      command -v tmux >/dev/null 2>&1 || echo "   (tmux is not on PATH here; the script needs it at run time)"
      _cur=""; [ -n "${TMUX:-}" ] && _cur=$(tmux display-message -p '#S' 2>/dev/null || true)
      read -r -p "tmux session name${_cur:+ [$_cur]}: " _g || true
      SELFC="${_g:-$_cur}"; [ -n "$SELFC" ] || { echo "   no session name given - self-compact not installed"; SELFC=no; } ;;
    esac
  fi
fi
case "$SELFC" in no|NO|n|N|"") SELFC=no ;; *[!A-Za-z0-9_.:-]*) die "--self-compact takes a tmux session name or 'no' (got '$SELFC')" ;; esac
if [ -z "$DESK" ] && [ "$ASK" = "1" ] && command -v gh >/dev/null 2>&1; then
  read -r -p "Desk ledger: GitHub repos to export hourly into the vault (owner/repo, space separated; empty = skip): " _h || true
  DESK="${_h:-}"
fi
VAULT="${BRAIN_DIR:-$BRAIN_ROOT/vault}"; HOOKS="$BRAIN_ROOT/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"; INST="${BRAIN_INSTANCE:-main}"
say "brain-kit installer (profile=$PROFILE, embeddings=$EMBED)"
echo "   root=$BRAIN_ROOT   vault=$VAULT   config=$CLAUDE_DIR   instance=$INST"
echo "   project=$PROJECT   context-window=$CTXWIN   self-compact=$SELFC   desk-ledger=${DESK:-skipped}"
PYBIN=""
for c in python3.13 python3.12 python3.11 python3.10 python3; do
  command -v "$c" >/dev/null 2>&1 || continue
  m=$("$c" -c 'import sys;print(sys.version_info[1] if sys.version_info[0]==3 else 0)' 2>/dev/null)
  if [ "${m:-0}" -ge 10 ] 2>/dev/null; then PYBIN="$c"; break; fi
done
[ -n "$PYBIN" ] || die "Python >= 3.10 not found (try: brew install python@3.12)"
command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq) - the write hooks need it"
[ -d "$KIT/scripts" ] && [ -d "$KIT/hooks" ] || die "incomplete checkout: scripts/ or hooks/ missing"
say "(1/8) directories"
mkdir -p "$VAULT"/{decision,knowledge,memory,moc,focus,_drafts,.index} \
         "$BRAIN_ROOT/scripts" "$BRAIN_ROOT/patterns" "$HOOKS" "$CLAUDE_DIR/skills"
say "(2/8) python environment"
[ -x "$BRAIN_ROOT/.venv/bin/python" ] || "$PYBIN" -m venv "$BRAIN_ROOT/.venv" || die "venv failed"
if [ "$EMBED" = "1" ]; then
  echo "   installing embedding deps (first run downloads torch - minutes)..."
  "$BRAIN_ROOT/.venv/bin/pip" install --quiet -r "$KIT/requirements.txt" || die "pip install failed"
  ok "embedding deps installed"
else
  ok "skipped (--no-embed) - BM25 recall is stdlib-only and needs nothing"
fi
say "(3/8) scripts, hooks, environment file"
cp -f "$KIT"/scripts/*.py "$BRAIN_ROOT/scripts/"
cp -f "$KIT"/scripts/*.sh "$BRAIN_ROOT/scripts/" 2>/dev/null || true
cp -f "$KIT/scripts/brain-search" "$BRAIN_ROOT/scripts/brain-search"
chmod +x "$BRAIN_ROOT"/scripts/*.sh "$BRAIN_ROOT/scripts/brain-search" 2>/dev/null || true
cp -f "$KIT"/patterns/*.txt "$BRAIN_ROOT/patterns/" 2>/dev/null || true
[ -f "$KIT/VERSION" ] && cp -f "$KIT/VERSION" "$BRAIN_ROOT/VERSION"   # what the update check compares against
ORIGIN=$(git -C "$KIT" remote get-url origin 2>/dev/null || true)     # tags are read from where you cloned
# An ssh clone would make the daily check an authenticated call - the host learns which account asks.
# The https form of the same address reads a public repo's tags with no key and no identity.
ORIGIN=$(printf '%s' "$ORIGIN" | sed -E 's#^(ssh://)?git@([^:/]+)[:/](.+)$#https://\2/\3#; s#\.git$##')
# Every hook sources the file written below, so the address goes in only when it is plain address
# characters. Anything else is left out and the check falls back to the upstream repository. A shell
# pattern looks at the whole value; grep would pass a value of several lines if one line is clean.
case "$ORIGIN" in *[!A-Za-z0-9._:/@+~-]*) ORIGIN="" ;; esac
cp -f "$KIT"/hooks/*.sh "$HOOKS/"; chmod +x "$HOOKS"/*.sh
# self-compact: "no" now keeps an earlier opt-in (not installing is not uninstalling); a fresh install stays off.
PRIOR_SC=$(sed -n 's/^BRAIN_SELF_COMPACT="\${BRAIN_SELF_COMPACT:-\([01]\)}"$/\1/p' "$CLAUDE_DIR/brain-kit.env" 2>/dev/null || true)
SC_ON=0; [ "$SELFC" != "no" ] && SC_ON=1; [ "$SELFC" = "no" ] && [ "${PRIOR_SC:-0}" = "1" ] && SC_ON=1
cat > "$CLAUDE_DIR/brain-kit.env" <<EOF
# written by brain-kit setup.sh - every hook sources this. An exported variable still wins.
BRAIN_ROOT="\${BRAIN_ROOT:-$BRAIN_ROOT}"
BRAIN_DIR="\${BRAIN_DIR:-$VAULT}"
BRAIN_EMBED="\${BRAIN_EMBED:-$EMBED}"
BRAIN_INDEX="\${BRAIN_INDEX:-sqlite}"
BRAIN_UPDATE_CHECK="\${BRAIN_UPDATE_CHECK:-1}"
BRAIN_UPDATE_REMOTE="\${BRAIN_UPDATE_REMOTE:-$ORIGIN}"
BRAIN_SELF_COMPACT="\${BRAIN_SELF_COMPACT:-$SC_ON}"
EOF
ok "$BRAIN_ROOT/scripts, $HOOKS, $BRAIN_ROOT/patterns, $CLAUDE_DIR/brain-kit.env"
say "(4/8) hook wiring in $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp -f "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
W=("UserPromptSubmit::::session-instance-bind.sh"   # first: every later hook reads the identity it binds
   "UserPromptSubmit::::_focus_inject.sh" "UserPromptSubmit::::_auto_retrieve.sh"
   "UserPromptSubmit::::time-inject.sh" "UserPromptSubmit::::due-inject.sh"
   "UserPromptSubmit::::context-inject.sh" "UserPromptSubmit::::salience-inject.sh"
   "PostToolUse::Write|Edit::salience-postwrite.sh"
   "PostToolUse::Write|Edit::brain-embed-after-write.sh"
   "PostToolUse::Read::recall-usage-count.sh"       # ranking input: notes the model opened, not ones it was shown
   "PreCompact::::precompact-snapshot.sh"
   "SessionStart::startup|resume|compact|clear::session-instance-bind.sh"
   "SessionStart::compact::sessionstart-compact-pointer.sh"
   "SessionStart::startup|resume::update-notice.sh")
[ "$PROFILE" = "full" ] && W+=("PostToolUse::Write|Edit::postwrite-check.sh"
                               "PostToolUse::Bash|Write|Edit|MultiEdit::observe-mutations.sh"
                               "Stop::::identical-answer-stop.sh"
                               "Stop::::unsearched-absence-stop.sh")   # "no record of X" without a search for X
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
say "(5/8) skills"
for sk in caveman five-gates brain-consolidate; do
  [ "$PROFILE" = "minimal" ] && [ "$sk" = "brain-consolidate" ] && continue
  if [ -e "$CLAUDE_DIR/skills/$sk" ]; then ok "$sk already installed - left alone"
  else cp -R "$KIT/skills/$sk" "$CLAUDE_DIR/skills/$sk"; ok "$sk installed"; fi
done
say "(6/8) vault seed and operating rules"
ID_FILE="$VAULT/.brain-instance"                   # instance name, read by focus + compact hooks
[ -f "$ID_FILE" ] || printf '%s\n' "$INST" > "$ID_FILE"
[ -f "$VAULT/focus/_FOCUS_$INST.txt" ] || cp "$KIT/vault-seed/focus/_FOCUS_main.txt" "$VAULT/focus/_FOCUS_$INST.txt"
cp -n "$KIT"/vault-seed/decision/*.md "$VAULT/decision/" 2>/dev/null || true
cp -n "$KIT"/vault-seed/knowledge/beliefs.md "$VAULT/knowledge/" 2>/dev/null || true
CM="$CLAUDE_DIR/CLAUDE.md"
if grep -q "brain-kit-operating-rules" "$CM" 2>/dev/null; then ok "CLAUDE.md block already there"
else sed "s|<vault>|$VAULT|g" "$KIT/docs/CLAUDE_BLOCK.md" >> "$CM"; ok "operating rules appended to $CM"; fi
say "(7/8) background timers (index sweeper, desk ledger)"
# The write hook only chunks a note (about 1 s); the vectors come from scripts/brain_index_sweep.sh, run by the
# hook and by this 2-minute timer. Without systemd --user (macOS, a container) the cron line does the same.
SYSD=0
if [ "$TIMERS" = "1" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then SYSD=1; fi
UD="$HOME/.config/systemd/user"
install_unit(){ # $1 = unit base name
  mkdir -p "$UD"
  sed "s#%h/brain#$BRAIN_ROOT#g" "$KIT/scripts/systemd/$1.service" > "$UD/$1.service"
  cp -f "$KIT/scripts/systemd/$1.timer" "$UD/$1.timer"
  systemctl --user daemon-reload && systemctl --user enable --now "$1.timer" >/dev/null 2>&1 && ok "$1.timer enabled" || echo "   could not enable $1.timer - see: systemctl --user status $1.timer"
}
if [ "$EMBED" = "1" ]; then
  if [ "$SYSD" = "1" ]; then install_unit brain-index-sweep
  else echo "   no systemd --user here: add this cron line for the vector sweeper (or run it from launchd):"
       echo "     */2 * * * * bash \"$BRAIN_ROOT/scripts/brain_index_sweep.sh\""; fi
else ok "sweeper skipped (--no-embed: nothing to embed)"; fi
if [ -n "$DESK" ]; then
  if command -v gh >/dev/null 2>&1; then
    printf '%s\n' "# brain-kit desk ledger: one owner/repo per line (scripts/desk_ledger.py)" > "$BRAIN_ROOT/desk-ledger.repos"
    for r in $DESK; do printf '%s\n' "$r" >> "$BRAIN_ROOT/desk-ledger.repos"; done
    ok "repos written to $BRAIN_ROOT/desk-ledger.repos"
    if [ "$SYSD" = "1" ]; then install_unit brain-desk-ledger
    else echo "   no systemd --user here: add this cron line for the hourly ledger:"
         echo "     7 * * * * python3 \"$BRAIN_ROOT/scripts/desk_ledger.py\""; fi
    echo "   first run by hand: python3 \"$BRAIN_ROOT/scripts/desk_ledger.py\""
  else echo "   desk ledger skipped: gh is not on PATH"; fi
else ok "desk ledger skipped (no repos given)"; fi
say "(8/8) opt-ins: context window, self-compact"
if [ "$CTXWIN" != "no" ]; then
  PS="$PROJECT/.claude/settings.json"; mkdir -p "$PROJECT/.claude"
  [ -f "$PS" ] || echo '{}' > "$PS"
  "$PYBIN" - "$PS" "$CTXWIN" <<'PY' || die "could not write $PS"
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); cfg = json.loads(p.read_text() or "{}")
cfg.setdefault("env", {})["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = sys.argv[2]
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
  ok "CLAUDE_CODE_AUTO_COMPACT_WINDOW=$CTXWIN in $PS (restart the session: settings env is read at startup)"
else ok "context window left as is"; fi
SC="$BRAIN_ROOT/scripts/self-compact.sh"
if [ "$SELFC" != "no" ]; then
  chmod +x "$SC"
  mkdir -p "$PROJECT/.claude"; printf '%s\n' "$SELFC" > "$PROJECT/.claude/self-compact-session"
  PCM="$PROJECT/CLAUDE.md"
  if grep -q "brain-kit-self-compact" "$PCM" 2>/dev/null; then ok "self-compact block already in $PCM"
  else sed "s|<vault>|$VAULT|g; s|<brain-root>|$BRAIN_ROOT|g" "$KIT/docs/SELF_COMPACT_BLOCK.md" >> "$PCM"; ok "self-compact block appended to $PCM"; fi
  ok "self-compact on: tmux session '$SELFC' (log: $CLAUDE_DIR/brain-kit-state/self-compact.log)"
elif [ "$SC_ON" = "1" ]; then chmod +x "$SC"; ok "self-compact kept from the earlier install"
else chmod -x "$SC" 2>/dev/null || true; ok "self-compact not installed (the script stays in place without its executable bit)"; fi
say "building the index"
# After the seed, not before it: an index built earlier would miss the example decision record
# and the belief-ledger template this step just copied in.
if [ "$EMBED" = "1" ]; then
  BRAIN_ROOT="$BRAIN_ROOT" BRAIN_DIR="$VAULT" "$BRAIN_ROOT/.venv/bin/python" "$BRAIN_ROOT/scripts/brain_index.py" build --embed \
    && ok "brain.db built (BM25 + BGE-M3)" || die "index build failed"
else
  BRAIN_ROOT="$BRAIN_ROOT" BRAIN_DIR="$VAULT" "$BRAIN_ROOT/.venv/bin/python" "$BRAIN_ROOT/scripts/brain_index.py" build \
    && ok "brain.db built (BM25 only - no torch needed)" || die "index build failed"
fi
say "done - restart your agent session so the hooks load, then read README.md"
echo "   smoke test: BRAIN_ROOT=\"$BRAIN_ROOT\" BRAIN_INDEX=sqlite python3 \"$BRAIN_ROOT/scripts/brain_bm25.py\" \"example decision\" 3"
echo "   manual recall: \"$BRAIN_ROOT/scripts/brain-search\" \"example decision\""
echo "   index stats: BRAIN_ROOT=\"$BRAIN_ROOT\" BRAIN_DIR=\"$VAULT\" \"$BRAIN_ROOT/.venv/bin/python\" \"$BRAIN_ROOT/scripts/brain_index.py\" stats"
echo "   re-embed after --no-embed: BRAIN_ROOT=\"$BRAIN_ROOT\" BRAIN_DIR=\"$VAULT\" \"$BRAIN_ROOT/.venv/bin/python\" \"$BRAIN_ROOT/scripts/brain_index.py\" build --embed"
