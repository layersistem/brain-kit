#!/usr/bin/env bash
# brain-kit installer - persistent memory + consolidation for Claude Code and other agent CLIs.
# Usage: ./setup.sh [--minimal] [--no-embed] [--project=DIR] [--context-window=<N|auto>] [--self-compact=<session|no>]
#                   [--caveman=<yes|no>] [--desk-repos="owner/a owner/b"] [--no-timers] [--yes-defaults]
#   --minimal          14 of the 18 hook entries: no postwrite check, no mutation log, no Stop gates; no consolidation skill
#   --no-embed         BM25 recall only: no torch, no model download, embedding hook and sweeper stay idle
#   --project=DIR      the project whose .claude/settings.json and CLAUDE.md the opt-ins touch (default:
#                      CLAUDE_PROJECT_DIR, else the current directory)
#   --context-window=  N writes CLAUDE_CODE_AUTO_COMPACT_WINDOW=N into <project>/.claude/settings.json (env);
#                      "auto" (or "no") writes nothing: the hooks use the model's own window. Asked interactively
#                      when the flag is absent; default: auto.
#   --self-compact=    a tmux session name installs self-compact for that session; "no" leaves it off. Asked
#                      interactively when the flag is absent; default: no.
#   --caveman=         "yes" installs the caveman skill (compressed chat replies in EVERY session of EVERY
#                      project - it is a user-level skill); "no" leaves it out. Asked interactively when the
#                      flag is absent; default: no. An earlier install's copy is never removed by this script.
#   --desk-repos=      "owner/repo ..." installs the hourly desk ledger for those repos (needs gh); absent = skipped
#   --no-timers        do not install systemd user timers or the macOS launchd agent (print the cron lines instead)
#   --yes-defaults     no prompts at all: every question takes its default (the opt-ins default to no / auto)
# Env: BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . CLAUDE_CONFIG_DIR (~/.claude) .
#      BRAIN_INSTANCE (main).  Idempotent: never overwrites notes, settings or existing skills. A re-run takes its
#      defaults from the existing <config>/brain-kit.env and keeps every line you added to that file.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=full; EMBED=""; PROJECT=""; CTXWIN=""; SELFC=""; CAVE=""; DESK=""; TIMERS=1; YESDEF=0
for a in "$@"; do case "$a" in
  --minimal) PROFILE=minimal ;;
  --no-embed) EMBED=0 ;;
  --project=*) PROJECT="${a#*=}" ;;
  --context-window=*) CTXWIN="${a#*=}" ;;
  --self-compact=*) SELFC="${a#*=}" ;;
  --caveman=*) CAVE="${a#*=}" ;;
  --desk-repos=*) DESK="${a#*=}" ;;
  --no-timers) TIMERS=0 ;;
  --yes-defaults) YESDEF=1 ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 2 ;;
