# Changelog

What changed in each release, newest first. Versions are [semantic](https://semver.org/) and every
release is a git tag (`v1.0.0`) - the tag is what the update check reads, and `VERSION` next to your
install is what it compares against.

## [1.1.0] - 2026-09-23

A measurement release. 1529 prompt/read pairs from four real sessions over one week were matched up - which notes
recall injected, and which of those the model then opened - and four of the things recall did turned out to
be noise or worse. Nothing here changes what you write or where it lives; the vault format is untouched.
Measured on the author's vault against two gold sets: hit@1 0.600 -> 0.633 and MRR 0.722 -> 0.739 (n=30),
unchanged at hit@1 0.600 / MRR 0.717 (n=15), hit@3 unchanged in both.

### Changed
- **Usage reinforcement now counts reading, not showing.** The counter behind BM25's usage multiplier used
  to be written by the renderer, so a note scored a point every time recall *printed* it - a note the model
  ignored ten times outranked one it opened once. Notes sitting at the counter's cap were 71.7% of all
  injections and were opened 5.4% of the time, against 8.3% for notes below it. The multiplier is unchanged;
  it now reads a counter written by a new `PostToolUse` hook on `Read` (see Added). **Existing installs: the
  old counts measure the wrong thing - reset `<vault>/.index/recall_counts.json` to `{}` when you upgrade.**
- **A three-word prompt gets no recall block.** "go on", "yes do it", "thanks": 88 such blocks in the data,
  and not one note in them was opened. `BRAIN_RECALL_MIN_WORDS` (4) moves the line, `BRAIN_RECALL_FORCE=1`
  exempts a deliberate lookup.
- **A repeat that nobody used is dropped.** Within one session, a note already shown is not shown again if it
  is only FAIR and shares no word with the prompt (339 lines, 22% of all output, read 1.2% of the time
  against a 6.2% baseline), or if it reads like a handover note and has never been opened (171 lines, 3.5%).
  Every note still gets its first showing unconditionally, shared-docs hits are never filtered, and when
  everything is filtered the block is silent rather than claiming nothing matched. `BRAIN_RECALL_REPEAT_FILTER=0`
  restores the old behaviour. The per-session state lives in `<agent-config-dir>/brain-kit-state/seen_*.json`
  and is swept after two days.
- **The printed score is now the engine's own measure.** A line both engines found still prints the RRF value
  (`3.3bd`); a line only one found prints its cosine (`0.71d`) or its BM25 score as a fraction of the best one
  for that query (`0.83b`). The old number was derived from the rank, which the line order already shows, and
  four of five printed scores were therefore saying nothing (0.553 AUC at separating read notes from unread
  ones). The trailing `b`/`d`/`bd` letters are unchanged, so anything parsing them keeps working.
- **The dense daemon no longer encodes whole documents.** Queries are cut to 192 tokens and 1500 characters
  (`BRAIN_EMB_MAX_TOKENS`, `BRAIN_Q_MAX_CHARS`, and `BRAIN_DENSE_Q_MAX` on the client side). CPU encode time is
  linear in query length - 300 words took 2.8 s, 2000 words 30 s - so a pasted report blew past the client
  timeout and, because the daemon is single-threaded, blocked every other session's dense call behind it (29
  timeouts in one 24-hour window). After the caps, every length answers in 0.35-0.73 s, with the gold-set
  numbers unchanged.

### Added
- **`hooks/recall-usage-count.sh` + `scripts/brain_usage_count.py`** - `PostToolUse` on `Read`: when the model
  opens a note in the vault or a memory root, its basename is counted in `<vault>/.index/recall_counts.json`
  (flock + atomic rename, standard library, no output). Re-run `setup.sh` to wire it.
- **`BRAIN_RRF_RECENCY`** - a freshness bonus on the fused score, **off by default and staying off**: it is in
  the tree because the measurement is worth having. Same-day notes are the ones that get opened (17.0% against
  4.3% for notes older than a month), but applying that to the fusion cost hit@1 0.633 -> 0.533 and MRR 0.739
  -> 0.689 on the 30-query set. A fresh note does reach the top - it is just not the one that answers the
  question. `=1` if your own gold set disagrees.

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
