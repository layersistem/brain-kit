# Changelog

What changed in each release, newest first. Versions are [semantic](https://semver.org/) and every
release is a git tag (`v1.0.0`) - the tag is what the update check reads, and `VERSION` next to your
install is what it compares against.

## [1.1.1] - 2026-09-23

A release about the moments the kit was silent when it should have spoken, and loud when it should have kept
quiet. Four of the five changes were found the same way: a session that did the wrong thing, a transcript
that showed why. The write hook cost 14 s per note because it loaded a 2 GB model every time; the context
warning came so late on a narrowed window that auto-compaction won the race; the number printed on the first
turn after a compaction was the pre-compaction one, which with self-compact would have ordered a second
compaction on the spot; and an agent said "I would need the device" about five rules whose issues and PRs
it had closed itself the month before, because nobody had searched for their names. The vault format is
untouched. Two of the additions are opt-in and the installer now asks before installing them.

### Changed
- **The write hook no longer loads the embedding model.** Measured over 24 hours of transcripts: 1453 runs
  of `brain-embed-after-write.sh`, the ones with a changed note averaging 14.4 s (max 50 s) against 0.6 s for
  unchanged ones - the whole difference was BGE-M3 loading from scratch on every edit, 330 minutes a day on
  the tool path. The hook now runs `brain_index.py update` without `--embed` (chunks and BM25 rows, about
  1 s; BM25 recall sees the note at once) and leaves the vectors to `scripts/brain_index_sweep.sh`, which
  the hook starts in the background and a 2-minute timer runs anyway. Dense recall lags a write by about
  15 s instead of the write costing 15 s. `BRAIN_EMBED_SYNC=1` restores the inline embed.
- **Context thresholds are two tiers at 50% and 65%.** The single 80% warning was measured against a
  narrowed `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and came one tool result before auto-compaction. WARNING now
  says "compact at the next clean boundary, prepare the handoff note"; HARD says "compact now". The window
  is `BRAIN_CTX_WINDOW`, else `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (from the environment or the project's
  `.claude/settings.json`), else the model default. `BRAIN_CTX_WARN` / `BRAIN_CTX_HARD` and
  `<project>/.claude/ctx-thresholds` still override. If you tuned your work around the 80% line, set
  `BRAIN_CTX_WARN` back.
- **No threshold order on the first turn after a compaction.** When the transcript's last event after the
  newest `usage` line is a compact boundary, the only number available is the pre-compaction one - the one
  that crossed the threshold. The hook now prints "first turn after compact, no measurement yet", gives no
  order, and clears its per-session delta file. Printing the stale number would have looped self-compact.
- **`brain_index.py` reports the vectors it wrote** (`embedded: N` on its summary line) so the sweeper can
  log a run that did something and stay quiet otherwise.
- **`scripts/update.sh`** also carries `scripts/brain-search`, `scripts/systemd/*` and `patterns/*`, and
  restores `scripts/self-compact.sh`'s executable bit to what it was before the update: whoever answered
  "no" to self-compact stays at no.

### Added
- **`scripts/self-compact.sh` + `docs/self-compact.md` + `docs/SELF_COMPACT_BLOCK.md`** - the agent compacts
  its own session, opt-in. At the hard threshold the context hook says "self-compact now"; the agent writes
  the handover note and the focus summary, starts the script as the last command of its turn, and ends the
  turn. The script waits for the turn to end (the pane shows "esc to interrupt" while busy), sends `/compact`
  with `tmux send-keys`, counts compact boundaries in the transcript from the JSON fields (a session's own
  tool output can contain the string), and types the continuation line when a new one appears. Every step is
  logged with a timestamp, starting with "started"; 30 minutes for the turn, 20 for the boundary;
  `SKIP_COMPACT=1` when the compact was typed by hand; a second copy for the same project exits with
  "already running", matched on the script's own process and never on the shell that launched it.
- **`scripts/brain_index_sweep.sh` + `scripts/systemd/brain-index-sweep.{service,timer}`** - the background
  embedder described above. Same mkdir lock as the hook, a lock older than 30 minutes is treated as a crash
  leftover, `BRAIN_SWEEP_THREADS` (4) caps torch, one log line per run that changed something or failed.
  `setup.sh` installs and enables the timer where `systemd --user` answers, prints the cron line elsewhere,
  and `--no-timers` skips it.
- **`hooks/unsearched-absence-stop.sh`** (`Stop`, `full` profile) - blocks a turn whose answer says a named
  thing is missing, unknown or waited for ("no record of `x-y-z`", "I would need the device", "waiting for")
  when nothing in the turn searched for that name (`brain-search`, `grep`, `rg`, a Grep or Glob call,
  `gh ... --search`). At most two blocks per turn, then it passes with a "brake" line in
  `brain-kit-state/absence-gate.log`. Fenced code in the answer is ignored, names are kebab-case with two or
  more hyphens, the English claim phrases are built in, and `<project>/.claude/absence-patterns` or
  `BRAIN_ABSENCE_RX_FILE` replaces them (`patterns/absence-claims.en.txt` is the built-in list,
  `patterns/absence-claims.tr.txt` a Turkish one). Under 70 ms on the turns it inspects. `BRAIN_ABSENCE_GATE=0`
  turns it off.
- **`scripts/brain-search`** - recall by hand: `brain-search "<query>" [k]` runs the same hook the prompt runs
  and prints the same block, with the short-prompt gate lifted so a one-word name query works. It is the
  search the absence gate asks for.
- **`scripts/desk_ledger.py` + `scripts/systemd/brain-desk-ledger.{service,timer}`** - hourly export of your
  repos' issues and PRs into `knowledge/desk-ledger-<owner>-<repo>.md` (exact titles and branch names, state
  with date, author, and the kebab-case identifiers mentioned in bodies and comments - the text itself is never
  copied), plus `moc/MOC-desk-ledger.md`. Sections are packed to 3500 characters because the index splits on
  `##` and reads the first 4000 of each. Repos from `--repo`, `BRAIN_DESK_REPOS` or `<BRAIN_ROOT>/desk-ledger.repos`;
  `setup.sh` installs the timer only when `gh` is present and you list repos, and skips silently otherwise.
