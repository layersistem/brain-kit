#!/usr/bin/env bash
# brain-kit updater - moves an installed kit to a tagged release. Nothing here runs on its own:
# the SessionStart notice only tells you a newer tag exists, and this script still shows the
# changes and asks before it writes anything.
#
# Usage: update.sh [--yes] [--to vX.Y.Z] [--dry-run]
#   --yes      skip the confirmation prompt (for a session that already has the user's go-ahead)
#   --to       install this exact tag instead of the newest one (downgrades allowed, deliberately)
#   --dry-run  show what would change and stop
#
# What it touches: $BRAIN_ROOT/hooks, $BRAIN_ROOT/scripts, $BRAIN_ROOT/patterns, $BRAIN_ROOT/VERSION. Never the
# vault, never your settings.json (global or per project), never a CLAUDE.md, never a skill you have edited.
# Anything you changed by hand is copied into $BRAIN_ROOT/backups/<stamp>/ before it is overwritten, and the
# path of every backup is printed. The two opt-ins setup.sh asks about (context window, self-compact) are
# not touched either: the window lives in the project's settings.json, and self-compact's on/off state is
# its executable bit plus BRAIN_SELF_COMPACT in brain-kit.env - both restored to what they were.
#
# The whole body sits in one brace group. bash reads a script as it runs it, and this script replaces
# itself (scripts/update.sh is in the release) part-way through: without the group, every line after
# that copy - the chmod, the opt-in restore, the VERSION write, the closing message - was read from the
# NEW file at the old byte offset and silently never ran (measured 23 Sep 2026: VERSION stayed at the old
# number, no "brain-kit is now" line, exit 0). A brace group is parsed in full before the first command.
{
set -euo pipefail
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$CFG/brain-kit.env" ] && . "$CFG/brain-kit.env" 2>/dev/null || true
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
REMOTE="${BRAIN_UPDATE_REMOTE:-https://github.com/layersistem/brain-kit}"
YES=0; DRY=0; WANT=""
while [ $# -gt 0 ]; do case "$1" in
  --yes|-y) YES=1 ;;
  --dry-run) DRY=1 ;;
  --to) shift; WANT="${1:-}" ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac; shift; done
die(){ printf 'update failed: %s\n' "$1" >&2; exit 1; }
command -v git >/dev/null 2>&1 || die "git not found"
[ -d "$BRAIN_ROOT/hooks" ] && [ -d "$BRAIN_ROOT/scripts" ] || die "no install at $BRAIN_ROOT"
LOCAL=$(head -c 32 "$BRAIN_ROOT/VERSION" 2>/dev/null | tr -d ' \t\r\n' || true)
[ -n "$LOCAL" ] || LOCAL="unknown (installed before versions existed)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/brain-kit-update.XXXXXX")
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# 1. a source to read the release from. A checkout we are sitting in is used as-is (its branch is
#    never moved - every file comes out through `git archive`); otherwise we clone into $WORK.
#    `setup.sh` next to `.git` is what makes it a kit checkout: an install root that the user keeps
#    under git of their own must not have this project's tags fetched into it.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$SRC/.git" ] && [ -f "$SRC/setup.sh" ]; then
  git -C "$SRC" fetch --quiet --tags "$REMOTE" 2>/dev/null || echo "   (offline: using the tags this checkout already has)"
else
  echo "== fetching $REMOTE"
  git clone --quiet "$REMOTE" "$WORK/src" || die "clone failed - no network, or the remote is wrong"
  SRC="$WORK/src"
fi

