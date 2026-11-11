#!/bin/sh
# _platform.sh - sourced by every hook right after brain-kit.env. Outside Windows it defines one pass-through
# function and returns; nothing is started and nothing changes.
#
# Windows: Claude Code runs hooks in Git Bash (Git for Windows), and three things differ there. Until this file
# the kit installed with four manual workarounds and then looked healthy while its write side did nothing: every
# hook exited 0, but a new note never reached the index, the hygiene check never spoke, and the pointer after a
# compaction never printed (measured on a clean Windows 11 machine, 11 Nov 2026).
#
#   1. Names and line ends. `python3` is a Microsoft Store placeholder, not Python, and a native jq.exe ends every
#      line with CR LF, so a value read from it never equals the text it is compared with. setup.sh puts a
#      python3.exe next to the kit's own interpreter (<root>/.venv/Scripts) and a jq wrapper that adds --binary
#      into <root>/winbin; both folders go to the front of PATH here. PYTHONUTF8=1 makes Python read and write
#      UTF-8 instead of the Windows code page, and <root>/.venv/Lib/site-packages/sitecustomize.py (written by
#      setup.sh) ends Python's output lines with LF.
#   2. Path forms. Claude Code hands a hook "C:\Users\me\brain\vault\note.md"; this shell knows the vault as
#      "/c/Users/me/brain/vault". brain_fp turns the first form into the second, so a text comparison with the
#      vault path works. CLAUDE_PROJECT_DIR, and a SESSION_ROOT the hook has already set, are converted too.
#   3. The agent's per-project memory folder is named after the Windows form of the project path
#      (C:\Users\me\proj -> C--Users-me-proj); BRAIN_MEMORY2 gets that default here unless it is already set.
#
# The lines after the platform test use bash syntax. That is safe: Git Bash's sh is bash, and a POSIX sh on
# another system has returned before it reads them.
brain_fp() { printf '%s' "$1"; }
case "${OSTYPE:-}" in msys*|cygwin*) ;; *) return 0 2>/dev/null || exit 0 ;; esac

brain_fp() {   # C:\a\b or C:/a/b -> /c/a/b ; anything else unchanged. No process is started.
  case "$1" in
    [A-Za-z]:[\\/]*) local d="${1%%:*}" r="${1#*:}"; printf '/%s%s' "${d,,}" "${r//\\//}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_bk_root="${BRAIN_ROOT:-$HOME/brain}"
case ":$PATH:" in *":$_bk_root/winbin:"*) ;; *) PATH="$_bk_root/winbin:$_bk_root/.venv/Scripts:$PATH" ;; esac
PYTHONUTF8=1; export PATH PYTHONUTF8
case "${CLAUDE_PROJECT_DIR:-}" in
  [A-Za-z]:[\\/]*)
    [ -n "${BRAIN_MEMORY2:-}" ] || BRAIN_MEMORY2="$HOME/.claude/projects/${CLAUDE_PROJECT_DIR//[:\\\/ _]/-}/memory"
    CLAUDE_PROJECT_DIR=$(brain_fp "$CLAUDE_PROJECT_DIR"); export CLAUDE_PROJECT_DIR BRAIN_MEMORY2 ;;
esac
case "${SESSION_ROOT:-}" in [A-Za-z]:[\\/]*) SESSION_ROOT=$(brain_fp "$SESSION_ROOT") ;; esac
unset _bk_root