esac; done
say(){ printf '\n== %s\n' "$1"; }
ok(){ printf '   ok  %s\n' "$1"; }
die(){ printf '\nFAILED: %s\n' "$1" >&2; exit 1; }
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Upgrade keeps your settings (1.2.0): the values an earlier install wrote to <config>/brain-kit.env are this run's
# defaults. The file is read in a subshell with those variables unset, so its own values come through rather than the
# ones its "${VAR:-...}" form would take from this shell. A flag, an answer or an exported variable still wins.
OWNED="BRAIN_ROOT BRAIN_DIR BRAIN_EMBED BRAIN_INDEX BRAIN_UPDATE_CHECK BRAIN_UPDATE_REMOTE BRAIN_SELF_COMPACT"
prior_env(){ # $1 = env file -> PREV_<name> for each variable above (empty when the file or the line is missing)
  for v in $OWNED; do eval "PREV_$v=''"; done
  [ -f "$1" ] || return 0
  eval "$(bash -c 'unset '"$OWNED"'; set +eu; . "$1" >/dev/null 2>&1
    for v in '"$OWNED"'; do printf "PREV_%s=%q\n" "$v" "${!v-}"; done' _ "$1" 2>/dev/null)"
}
prior_env "$CLAUDE_DIR/brain-kit.env"; CLAUDE_DIR0="$CLAUDE_DIR"
BRAIN_ROOT="${BRAIN_ROOT:-${PREV_BRAIN_ROOT:-$HOME/brain}}"
PROJECT="${PROJECT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ASK=0; [ -t 0 ] && [ "$YESDEF" = "0" ] && ASK=1
if [ "$ASK" = "1" ]; then
  read -r -p "brain root [$BRAIN_ROOT]: " _a || true; [ -n "${_a:-}" ] && BRAIN_ROOT="$_a"
  read -r -p "agent config dir [$CLAUDE_DIR]: " _b || true; [ -n "${_b:-}" ] && CLAUDE_DIR="$_b"
  read -r -p "project dir (its .claude/settings.json and CLAUDE.md take the opt-ins) [$PROJECT]: " _c || true; [ -n "${_c:-}" ] && PROJECT="$_c"
fi
[ "$CLAUDE_DIR" = "$CLAUDE_DIR0" ] || prior_env "$CLAUDE_DIR/brain-kit.env"   # another config dir: its own file decides
PROJECT="${PROJECT%/}"
# The context-window opt-in (23 Sep 2026; 1.2.0: the suggestion is "auto"). "auto" writes nothing: the hooks use the
# model's own window (200k, or 1M for a "[1m]" model), and context-inject.sh clips a configured window to it. A number
# narrows the window through CLAUDE_CODE_AUTO_COMPACT_WINDOW in the project's .claude/settings.json; the hooks' warning
# (50%) and hard (65%) lines are fractions of it. 1.1.x suggested 500000 - more than a 200k model's whole window, where
# the 50% and 65% lines could then never fire.
if [ -z "$CTXWIN" ]; then
  CTXWIN=auto
  if [ "$ASK" = "1" ]; then
    read -r -p "Context window for the warnings and auto-compact: 'auto' uses the model's own window, a number of tokens narrows it (written to the project's .claude/settings.json) [auto]: " _d || true
    CTXWIN="${_d:-auto}"
  fi
fi
case "$CTXWIN" in auto|AUTO|no|NO|n|N|"") CTXWIN=auto ;; *[!0-9]*) die "--context-window takes a number of tokens or 'auto' (got '$CTXWIN')" ;; esac
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
# caveman (1.2.0): opt-in. Until 1.1.1 it was copied into <config>/skills on every install without a word in
# any document, and its own text calls itself mandatory in every session - so every project on the machine
# started answering in compressed prose. It is a style choice and the person installing makes it.
if [ -z "$CAVE" ]; then
  CAVE=no
  if [ "$ASK" = "1" ]; then
    read -r -p "Install the caveman skill? The agent then answers in compressed prose (about 65-75% fewer output tokens) in every session of every project - it is a user-level skill. [y/N] " _k || true
    case "${_k:-}" in y|Y|yes|YES) CAVE=yes ;; esac
  fi
fi
case "$CAVE" in yes|YES|y|Y) CAVE=yes ;; no|NO|n|N|"") CAVE=no ;; *) die "--caveman takes 'yes' or 'no' (got '$CAVE')" ;; esac
if [ -z "$DESK" ] && [ "$ASK" = "1" ] && command -v gh >/dev/null 2>&1; then
  read -r -p "Desk ledger: GitHub repos to export hourly into the vault (owner/repo, space separated; empty = skip): " _h || true
  DESK="${_h:-}"
