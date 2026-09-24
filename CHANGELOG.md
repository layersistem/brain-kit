# Changelog

What changed in each release, newest first. Versions are [semantic](https://semver.org/) and every
release is a git tag (`v1.0.0`) - the tag is what the update check reads, and `VERSION` next to your
install is what it compares against. Every tag also has a GitHub Release that carries the same section as
this file.

## [1.2.0] - 2026-09-24

An audit release. The kit was installed from scratch on Ubuntu 24.04 in a container and every hook was run
against the result, and most of what turned up was the kit being wrong in ways a user would not see: recall
re-scanned the whole vault on every prompt because the hooks never exported `BRAIN_INDEX` (5.8-6.8 s per
prompt on a 2,000-note vault), re-running the installer - the documented upgrade step - reset the vault path
and dropped the lines added to `brain-kit.env` by hand, the installer put a compressed-prose skill into every
project on the machine without a word in any document, and the 1.1.1 absence gate never fired on Ubuntu
because its name filter used an awk feature mawk does not have. The rest came from the author's own install,
which the kit is taken from: the recall repeat filter dropped notes a compaction had already taken out of the
model's context, a focus file past about 10,000 characters reached the model as a 2 KB preview with its
truncation warning cut off, and the post-compact line asked for confirmation right after the agent had
compacted itself in order to carry on. The vault format is untouched; no new hook needs wiring, but the
installer should run again (UPGRADE.md, "Coming from 1.1.1").

Measured for this release: clean install and upgrade on ubuntu:24.04: install rc 0 (4 s, `--no-embed`), upgrade 1.1.1 -> 1.2.0 rc 0, with all 3 checked `brain-kit.env` values kept on a same-version re-run and on the upgrade (1.1.1 kept 0 of 3); recall on a 2,000-note vault median 254 ms (min 236, max 269, n=5; the prompt hook timed end to end on a 2,002-note vault in the container, BM25 only; 1.1.1 in the same harness: 8,327 ms); the longest hook output 8,458 characters (`_focus_inject.sh` on a 40,705-character focus file, warning on line 1; 1.1.1: 12,420 characters, warning on the last line); every hook and script parsed by bash 3.2 (`docker run --rm -i bash:3.2 bash -n < file`)
25 files, 0 errors; gitleaks 0 findings in the git history and 0 in the working tree. macOS: not installed or run on a Mac for this release; what was checked is that every shell file parses under bash 3.2 (the `bash:3.2` container above) and that the BSD-only and GNU-only calls listed under Fixed are gone from the diff. A clean install on a Mac is the first measurement owed to the next release..

### Changed
- **caveman is opt-in.** `setup.sh` used to copy `skills/caveman` into `<agent-config-dir>/skills` on every
  install; its own text makes it mandatory in every session, so every project on the machine started
  answering in compressed prose, and no document said so. It is now a question that defaults to no
  (`--caveman=yes|no`). A copy from an earlier install is never removed; the installer says where it is.
- **The installer merges `brain-kit.env` instead of rewriting it.** It reads the existing file first and takes
  the values an earlier install wrote as this run's defaults (a flag, an answer or an exported variable still
  wins); the lines it owns are updated in place, every other line stays, and the old file is kept as
  `brain-kit.env.bak.<epoch>`. Measured before: a re-run put `BRAIN_DIR` back to the default, and two lines
  added to the file were gone. A BM25-only install stays BM25-only on a re-run; `BRAIN_EMBED=1 ./setup.sh`
  switches it.