# 2. which tag. Only vX.Y.Z is a release; anything else in the tag list is ignored.
pick_tag(){ git -C "$SRC" tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
  awk -F'[v.]' '{ if ($2>a || ($2==a && ($3>b || ($3==b && $4>c)))) { a=$2; b=$3; c=$4 } }
                END { if (a != "") printf "v%d.%d.%d", a, b, c }'; }
if [ -n "$WANT" ]; then
  printf '%s' "$WANT" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "--to takes a vX.Y.Z tag"
  TAG="$WANT"
  git -C "$SRC" rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null || die "no such tag: $TAG"
else
  TAG=$(pick_tag); [ -n "$TAG" ] || die "the remote has no vX.Y.Z tag yet"
fi
NEW="${TAG#v}"
if [ "$NEW" = "$LOCAL" ] && [ -z "$WANT" ]; then
  echo "brain-kit $LOCAL is already the newest release. Nothing to do."; exit 0
fi

# 3. lay the release out and see what actually differs from the install
mkdir -p "$WORK/new"; git -C "$SRC" archive "$TAG" | tar -x -C "$WORK/new"
OLD=""
if git -C "$SRC" rev-parse --quiet --verify "refs/tags/v$LOCAL" >/dev/null 2>&1; then
  OLD="$WORK/old"; mkdir -p "$OLD"; git -C "$SRC" archive "v$LOCAL" | tar -x -C "$OLD"
fi
CHANGED=""; MODIFIED=""
# the list comes from the release, not from the current directory - a glob here would expand
# against wherever the user happened to run this from and quietly find nothing.
FILES=$(cd "$WORK/new" && ls -1 hooks/*.sh scripts/*.py scripts/*.sh scripts/brain-search scripts/systemd/* patterns/* 2>/dev/null || true)
for rel in $FILES; do
  inst="$BRAIN_ROOT/$rel"
  if [ ! -e "$inst" ] || ! cmp -s "$inst" "$WORK/new/$rel"; then CHANGED="$CHANGED $rel"; fi
  # user-modified = the installed file no longer matches the release it came from
  if [ -e "$inst" ] && [ -n "$OLD" ] && [ -e "$OLD/$rel" ] && ! cmp -s "$inst" "$OLD/$rel"; then
    MODIFIED="$MODIFIED $rel"
  fi
done
[ -n "$OLD" ] || MODIFIED="$CHANGED"   # cannot tell what you edited: back up everything being replaced

echo
echo "== brain-kit $LOCAL  ->  $NEW   ($BRAIN_ROOT)"
awk -v v="$NEW" '$0 ~ "^## \\[" v "\\]" { p=1; print; next } p && /^## \[/ { exit } p { print }' \
  "$WORK/new/CHANGELOG.md" 2>/dev/null || true
echo "files this would replace:"; for f in $CHANGED; do echo "   $f"; done
[ -n "$CHANGED" ] || { echo "   (none - the installed files already match $TAG)"; }
if [ -n "$MODIFIED" ]; then
  echo "changed by you since install - these get backed up first:"; for f in $MODIFIED; do echo "   $f"; done
fi
echo "your vault, settings.json, CLAUDE.md, skills and the setup.sh opt-ins are not touched."
[ "$DRY" = "1" ] && exit 0
[ -n "$CHANGED" ] || exit 0

# 4. consent, then write
if [ "$YES" != "1" ]; then
  printf 'apply it? [y/N] '
  read -r ans < /dev/tty || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "nothing was changed."; exit 0 ;; esac
fi
STAMP="$BRAIN_ROOT/backups/$(date +%Y%m%d-%H%M%S)-v$LOCAL"
# self-compact is opt-in: whether it is on is the executable bit of scripts/self-compact.sh (set by setup.sh
# on a yes, cleared on a no). Remember it now; the chmod below must not switch it on for someone who said no.
SC_WAS_X=0; [ -x "$BRAIN_ROOT/scripts/self-compact.sh" ] && SC_WAS_X=1
for rel in $MODIFIED; do
  case " $CHANGED " in *" $rel "*) ;; *) continue ;; esac     # only what is about to be overwritten
  inst="$BRAIN_ROOT/$rel"; [ -e "$inst" ] || continue
  mkdir -p "$STAMP/$(dirname "$rel")"; cp -p "$inst" "$STAMP/$rel"; echo "   backed up $rel -> $STAMP/$rel"
done
for rel in $CHANGED; do
  mkdir -p "$BRAIN_ROOT/$(dirname "$rel")"; cp -f "$WORK/new/$rel" "$BRAIN_ROOT/$rel"
done
chmod +x "$BRAIN_ROOT"/hooks/*.sh "$BRAIN_ROOT"/scripts/*.sh "$BRAIN_ROOT/scripts/brain-search" 2>/dev/null || true
[ "$SC_WAS_X" = "1" ] || chmod -x "$BRAIN_ROOT/scripts/self-compact.sh" 2>/dev/null || true   # keep the install's choice
printf '%s\n' "$NEW" > "$BRAIN_ROOT/VERSION"
echo
echo "brain-kit is now $NEW. Restart the session so the hooks reload."
echo "Full release notes: CHANGELOG.md, section [$NEW], in the checkout you installed from."
exit 0
}