- **Installer prompts and flags.** `setup.sh` asks two questions and installs neither feature on an empty
  answer: narrow the context window (writes `CLAUDE_CODE_AUTO_COMPACT_WINDOW` into the project's
  `.claude/settings.json`; suggested 500000), and install self-compact (tmux session name, default the current
  one). Non-interactive: `--context-window=<N|no>`, `--self-compact=<session|no>`, `--yes-defaults`,
  `--project=DIR`, `--desk-repos=...`, `--no-timers`; stdin not a terminal and no flag means no. Re-running the
  installer with "no" keeps an earlier "yes": not installing is not uninstalling.
- **Usage counter, remote mode.** `BRAIN_RECALL_REMOTE=1` sends the Read hook's increment to the dense daemon's
  new `GET /count?name=` endpoint instead of writing `recall_counts.json` - one writer for a vault that a second
  machine reads over a network share, where two writers race and the stale one wins. `brain_usage_count.bump()`
  is the shared body; the name is validated before it touches the file.

### Fixed
- **`scripts/update.sh` stopped part-way through whenever the release changed `update.sh` itself.** bash reads
  a script as it runs it, and the updater copies the new `scripts/update.sh` over the one that is running; from
  that line on it was executing the new file at the old byte offset, so the chmod, the backup summary, the
  `VERSION` write and the closing message never ran (exit 0, `VERSION` still the old number - measured on
  both 1.0.0 -> 1.1.0 shaped updates). The body now sits in one brace group, which bash parses in full
  before running the first command.

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