- **The context window comes from the model.** Every model except Haiku used to count as 1M, so on a 200k
  model the 50% and 65% lines could never fire (a 153k context printed "15% of 1000k"). The window is now
  200k, or 1M when a model id ending in `[1m]` is in `ANTHROPIC_MODEL` or a settings file's `model` key, or when
  a context above 200k has been seen; `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is clipped to it and
  `BRAIN_CTX_WINDOW` is taken as given. The installer suggests `auto` instead of 500000
  (`--context-window=<N|auto>`). A 1M session started with `--model <id>[1m]` on the command line is not
  visible to the hook until it passes 200k: set `BRAIN_CTX_WINDOW=1000000` for it.
- **The recall repeat filter is off by default** (`BRAIN_RECALL_REPEAT_FILTER=1` turns it on). The 1.1.x filter
  did not know about compaction: on the author's install a session that kept one id through 25 compactions
  lost notes the model no longer had (full recall blocks on prompts of 6+ words fell from 80% to 43%). When on,
  it now starts over at every compact boundary in the transcript (the prompt hook passes `transcript_path`),
  and it is always off without a session id - `brain-search` has none, and in 1.1.1 a repeated manual search
  printed hits once and then nothing, 5 times out of 5.
- **"No match" no longer means "not known".** On a real question with no hit, recall used to say "treat this
  as NOT KNOWN". A missing match is not a missing record - a project scope, a wording in another language or a
  note split into sections all lose it - so the line now says so and gives the `brain-search` command to run
  by the concrete name.
- **The focus hook's output stays within 8,500 characters, and a truncation warning is its first line.**
  Claude Code hands the model only a 2 KB preview of a hook output past about 10,000 characters; the old cap
  was 12,000 bytes and its warning was the last line (measured: a 12,432-character output, the warning at
  character 12,318; on the author's install 76 of 76 full showings over three days were cut). Tasks and git come
  first in the budget (1,500 characters), a cut focus ends with the path to Read, and a SUMMARY or NOW line
  longer than 1,500 characters gets a warning line. `BRAIN_FOCUS_MAX` is in characters now.
- **`postwrite-check.sh` reports and never deletes.** It removed every 0-byte `.md` in the whole vault on each
  write (a placeholder in another folder went in a test); it now reports only the note just written. Link
  targets come from one list of note names built once per call instead of one `find` per link (measured before:
  4.0 s per write at 1,000 notes, 19.7 s at 3,000, 45 s at 5,000; after: 57-62 ms at 1,000 notes, 97-112 ms at 3,000, 127-152 ms at 5,000; n=3 each, the hook timed on Ubuntu 24.04).
  `[[note#heading]]`, `[[folder/note]]` and `[[note.md]]` resolve to the note, and hidden folders are skipped.
- **The correction detector is quieter.** `" no "`, `"stop"` and `"i said"` left the pattern list: 3 of 3
  ordinary prompts set it off in a test, one of them as the hard "pattern analysis" line. That line no longer
  asks for confirmation, and a prompt that is the continuation line self-compact typed is not read as a
  correction.
- **After a compaction with self-compact installed, the pointer line no longer asks to confirm** - it tells the
  agent to carry on from the handoff record and the focus file. It also lists the memory files and CLAUDE.md
  files changed in the last 60 minutes, because after a compaction Claude Code can load an older copy of them
  (anthropics/claude-code#92949).
- **The write hook waits at most 3 s for the index lock**, not 30 (measured before: 29.1 s of waiting, then a
  skip); past that it starts the sweeper and says the write was deferred. The sweeper holds that lock only
  for its `update` step (about a second) and computes the vectors after releasing it, with a second lock so
  the timer and the hook never load two copies of the model (one note's round measured 12.1 s and 2.4 GB).
  The vector step is the new `brain_index.py embed`: a round budget (`BRAIN_EMBED_BUDGET`, 110 s, under the
  2-minute timer; not a number = 110 and a warning), a commit every 16 chunks. A manual
  `brain_index.py build|update --embed` still fills everything in one go.
- **Consolidation's headless call runs without tools.** The default is now `claude -p --tools ""
  --strict-mcp-config` with the prompt on stdin and the claude.ai connectors off: the prompt is built from
  notes other sessions wrote, and an instruction buried in one of them must not be able to run a command;
  on argv a 543,000-character prompt failed with "Argument list too long" on the author's install. A CLI named in
  `BRAIN_CONSOLIDATE_CMD` still gets the prompt as its last argument.

### Fixed
- **Every hook reads `brain-kit.env` with `set -a`,** so the settings in it reach the Python side:
  `BRAIN_INDEX=sqlite` never did, and recall re-scanned every file on every prompt (measured before: 5.8-6.8 s
  per prompt on 2,000 notes; after: median 254 ms, n=5, on the same 2,002-note vault). Recall's docs pass (`wiki_pull`) no longer runs a
  second BM25 + dense search when no docs root is configured or on disk.
- **The absence gate works on Ubuntu.** Its name filter used the interval `{3,}` in awk, which mawk (Ubuntu's
  and Debian's default awk) does not support: the name list came out empty and 6 of 6 test turns passed
  silently. Fenced code spanning several lines is dropped before the claim is looked for, a Read of a file
  whose path carries the name counts as a search, `\b` (which POSIX ERE does not define) is spelled out, and the block
  message gives `brain-search`'s full path - it is not on PATH (rc 127 in the test).
- **`time-inject.sh`** tried BSD `date -r` only: on Linux every prompt got a broken session line and an error
  on stderr. It now falls back to `date -d @epoch`, and a session older than 24 hours shows its start date.
- **`observe-mutations.sh` masks `Authorization: Bearer <token>`, `-p<password>` and `sshpass -p`**, which
  reached the observation file in a test, and uses no GNU-only sed flag.
- **The desk ledger reads `brain-kit.env`.** It runs from a timer with no shell to source the file, so a custom
  root or vault was invisible to it. Plain assignments and `NAME="${NAME:-value}"` lines are read, nothing in
  the file is executed, and an exported variable wins.
- **macOS.** There is no `setsid` there: the write hook started the sweeper with it, and the self-compact
  command in `docs/SELF_COMPACT_BLOCK.md` failed with "setsid: command not found". Both fall back to `nohup`,
  and on macOS the installer loads a launchd agent that runs the sweeper every 2 minutes (1.1.1 printed a cron
  line there, and without it new notes got no vectors). `postwrite-check.sh` no longer uses GNU `find -printf`.
- **Three traces of the author's own setup** left the shipped files: a pattern in `salience-inject.sh` and a
  local archive path and an internal skill name in the caveman skill.

### Documentation
- README: the disk figure is the measured one - about 13 GB (the venv 5.8 GB, 3.2 GB of it CUDA; the Hugging
  Face cache 4.3 GB; pip's cache 2.9 GB; 3.35 GB of memory at the peak of the install) - with the way to keep
  the 3.2 GB of `nvidia-*` and 0.9 GB of `triton` packages off a machine without an NVIDIA GPU (the CPU build
  of torch, installed into the venv first). Requirements name `python3-venv` and bash instead of "a POSIX
  shell"; `--minimal` is described as what it installs; every network call is listed (it said two - the
  model download and the update check - and left out pip, the desk ledger's `gh` calls and the consolidation
  path's `claude -p`); the clone line has the real address.
- `INTRO_PROMPT.md` has the model ask the installer's three questions itself and pass them as flags: a model
  runs the installer without a terminal, where the installer asks nothing.
- `setup.sh` copies `docs/` to `$BRAIN_ROOT/docs` and `scripts/update.sh` keeps it current; the context hook
  points at `$BRAIN_ROOT/docs/self-compact.md` instead of a path relative to a checkout.
- UPGRADE.md: "Coming from 1.1.1".

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