fi
# Embeddings: --no-embed decides; without it, an exported BRAIN_EMBED, then the earlier install's choice, then on.
# (A re-run without the flag no longer turns a BM25-only install into a 13 GB one; BRAIN_EMBED=1 ./setup.sh does.)
[ -n "$EMBED" ] || EMBED="${BRAIN_EMBED:-${PREV_BRAIN_EMBED:-1}}"
[ "$EMBED" = "0" ] || EMBED=1
_pd="${PREV_BRAIN_DIR:-}"; [ "$_pd" = "${PREV_BRAIN_ROOT:-}/vault" ] && _pd=""   # the old default follows a new root
VAULT="${BRAIN_DIR:-${_pd:-$BRAIN_ROOT/vault}}"; HOOKS="$BRAIN_ROOT/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"; INST="${BRAIN_INSTANCE:-main}"
say "brain-kit installer (profile=$PROFILE, embeddings=$EMBED)"
echo "   root=$BRAIN_ROOT   vault=$VAULT   config=$CLAUDE_DIR   instance=$INST"
echo "   project=$PROJECT   context-window=$CTXWIN   self-compact=$SELFC   caveman=$CAVE   desk-ledger=${DESK:-skipped}"
[ -n "${PREV_BRAIN_ROOT:-}" ] && echo "   defaults taken from the existing $CLAUDE_DIR/brain-kit.env (your own lines in it are kept)"
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
mkdir -p "$BRAIN_ROOT/docs"; cp -f "$KIT"/docs/*.md "$BRAIN_ROOT/docs/"   # the hooks point at <root>/docs (1.2.0)
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
SC_ON=0; [ "$SELFC" != "no" ] && SC_ON=1; [ "$SELFC" = "no" ] && [ "${PREV_BRAIN_SELF_COMPACT:-0}" = "1" ] && SC_ON=1
# The env file is merged, not rewritten (1.2.0). The lines of the variables this script owns are replaced in place,
# or appended when missing; every other line - your own settings, comments - stays as it was, and the earlier file
# is kept as brain-kit.env.bak.<epoch>. 1.1.x wrote the file from scratch on every run, so the upgrade step ("run
# setup.sh again") reset BRAIN_DIR to the default and dropped the lines added by hand. A second assignment of an
# owned variable further down is dropped: its value is already in the first one.
ENVF="$CLAUDE_DIR/brain-kit.env"
q(){ printf '%s' "$1" | sed 's/[\\"$`]/\\&/g'; }   # each value lands inside double quotes in a file every hook sources
NEWL=$(printf '%s="${%s:-%s}"\n' \
  BRAIN_ROOT BRAIN_ROOT "$(q "$BRAIN_ROOT")" \
  BRAIN_DIR BRAIN_DIR "$(q "$VAULT")" \
  BRAIN_EMBED BRAIN_EMBED "$EMBED" \
  BRAIN_INDEX BRAIN_INDEX "$(q "${PREV_BRAIN_INDEX:-sqlite}")" \
  BRAIN_UPDATE_CHECK BRAIN_UPDATE_CHECK "$(q "${PREV_BRAIN_UPDATE_CHECK:-1}")" \
  BRAIN_UPDATE_REMOTE BRAIN_UPDATE_REMOTE "$(q "${PREV_BRAIN_UPDATE_REMOTE:-$ORIGIN}")" \
  BRAIN_SELF_COMPACT BRAIN_SELF_COMPACT "$SC_ON")
SRC=/dev/null
[ -f "$ENVF" ] && { cp -p "$ENVF" "$ENVF.bak.$(date +%s)"; SRC="$ENVF"; }
{ [ "$SRC" = /dev/null ] && echo "# written by brain-kit setup.sh - every hook sources this. An exported variable still wins; lines you add are kept on re-runs."
  awk 'NR == FNR { n = $0; sub(/=.*/, "", n); line[n] = $0; order[++k] = n; next }
    { s = $0; sub(/^[ \t]*/, "", s); sub(/^export[ \t]+/, "", s); n = s
      if (sub(/=.*/, "", n) && (n in line)) { if (!(n in done)) { print line[n]; done[n] = 1 }; next }
      print }
    END { for (i = 1; i <= k; i++) if (!(order[i] in done)) print line[order[i]] }' <(printf '%s\n' "$NEWL") "$SRC"
} > "$ENVF.new" && mv -f "$ENVF.new" "$ENVF"
ok "$BRAIN_ROOT/scripts, $HOOKS, $BRAIN_ROOT/patterns, $BRAIN_ROOT/docs, $ENVF (merged; your own lines kept)"
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
  if [ "$sk" = "caveman" ] && [ "$CAVE" != "yes" ]; then
    # Not installing is not uninstalling: a copy from an earlier release stays, and the line says how to drop it.
    if [ -e "$CLAUDE_DIR/skills/caveman" ]; then
      ok "caveman not chosen, but $CLAUDE_DIR/skills/caveman is there from an earlier install - left alone; delete that folder to turn it off"
    else ok "caveman not installed (opt-in: --caveman=yes)"; fi
    continue
  fi
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
# hook and by this 2-minute timer. On macOS a launchd agent does the same (1.2.0; until then macOS got only the
# cron line, and without it new notes got no vectors). Without either (a container) the cron line does it.
SYSD=0; LAUNCHD=0
if [ "$TIMERS" = "1" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then SYSD=1; fi
if [ "$TIMERS" = "1" ] && [ "$SYSD" = "0" ] && [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then LAUNCHD=1; fi
install_agent(){ # macOS: a per-user launchd agent that runs the sweeper every 120 s, the systemd timer's job on Linux
  local LA="$HOME/Library/LaunchAgents" L="local.brain-kit.index-sweep" SWP
  SWP=$(printf '%s' "$BRAIN_ROOT/scripts/brain_index_sweep.sh" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  mkdir -p "$LA"
  cat > "$LA/$L.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$L</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SWP</string></array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$L" >/dev/null 2>&1 || launchctl unload "$LA/$L.plist" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$LA/$L.plist" >/dev/null 2>&1 || launchctl load -w "$LA/$L.plist" >/dev/null 2>&1; then
    ok "launchd agent $L loaded ($LA/$L.plist, every 2 min)"
  else echo "   could not load $LA/$L.plist - try: launchctl bootstrap gui/\$(id -u) \"$LA/$L.plist\""; fi
}
UD="$HOME/.config/systemd/user"
install_unit(){ # $1 = unit base name
  mkdir -p "$UD"
  sed "s#%h/brain#$BRAIN_ROOT#g" "$KIT/scripts/systemd/$1.service" > "$UD/$1.service"
  cp -f "$KIT/scripts/systemd/$1.timer" "$UD/$1.timer"
  systemctl --user daemon-reload && systemctl --user enable --now "$1.timer" >/dev/null 2>&1 && ok "$1.timer enabled" || echo "   could not enable $1.timer - see: systemctl --user status $1.timer"
}
if [ "$EMBED" = "1" ]; then
  if [ "$SYSD" = "1" ]; then install_unit brain-index-sweep
  elif [ "$LAUNCHD" = "1" ]; then install_agent
  else echo "   no systemd --user or launchd agent here: add this cron line for the vector sweeper:"
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
if [ "$CTXWIN" != "auto" ]; then
  PS="$PROJECT/.claude/settings.json"; mkdir -p "$PROJECT/.claude"
  [ -f "$PS" ] || echo '{}' > "$PS"
  "$PYBIN" - "$PS" "$CTXWIN" <<'PY' || die "could not write $PS"
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); cfg = json.loads(p.read_text() or "{}")
cfg.setdefault("env", {})["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = sys.argv[2]
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
  ok "CLAUDE_CODE_AUTO_COMPACT_WINDOW=$CTXWIN in $PS (restart the session: settings env is read at startup)"
else ok "context window: auto (nothing written; the hooks use the model's own window)"; fi
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
