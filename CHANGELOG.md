# Changelog

What changed in each release, newest first. Versions are [semantic](https://semver.org/) and every
release is a git tag (`v1.0.0`) - the tag is what the update check reads, and `VERSION` next to your
install is what it compares against.

## [1.0.0] - 2026-09-20

The first numbered release. Until now "the kit" meant whatever `main` happened to be, so an installed
copy could not tell you how old it was and an update was a diff by hand. From here on there is a
version next to the install, a tag per release, and one line at session start when a newer tag exists.

### Added
- **Update notice** - `hooks/update-notice.sh` (SessionStart). At most once a day, 2 s budget,
  `git ls-remote --tags` only. It tells; it never installs. Only a version number reaches the model:
  tags are filtered whole-line against `^v[0-9]+\.[0-9]+\.[0-9]+$`, so free text on the remote side
  cannot enter your context. No network, no tags, or a timeout means no output and exit 0.
  `BRAIN_UPDATE_CHECK=0` turns it off; `BRAIN_UPDATE_REMOTE` points it somewhere else (a fork).
- **`scripts/update.sh`** - applies a release when you ask for it. It moves to the *tag*, not to the tip
  of `main`; prints this file's section for the new version and the exact list of files it would
  replace; asks before writing (`--yes` skips, `--dry-run` stops); and copies anything you edited by
  hand into `$BRAIN_ROOT/backups/<stamp>/` before overwriting it. The vault, `settings.json` and your
  skills are never touched.
- **`UPGRADE.md`** - the instruction sheet, written for the model that will run the update, because a
  kit whose installer is a model should have model-readable upgrade instructions too.
- **Per-project context thresholds** - `context-inject.sh` reads `<project>/.claude/ctx-thresholds`
  (`WARN=` and `HARD=`, tokens or `k`). One window size does not fit a five-file repo and a monorepo:
  the warning belongs to the project, not to the machine. No restart needed - the file is read on every
  prompt. `BRAIN_CTX_WARN` remains the global default.
- **`scripts/usage_report.py`** - what a day of sessions actually cost, per project, from the
  transcripts: calls, sub-agent calls, user turns, context per call, cache-read / cache-create / input /
  output tokens and a single comparable "equivalent" figure. Deduplicated by `message.id`.
- **`docs/WATCHERS.md`** - the "keep the watcher outside the model" pattern: why a polling loop that
  lives inside the session burns tokens for nothing, and what to run instead.
- **`docs/DISCIPLINE.md` §9** - two lessons about measuring from transcripts, both learned the
  expensive way.

### Fixed
- `setup.sh` copied only `scripts/*.py`, so `scripts/context_budget.sh` never reached the install and
  the README's "run it after any change" advice pointed at a file that was not there. It now copies the
  shell scripts too, records `VERSION` in the install root, and writes `BRAIN_UPDATE_REMOTE` from the
  checkout's own origin - in its https form, so an ssh clone does not turn the daily check into an
  authenticated call, and only when the address is plain address characters, because every hook
  sources that file.
- `skills/find-skills` named its author as the one who approves an install and listed the projects of
  the author's own machine. It now speaks about the user and about whatever shares the skills folder.
