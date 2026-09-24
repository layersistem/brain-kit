# brain-kit

A persistent memory + consolidation layer for Claude Code (and other agent CLIs).

Your agent forgets everything between sessions, and compaction eats the middle of the ones that
run long. brain-kit gives it a memory made of plain markdown notes you can read, edit and grep:
decisions, rejected options and lessons, stored in a vault on your own disk. On every prompt a
BM25 pass runs over that vault and injects the handful of notes closest to what you just asked,
so the session starts from what you already worked out instead of re-deriving it. Notes carry a
`weight:` tag and a date, so canon outranks routine and an old undated-importance note fades
instead of crowding out this week's decision.

Two more pieces close the loop. Before a compaction, a hook writes a deterministic snapshot of
the last messages to a drafts folder that is deliberately excluded from retrieval - if the
model-written summary loses something, the raw text is still there. And a consolidation pass
collects a window of decision records, finds the older notes each one might have superseded, and
produces a **proposal**: distil this into knowledge, mark that one superseded, these two
contradict each other. A human approves; nothing is applied on its own. All of it runs locally.
No API key, no cloud, nothing leaves the machine - BM25 retrieval is pure Python with no model at
all, and the semantic layer runs BGE-M3 on your CPU.

## Requirements

- Python >= 3.10 with its `venv` module (on Debian and Ubuntu that is the separate `python3-venv`
  package: `sudo apt install python3-venv`), `jq`, and bash - the hooks and scripts are bash scripts;
  macOS's own `/bin/bash` 3.2 is enough. macOS and Linux tested.
- **BGE-M3 (`BAAI/bge-m3`) is required for the full kit.** `setup.sh` installs
  `sentence-transformers` + `torch` into `<BRAIN_ROOT>/.venv` and the first embed run downloads
  the model (once, from Hugging Face; offline afterwards). It powers the embed hook, the
  duplicate check on write, `brain_search.py`, and the hybrid recall daemon
  (`docs/DENSE_RECALL.md`) - the configuration we measured best (BM25 hit@1 0.80 -> hybrid 0.87).
  **Disk: about 13 GB**, measured on a clean Ubuntu 24.04 install: the venv 5.8 GB (3.2 GB of it the
  CUDA libraries the default Linux torch wheel brings), the Hugging Face cache 4.3 GB, pip's download
  cache 2.9 GB. Memory peaked at 3.35 GB during that install; budget ~3 GB RAM if you run the daemon
  resident. On a Linux machine without an NVIDIA GPU, put the CPU build of torch into the venv before
  running `setup.sh` (it reuses an existing venv) and the 3.2 GB of `nvidia-*` packages and the 0.9 GB
  `triton` package are never downloaded:
  `python3 -m venv ~/brain/.venv && ~/brain/.venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cpu`
- `./setup.sh --no-embed` is the fallback for machines that cannot carry the model: BM25 recall,
  focus injection, compact snapshots and consolidation still work; embedding, dedup-on-write and
  dense recall stay off. It is a degraded mode, not the recommended one.
- Optional: Obsidian. The vault is plain markdown with `[[wikilinks]]`; graph view and backlinks
  make orphan notes and missing links visible at a glance.

## Quick start

```bash
git clone https://github.com/layersistem/brain-kit && cd brain-kit
./setup.sh                       # or: ./setup.sh --no-embed   (BM25 only, no model download)
BRAIN_ROOT=~/brain python3 ~/brain/scripts/brain_bm25.py "example decision" 3
```

Restart your agent session afterwards so the hooks load. `--minimal` wires 14 of the 18 hook entries:
everything except the vault hygiene check (`postwrite-check.sh`), the observation stream
(`observe-mutations.sh`) and the two Stop gates, and it skips the consolidation skill. The
`five-gates` skill installs in both profiles, caveman in either only when you choose it. Then run the dense-recall daemon as a service
(recommended, `docs/DENSE_RECALL.md`) - recall is hybrid the moment it is up, BM25-only until then.

## Model-first install

You do not have to run any of this yourself. Open Claude Code in the cloned folder and paste
[`INTRO_PROMPT.md`](INTRO_PROMPT.md) into it. It has two tracks - a fresh project and an
existing one with notes you already keep - and the model runs the installer, verifies the hooks
landed in `settings.json`, checks that recall answers a query, and reports back in five lines.

## What the installer asks, and what it installs on its own

Three features are opt-in and `setup.sh` asks before installing them. An empty answer means no (for the
window: auto, nothing written), and so does a non-interactive run (stdin not a terminal) without the
matching flag:

```
Context window for the warnings and auto-compact: 'auto' uses the model's own window, a number of tokens
narrows it (written to the project's .claude/settings.json) [auto]:
Install self-compact (requires tmux; the agent compacts itself at the hard threshold)? [y/N]
Install the caveman skill? The agent then answers in compressed prose (about 65-75% fewer output tokens)
in every session of every project - it is a user-level skill. [y/N]
```

The first, when you give a number, writes it into `<project>/.claude/settings.json` (`env`) as
`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, where both Claude Code and the context hook read it. `auto` writes
nothing: the context hook then uses the model's own window (200k, or 1M for a model id ending in
`[1m]`) and clips any configured window to it (1.2.0; 1.1.x suggested 500000, more than a 200k model's
whole window, so its warnings could never fire there). The
second makes the agent compact its own session at the hard threshold: it writes the tmux session name to
`<project>/.claude/self-compact-session`, appends a short block to the project's `CLAUDE.md`, and turns
the context hook's hard line into a "self-compact now" order (`docs/self-compact.md`). The project is
`--project=DIR`, else `CLAUDE_PROJECT_DIR`, else the directory you run from. For CI and scripts:
`--context-window=<N|auto>`, `--self-compact=<session|no>`, `--caveman=<yes|no>`, `--yes-defaults` (every
question takes its default, no prompt). `scripts/update.sh` never changes any of these choices.

Running `setup.sh` again (an upgrade, or a changed answer) takes its defaults from the existing
`<agent-config-dir>/brain-kit.env` and merges into it: the lines it owns are updated in place, every line
you added stays, and the previous file is kept as `brain-kit.env.bak.<epoch>` (1.2.0; before, the file was
rewritten and a custom `BRAIN_DIR` went back to the default). A BM25-only install stays BM25-only on a
re-run without `--no-embed`; `BRAIN_EMBED=1 ./setup.sh` switches it to the full install.

The third is a writing style, not a memory feature. `skills/caveman` makes the agent drop filler and
articles in chat while keeping every technical detail exact, and write deliverables (docs, mails, PR
bodies) as plain full sentences. It installs into `<agent-config-dir>/skills`, so once chosen it applies
to every project on the machine. Until 1.1.1 the installer copied it in without asking; if you installed
one of those releases and do not want it, delete `<agent-config-dir>/skills/caveman` - the installer never
removes a skill.

**Where things land.** The hooks, the `brain-kit.env` file, the skills and the operating-rules block in
`<agent-config-dir>/CLAUDE.md` are user-level: they apply to every project you open with that agent, not
only to the one you ran the installer from. Only the two project opt-ins above write into the project.
To keep recall, the focus line and the write hooks quiet in some directories, list them in
`BRAIN_ISOLATE_DIRS`.

Two things install on their own when the machine can carry them. The **index sweeper** timer
(`scripts/systemd/brain-index-sweep.*`, every 2 minutes) embeds what the write hook only chunked; on macOS
the installer loads a launchd agent that does the same (`~/Library/LaunchAgents/local.brain-kit.index-sweep.plist`),
without either it prints the cron line instead, and `--no-timers` skips the step. The **desk
ledger** (`scripts/desk_ledger.py`, hourly) exports your repos' issues and PRs into the vault so closed work
is found by name; it is installed only when `gh` is on PATH and you list repos (the prompt, or
`--desk-repos="owner/a owner/b"`), otherwise it is skipped without a word.

## Architecture

```
  your prompt
      |
      +--> [UserPromptSubmit] _focus_inject.sh ----> current focus file, verbatim
      +--> [UserPromptSubmit] _auto_retrieve.sh ---> brain_recall.py --> brain_recall_print.py --> top-k notes injected
                                                     |-- brain_bm25 (zero model, stdlib only; reads
                                                     |   .index/brain.db when BRAIN_INDEX=sqlite -
                                                     |   FTS5 narrows candidates, same BM25 formula
                                                     |   scores them - else re-scans the vault)
                                                     '-- brain_searchd daemon (warm BGE-M3, ~80 ms,
                                                         RRF-fused; recommended, run as a service;
                                                         absent -> plain BM25; docs/DENSE_RECALL.md)
      +--> [UserPromptSubmit] time-inject.sh -------> a clock: now (with weekday), session age,
                                                     minutes since your last prompt
      +--> [UserPromptSubmit] due-inject.sh --------> @due lines whose day has come (overdue, today,
                                                     tomorrow) + once a day the coming week
      +--> [UserPromptSubmit] context-inject.sh ----> how full the context is, delta since last prompt,
                                                     warning at 50% of the window, hard order at 65%
                                                     (self-compact when installed; Claude Code only)
  you write a note
      +--> [PostToolUse] brain-embed-after-write.sh --> brain_index.py update --> .index/brain.db
      |                                                 (chunks + BM25 tokens, ~1 s, hash-incremental)
      |                                                 '-- vectors: scripts/brain_index_sweep.sh, in the
      |                                                     background (hook-started + a 2-minute timer)
      +--> [PostToolUse] postwrite-check.sh ----------> ghost-link + orphan-note + empty-note check (the file just written)
  you mutate anything (write, edit, state-changing shell)
      +--> [PostToolUse] observe-mutations.sh --------> _drafts/observations_<instance>_<day>.md
                                                       (append-only trail, secrets masked, kept out
                                                        of retrieval; consolidation reads it and flags
                                                        work no decision record explains as [NO-DR])

  end of turn
      +--> [Stop] identical-answer-stop.sh ----------> blocks a byte-for-byte repeat of the previous answer
      +--> [Stop] unsearched-absence-stop.sh --------> blocks "no record of <name>" when <name> was never
                                                       searched in this turn (at most 2 blocks per turn)

  before compaction
      +--> [PreCompact] precompact-snapshot.sh ------> _drafts/compact_snapshot_<instance>.md
  after compaction
      +--> [SessionStart:compact] pointer ------------> "read the handoff note, then this snapshot"

  at session start
      +--> [SessionStart] update-notice.sh ----------> one line if a newer release is tagged
                                                       (once a day, version number only, installs
                                                        nothing - applying it is scripts/update.sh)

  by hand / nightly / on a timer
      brain-search          recall by hand: the same roots and the same block the prompt hook produces
      brain_search.py       BGE-M3 retrieve (+ optional reranker; measured worse
                            than plain cosine here) - one-off deep search, still local
      brain_consolidate.py  window of decisions -> proposal report -> human approves
      self-compact.sh       the agent's last command at the hard threshold: waits for the turn to end,
                            sends /compact, waits for the boundary, types the continuation line (opt-in)
      desk_ledger.py        hourly: the repos' issues + PRs -> knowledge/desk-ledger-*.md, so closed
                            work is found by name (opt-in, needs gh)
```

Vault layout (`$BRAIN_ROOT/vault/`):

```
decision/   DR-<date>-<slug>.md   the payload: decision, rejected path, reopen trigger
knowledge/  *.md                  distilled, durable know-how
memory/     *.md                  timeless canon: working style, preferences, authority
moc/        MOC-*.md              maps of content, the zoom-out view
focus/      _FOCUS_<instance>.txt current focus, injected verbatim every prompt
_drafts/                          snapshots and consolidation output - excluded from retrieval
```

The vault is plain markdown with `[[wikilinks]]`, so it opens as-is in Obsidian (graph view, backlinks,
search) - useful for reading and pruning by hand, but optional: nothing in brain-kit depends on it, and
`grep` or any editor works the same. `_drafts/` is pre-excluded from the Obsidian graph via the seeded
`.obsidian/app.json` - it holds working files, not notes, so it should not show up as orphans. If you
already keep an Obsidian vault, point `BRAIN_DIR` at it (see [`INTRO_PROMPT.md`](INTRO_PROMPT.md), track B).

## The index

BM25 recall's file-scan is fine for a few hundred notes and gets slow past a couple thousand,
since it re-reads and re-tokenizes every file on every query. `brain_index.py` builds and
maintains `<vault>/.index/brain.db` instead - one SQLite file holding a `files` table (sha-hashed,
so an unchanged note costs one hash comparison, not a re-scan), a `chunks` table (BM25 tokens, a
600-char excerpt, the BGE-M3 vector as a BLOB) and an FTS5 shadow table for fast candidate lookup,
so the same rows serve both the sparse and the dense engine. Setting `BRAIN_INDEX=sqlite` (the
default `setup.sh` writes) routes `brain_bm25.search()` through it; the write hook keeps it
current with an incremental `update` after every note change, and a missing or broken index falls
back to the plain file-scan on its own. Measured on a ~1,200-note vault: a query that took 1.1 s
scanning files takes 0.007 s through the index (about 150x), and the recall hook's end-to-end
time drops from 1.47 s to 0.22 s. Until 1.2.0 a kit install never took this path: the hooks read
`brain-kit.env` without exporting it, so `BRAIN_INDEX` did not reach Python and every prompt re-scanned
the vault (measured on a 2,000-note vault: 5.8-6.8 s per prompt, 0.24 s with the variable exported).
`brain_index.py build [--embed]` does a full rebuild; `stats`
prints row counts and file size.

## Measuring what it costs

Everything the kit injects is paid in context tokens, and the bill has two shapes: a fixed cost
per session (skill descriptions, the CLAUDE.md chain) and a cost per prompt (the focus file,
injected verbatim every time). `scripts/context_budget.sh [instance]` prints both, line by line
for the focus file, with warnings past the thresholds that hurt: a skill description over 60
words, a focus SUMMARY over 700 characters, a focus file over ~500 tokens per prompt. Run it after
any change to skills, CLAUDE.md or the focus file. The reason it exists: on 2026-09-09 a skill
cleanup cut the per-session cost by 90%, and the very next measurement showed the focus file
alone was costing ~1,200 tokens on every prompt - the larger lever, invisible until measured.

What the sessions actually spent is a second question, and `scripts/usage_report.py` answers it from
the transcripts the agent already writes: calls, context per call and token totals per project, for
today or any window you pass. Two traps it avoids, both of which inflated our own first numbers by
1.85x to 2.6x: one API response lands in the transcript as one line *per content block*, all of them
repeating the same `message.id` and the same `usage` (so it counts distinct ids, not lines), and
context per call is input + cache_read + cache_creation, not input alone. Use it to rank projects
against each other; it is not a billing statement.

## Prostheses: what each part stands in for

The model's weights are frozen and its context is a working memory that compaction empties.
Everything in this kit is a prosthesis for a faculty the vendor does not ship. The mapping is not
a metaphor we decorated afterwards; it is how the pieces were chosen, over about three months of
daily use, adding one part each time a specific kind of forgetting hurt.

| Human faculty | Brain region (rough) | brain-kit part | What it replaces |
|---|---|---|---|
| Working memory | prefrontal cortex | the context window (vendor) | nothing - but compaction is a lossy blackout, so `precompact-snapshot.sh` keeps the raw last messages |
| Episodic memory | hippocampus | `decision/` records | "what did we decide on Tuesday, and what did we reject" |
| Semantic memory | neocortex | `knowledge/` + `memory/` | durable know-how and timeless canon, distilled out of episodes |
| Procedural memory | basal ganglia | skills + hooks | reflexes that run without recall: retrieve, embed, snapshot, check |
| Attention / cue-driven recall | association cortex | `_auto_retrieve.sh` -> `brain_recall.py` (BM25, optionally fused with a warm BGE-M3 daemon) | the note you would have thought of, injected before you ask |
| Sense of time | suprachiasmatic nucleus + hippocampal time cells | `time-inject.sh` | the model has no clock: without it "yesterday", "an hour ago" and "how long was I away over that compaction" are guesses. Injected, not instructed - a "work out the time" instruction produces a guess |
| Prospective memory (time-based) | rostral prefrontal cortex | `@due YYYY-MM-DD[ HH:MM] text` lines in your focus or your own decision records, surfaced by `due-inject.sh` | "what did I promise to do on Monday at 11:30" - overdue, today and tomorrow on every prompt; the coming week once a day, on the first prompt, the way a person scans the week over the first coffee and then lets the far horizon go blurry |
| Ongoing-task memory | frontal lobe | `focus/` file, injected verbatim | "what was I in the middle of" |
| Interoception | insula (the body's own state: fatigue, fullness) | `context-inject.sh` - context tokens, % of window, delta per prompt, warning at 50% and a hard order at 65% | "how full am I, how fast am I filling, is the blackout near" - so the handoff note is written before compaction, not reconstructed after. With `scripts/self-compact.sh` installed the hard order is "compact yourself": the agent writes the note and starts the script, which sends `/compact` from outside and types the continuation line (`docs/self-compact.md`). Claude Code only: it reads the transcript's `usage` block; the number matches the app's Context window panel to the token |
| Re-orientation after a blackout | waking up: reticular activating system | `sessionstart-compact-pointer.sh` + the handoff note it points at | "where am I, what was I doing" after a compaction, without a search |
| Knowing which of you is speaking | proprioception | `session-instance-bind.sh` + `_instance.sh` (identity bound to the session's process, not its folder) | two instances in one folder keep their own names; see `docs/MULTI_INSTANCE.md` §6 |
| Salience / emotional tagging | amygdala | `weight:` (canon > lesson > approval > routine) in the ranking, and the reflex that sets it: `salience-inject.sh` spots a correction in your prompt ("wrong", "undo", "why did you"; `BRAIN_SALIENCE_RX` for your language) and tells the model to tag this turn's record `weight: lesson`; `salience-postwrite.sh` warns if a decision record is then written without a weight | canon outranks routine at equal relevance; and what hurt gets encoded as a lesson without anyone remembering to do it |
| Forgetting | synaptic decay | age decay + `superseded` penalty | an old, undated-importance note fades instead of crowding out this week's |
| Sleep consolidation | hippocampus -> cortex replay | `brain_consolidate.py` proposal | distil episodes into knowledge, mark superseded, surface contradictions - a human approves |
| Belief tracking | orbitofrontal / anterior cingulate | the optional belief ledger, `docs/BELIEFS.md` | one falsifiable claim per belief, with its own status, separate from the episodic record of how you got there - so "is this still true" does not require re-reading history |
| Implicit episodic trace | hippocampal indexing of what you did, not what you decided | `observe-mutations.sh` stream | every mutation leaves a one-line trace; consolidation matches traces to decisions and flags the unexplained ones |
| Metacognition | anterior cingulate | confidence tags on every recalled note (STRONG = both engines agreed or dense cosine over the floor, FAIR = one engine) + an explicit "no note matched this sentence - no match is not the same as no record; search by the concrete name" line when a real question finds nothing; discipline docs, `docs/DISCIPLINE.md` | knowing how much to trust what memory just handed you, knowing that you don't know (say so, label the guess a hypothesis) - and when the tool is wrong, when to stop, when to ask |
| Source monitoring ("did I actually look, or do I just not remember?") | prefrontal reality-monitoring | `unsearched-absence-stop.sh` + `scripts/brain-search` | a person who says "there is no record of X" has usually checked; a model says it from the absence of X in its context, which after a compaction or a long turn means nothing. The gate blocks an absence claim about a named thing when nothing in the turn searched for that name, and names the two searches to run. `desk_ledger.py` feeds it: work you closed on GitHub last month is in the vault under its exact title, so the search finds it |
| Perseveration guard | basal ganglia loop that normally lets a stuck motor pattern break | `identical-answer-stop.sh` | a person snaps out of repeating themselves when the response clearly isn't landing; a model can keep emitting the same templated answer turn after turn, even under a one-character correction buried inside it. This hook blocks a byte-for-byte repeat of the previous turn's answer and forces a re-read, making that failure mode mechanically impossible instead of relying on the model to notice it |

Not covered, on purpose: continual learning of the weights themselves. This kit does not train
anything; it gives a frozen model a memory it can read.

## What gets injected, and when

| Moment | Hook | What lands in context |
|---|---|---|
| every prompt | `_focus_inject.sh` | your focus file for this instance, verbatim, with the optional tasks and git lines - all of it within 8,500 characters (`BRAIN_FOCUS_MAX`). A longer focus is cut at a line boundary, and the first line of the output then says so and gives the path to Read; a SUMMARY or NOW line longer than 1,500 characters gets a warning line of its own |
| every prompt | `_auto_retrieve.sh` (renderer: `scripts/brain_recall_print.py` - the hook itself holds no Python, so a quoting slip can never block every session's prompts again) | top-k matching notes with a confidence tag each (STRONG/FAIR) and a count in the header; with `BRAIN_WIKI_DIR` set, docs hits in a SOURCE block with a `code:` bridge line and notes under RECORD (the source for decisions and history; not opened = no "nothing written" verdict); STRONG notes carry the "what" line + excerpt, FAIR notes only title + address (low confidence gets less room); on a real question (>= 6 words) with no match, one line saying that no match is not the same as no record, with the `brain-search` command to run by name - not silence; a note saying the dense engine did not answer this turn, if none of the results came from it. Nothing at all on a prompt of three words or fewer (`BRAIN_RECALL_MIN_WORDS`). With `BRAIN_RECALL_REPEAT_FILTER=1` (off by default since 1.2.0) a note already shown since the last compaction is dropped when it is FAIR and unrelated to the prompt's words, or is a handover note nobody has opened |
| every prompt | `beliefs_recall.py` (called from `_auto_retrieve.sh`) | active beliefs tied to whatever notes recall just surfaced, plus a pointer to anything on the same topic that has since evolved; silent until you opt into the belief layer (`docs/BELIEFS.md`) |
| every prompt | `time-inject.sh` | a clock: local date+weekday+time, session age, minutes since the last prompt |
| every prompt | `due-inject.sh` | what is due: `@due YYYY-MM-DD[ HH:MM] text` lines from your focus + your own decision records - overdue (days late), today (NOW once the hour passes), tomorrow; on the first prompt of the day also the coming week (2-7 days); silent otherwise |
| every prompt | `salience-inject.sh` | only when your prompt carries a correction signal: one line - "tag this turn's record `weight: lesson`"; a hard "run a pattern analysis" line when several corrections land inside 90 minutes (a burst, not the day's total - `BRAIN_SALIENCE_BURST` / `_WINDOW`); negated phrases ("nothing wrong") do not count |
| after a note write | `salience-postwrite.sh` | only when a decision record is written weight-less after a correction in this session |
| every prompt | `context-inject.sh` | context ~Nk (P% of window), delta since last prompt; WARNING past 50% ("compact at the next clean boundary, prepare the handoff note"), HARD past 65% ("self-compact now" when `scripts/self-compact.sh` is installed, else "write the handoff note, let it compact"). On the first turn after a compaction: one line saying there is no measurement yet, and no order - the only number available then is the pre-compaction one. `BRAIN_CTX_WINDOW` / `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `BRAIN_CTX_WARN`, `BRAIN_CTX_HARD`, `<project>/.claude/ctx-thresholds`. **Claude Code only** - needs the hook's `transcript_path`; silent elsewhere |
| after a note write | `brain-embed-after-write.sh` | one line confirming the index update (or that it failed) plus "vectors: background sweeper" when a chunk was left for `scripts/brain_index_sweep.sh` to embed. The hook itself no longer loads the model (it cost 14 s per edit on the tool path); dense recall sees the note about 15 s later, BM25 at once. It waits at most 3 s for the index lock; past that it starts the sweeper and says the write was deferred |
| after a note is read | `recall-usage-count.sh` | nothing - it counts. Opening a vault or memory note adds one to `<vault>/.index/recall_counts.json`, which BM25 reads as a small capped boost, so what gets *read* rises and what merely gets shown does not |
| after a note write | `postwrite-check.sh` | only when the note you just wrote links to a missing note, has no links at all (an orphan; `BRAIN_ORPHAN_EXEMPT` dirs are fine), or is empty - reported, never deleted. Code blocks and backticks are not scanned; `[[note#heading]]` and `[[folder/note]]` resolve to the note; hidden folders are skipped; the vault-wide ghost count is shown as background only |
| before compaction | `precompact-snapshot.sh` | nothing - it writes a file |
| at session start (startup, resume, compact, clear) and first on every prompt | `session-instance-bind.sh` | one line, only when the identity changes: which instance this session is bound to (on a prompt it is a silent self-check unless the binding was lost) |
| after compaction | `sessionstart-compact-pointer.sh` | addresses: the handoff note and the snapshot, plus the memory and CLAUDE.md files changed in the last 60 minutes (after a compaction Claude Code can load an older copy of them). With self-compact installed it does not ask to confirm before continuing |
| at session start (startup, resume) | `update-notice.sh` | only when the remote has a newer `vX.Y.Z` tag than your `VERSION`: one line naming that version and how to apply it. At most once a day, 2 s budget, nothing but the version number crosses over, installs nothing (`BRAIN_UPDATE_CHECK=0` disables) |
| end of turn | `identical-answer-stop.sh` | only when this answer is byte-for-byte identical to the previous turn's: blocks and forces a re-read of the incoming message (`full` profile only, `BRAIN_PERSEVERATION_GUARD=0` disables) |
| end of turn | `unsearched-absence-stop.sh` | only when the answer claims something named is missing, unknown or waited for ("no record of `foo-bar-rule`", "I would need the device for `x-y-z`") and no Bash/Grep/Glob call in the turn searched for that name (`brain-search`, `grep`, `rg`, `gh ... --search`) and no Read opened a file whose path carries it: blocks once, names the searches to run; a second unsearched claim in the same turn blocks again, the third passes with a "brake" line in `brain-kit-state/absence-gate.log`. Names are kebab-case with two or more hyphens. English phrases built in; `<project>/.claude/absence-patterns` or `BRAIN_ABSENCE_RX_FILE` replaces them (a Turkish set ships in `patterns/`). `full` profile only, `BRAIN_ABSENCE_GATE=0` disables |

Recall stays quiet when it has nothing good: below a relevance floor it returns no block at all,
because five irrelevant notes cost more than none.

## Configuration

Everything is environment variables; `setup.sh` writes the few that matter into
`<agent-config-dir>/brain-kit.env`, which every hook sources. An exported variable always wins.

| Variable | Default | What it does |
|---|---|---|
| `BRAIN_ROOT` | `~/brain` | install root: vault, scripts, hooks, venv |
| `BRAIN_DIR` | `$BRAIN_ROOT/vault` | the vault itself - point it at notes you already have |
| `BRAIN_INSTANCE` | `main` | this session's name (else `.brain-instance`) |
| `BRAIN_TITLE_MAP` | empty | `web|frontend=web;api=api` - map a client-recorded session title (`agent-name` / `custom-title` in the transcript) to an instance; consulted after the bound session and the ticket, before the folder walk-up (`docs/MULTI_INSTANCE.md` §6) |
| `BRAIN_MEMORY` / `BRAIN_MEMORY2` | `$BRAIN_ROOT/memory`, none | extra roots indexed as timeless memory |
| `BRAIN_WIKI_DIR` | none | optional shared docs root (a product wiki, a repo's docs), read-only, indexed alongside - BM25 and dense; recall prints the real file path so the model can Read it. With a docs root set, recall output follows a trust order: docs hits in a SOURCE block (with a `code:` line of file paths the doc mentions), notes in a RECORD block - the source for decisions and history, to be opened before any "nothing is written" verdict; how the system behaves is still checked against the code |
| `BRAIN_RECALL_WIKI_PULL` | `1` | when the fused top-k has no docs hit, append the best docs hit anyway (flagged as low score) so the map is on screen before the model judges from a note; `0` disables |
| `BRAIN_RECALL_WIKI_PULL_RANK` | `10` | how far down either engine's ranking the docs-pull may reach; beyond it nothing is pulled and recall says "no match" instead of showing an unrelated doc |
| `BRAIN_WIKI_SCOPE_RX` | empty | regex on the session's project slug; set it and only matching sessions see the docs root (others keep vault + memory) - applied by the file scan, the SQLite path and the dense daemon alike |
| `BRAIN_WIKI_DIRS` / `BRAIN_WIKI_SCOPE_RXS` | empty | further docs roots and their scope regexes, two `;`-separated parallel lists (`;` because a scope is a regex, where `\|` is alternation): root N is visible only to sessions whose slug matches regex N, an empty regex = every session. Roots are tagged `wiki`, `wiki2`, `wiki3`, ... in the index and in recall output, so one machine can carry several products' docs and each session sees only its own (`scripts/brain_wiki.py`) |
| `BRAIN_WIKI_EMBED` | `1` | `0` keeps the docs root out of the encoder (BM25 only) - for a very large tree |
| `BRAIN_ORPHAN_EXEMPT` / `BRAIN_WRITING_RULE` | `_drafts _archive refs focus`, empty | dirs where linkless files are fine by design; an optional rule name quoted in the orphan message |
| `BRAIN_SALIENCE_BURST` / `_WINDOW` / `_NEG_RX` | `3`, `5400`, built-in | hard warning after N corrections inside the window (seconds); negation phrases that cancel a match |
| `BRAIN_RECALL_K` | `5` | how many notes recall injects |
| `BRAIN_RECALL_MIN_WORDS` / `BRAIN_RECALL_FORCE` | `4` / `0` | prompts shorter than N words get no recall block at all ("go on", "yes do it": measured 88 such blocks, none of their notes ever opened); `BRAIN_RECALL_FORCE=1` exempts a deliberate manual lookup |
| `BRAIN_RECALL_REPEAT_FILTER` | `0` | `1` turns on the repeat filter: within a session, drop a note already shown since the last compaction when it is only FAIR and shares no word with the prompt, or when it is a handover-style note (hub, handoff, closing, compact) that has never been opened. First showing is never filtered, shared docs are never filtered, a fully filtered turn prints nothing rather than claiming no match, and a call without a session id (`brain-search`) is never filtered. Off by default since 1.2.0: the 1.1.x filter did not know about compaction and dropped notes the model no longer had in context |
| `BRAIN_RRF_RECENCY` | `0` | freshness bonus on the fused score (<= 1 day x1.10, 2-3 days x1.03, memory exempt). Off because it measured worse: hit@1 0.633 -> 0.533, MRR 0.739 -> 0.689 on a 30-query gold set. Kept live so you can test it against your own set |
| `BRAIN_STOPWORDS` | empty | extra stopwords (also `<root>/.brain-stopwords`) |
| `BRAIN_INDEX` | `sqlite` | BM25 reads `.index/brain.db` instead of scanning files; unset or a broken index falls back on its own |
| `BRAIN_EMBED` | `1` | `0` (set by `--no-embed`) keeps every encoder off: the write hook still updates the BM25 side, the sweeper exits at once |
| `BRAIN_EMBED_BUDGET` | `110` | seconds one sweeper round may spend encoding (the timer fires every 120 s); the rest waits for the next round, and every batch of 16 is committed as it is done. Not a number = 110 and a warning in the sweeper log. A manual `brain_index.py build --embed` or `update --embed` has no budget |
| `BRAIN_FOCUS_MAX` / `BRAIN_FOCUS_LINE_MAX` | `8500` / `1500` | the focus hook's whole output in characters (Claude Code shows the model only a 2 KB preview of a hook output past about 10,000 characters), and the longest SUMMARY or NOW line before a warning (also where one line is clipped when the focus is cut) |
| `BRAIN_EMBED_SYNC` / `BRAIN_SWEEP_THREADS` | `0` / `4` | `BRAIN_EMBED_SYNC=1` makes the write hook embed inline again (the pre-1.1.1 behaviour: 14 s per edit on the tool path, for a machine with no timer). The thread count caps torch/BLAS in the sweeper: every core spinning measured slower than 16 threads on a 24-core box, and the sweeper shares the machine with the sessions |
| `BRAIN_RECALL_REMOTE` | `0` | `1` sends the usage counter's increment to the dense daemon (`GET /count` on `BRAIN_SEARCHD_URL`) instead of writing `recall_counts.json` - for a second machine that reads the vault over a network share, so the file has one writer |
| `BRAIN_EMBED_MODEL` / `BRAIN_RERANK_MODEL` | BGE-M3 / bge-reranker-v2-m3 | local model overrides |
| `BRAIN_SEARCHD_URL` / `_TIMEOUT` / `_PORT` | `127.0.0.1:8799`, `0.8`, `8799` | dense-recall daemon (recommended, `docs/DENSE_RECALL.md`); absent = BM25 only. Every call is logged to `<agent-config-dir>/brain-kit-state/dense_calls.log` (ok/miss, ms) so a silent fallback stays measurable |
| `BRAIN_DENSE_MIN` / `BRAIN_DENSE_JOIN` | `0.62` / `0.55` | dense cosine gates: answer-alone / enter-fusion |
| `BRAIN_DENSE_JOIN_ROOTS` | empty | per-root fusion gate, `wiki=0.48,wiki2=0.50`; a docs root whose gold sits lower than the vault's keeps its dense hits in the fusion |
| `BRAIN_EMB_MAX_TOKENS` / `BRAIN_Q_MAX_CHARS` / `BRAIN_DENSE_Q_MAX` | `192` / `1500` / `1500` | query length caps on the daemon (tokens, characters) and on the client side (characters). CPU encode time is linear in query length, so an uncapped paste of 2000 words took 30 s, lost its own dense half and blocked every other session behind the single-threaded daemon; capped, every length answers in under 0.8 s with no change to gold-set scores. The daemon reads `BRAIN_EMB_MAX_TOKENS` at startup |
| `BRAIN_PROJECT_NAME` / `_VOCAB` / `BRAIN_CWD_MARKERS` | empty | project scope filter (off by default) |
| `BRAIN_FOCUS_DIRS` / `BRAIN_ISOLATE_DIRS` | empty | directory globs where hooks speak, or stay silent |
| `BRAIN_CONSOLIDATE_CMD` | `claude -p --tools "" --strict-mcp-config` (prompt on stdin) | CLI used by the optional `--llm` consolidation path; a CLI named here gets the prompt as its last argument |
| `BRAIN_PERSEVERATION_GUARD` | `1` | `0` disables `identical-answer-stop.sh` (`full` profile only) |
| `HOOK_DRY_RUN` | empty | set to anything and the three gates that can block (`identical-answer-stop.sh`, `unsearched-absence-stop.sh`, `postwrite-check.sh`) run their full logic but report instead of blocking: `DRY-RUN [hook] would have blocked: <reason>` on stderr, one line in `<agent-config-dir>/brain-kit-state/hook-dryrun.log` (mode 600), exit 0. Test a gate's negative case with `HOOK_DRY_RUN=1 bash hooks/<gate>.sh < payload.json`; a gate that has never shown red is an untested claim |
| `BRAIN_CTX_WINDOW` / `BRAIN_CTX_WARN` / `BRAIN_CTX_HARD` | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` if set (the project's own compaction ceiling, from the environment or `<project>/.claude/settings.json`) clipped to the model's window, else the model's window: 200k, or 1M when a model id ending in `[1m]` is in `ANTHROPIC_MODEL` or the settings' `model` key, or a context above 200k has been seen (a `--model ...[1m]` flag on the command line is not visible to the hook: set `BRAIN_CTX_WINDOW=1000000` then) / 50% of the window / 65% of the window | context-inject thresholds. Per project, `<project>/.claude/ctx-thresholds` sets them without a restart - `WARN=120000` and `HARD=160k`, one per line, plain tokens or a `k` suffix; a five-file repo and a monorepo do not deserve the same threshold. An exported variable still wins. Until 1.1.1 the single warning sat at 80% and `HARD` had no default; on a narrowed window that warning came one tool result before auto-compaction |
| `BRAIN_SELF_COMPACT` | `0` (`setup.sh` writes `1` when you opt in) | `0` keeps the context hook's older hard-threshold wording even when `scripts/self-compact.sh` is executable. The opt-in also writes the tmux session name to `<project>/.claude/self-compact-session` (`SELF_COMPACT_TMUX_SESSION` overrides it) and appends `docs/SELF_COMPACT_BLOCK.md` to the project's `CLAUDE.md` |
| `BRAIN_ABSENCE_GATE` / `BRAIN_ABSENCE_MAX_BLOCKS` / `BRAIN_ABSENCE_RX_FILE` | `1` / `2` / `<project>/.claude/absence-patterns` | the unsearched-absence gate: off switch, blocks per turn before the brake, and the claim-phrase file (one extended regex per line, replaces the built-in English list; `patterns/absence-claims.en.txt` is that list, `patterns/absence-claims.tr.txt` a Turkish one) |
| `BRAIN_DESK_REPOS` / `BRAIN_DESK_AUTHORS` | empty / empty | the desk ledger's repos (`owner/name`, space or comma separated; else `<BRAIN_ROOT>/desk-ledger.repos`, one per line, written by `setup.sh --desk-repos=`) and an optional author filter (logins; a bot's `app/` prefix and `[bot]` suffix are ignored). Nothing listed = the ledger does nothing |
| `BRAIN_UPDATE_CHECK` / `BRAIN_UPDATE_REMOTE` / `BRAIN_UPDATE_TIMEOUT` | `1` / the origin of the checkout `setup.sh` ran from, in its https form / `2` | the session-start update notice: `0` turns it off for good, the remote is where tag names are read from, the timeout bounds the single `git ls-remote` call |

## Staying up to date

An installed kit knows its own version (`VERSION`, written by `setup.sh`) and releases are git tags.
At session start `hooks/update-notice.sh` compares the two and, at most once a day, says one line if
the remote has a newer `vX.Y.Z`:

```
brain-kit 1.1.0 is available (installed: 1.0.0). Nothing was downloaded and nothing changed.
```

What is checked: `git ls-remote --tags <remote>`, with a 2 s budget. What is sent: nothing - no
identity, no vault, no usage, and the call needs no account or key. What enters your context: a
version number and that sentence. Tag names are matched whole-line against `^v[0-9]+.[0-9]+.[0-9]+$`,
so a tag carrying free text cannot put words into your session. No network, a slow remote or no tags
at all means no output at all, and the check is skipped for the rest of the day either way.

Applying it is a separate, deliberate step - a hook that installed remote code by itself would be a
supply-chain hole:

```bash
bash "$BRAIN_ROOT/scripts/update.sh"     # --dry-run to look first, --to v1.0.0 to pin a release
```

It moves to the tag (not to the tip of the branch), prints that release's CHANGELOG section and the
exact file list first, asks before writing, and copies anything you edited by hand into
`$BRAIN_ROOT/backups/<stamp>/` before replacing it. Your vault, your `settings.json` and your skills
are never touched; a release that adds a new hook needs `./setup.sh` re-run to wire it.
[`UPGRADE.md`](UPGRADE.md) is the same procedure written for the model that will carry it out. Turn
the whole thing off with `BRAIN_UPDATE_CHECK=0` in `<agent-config-dir>/brain-kit.env`.

## What this is not

- **Not an enforcement layer.** Nothing here gates a commit or refuses an action. Three hooks push
  back, all narrowly: the vault hygiene check (broken links, empty notes), the perseveration
  guard (`identical-answer-stop.sh`), which blocks only a byte-for-byte repeat of the previous
  turn's answer, and the unsearched-absence gate (`unsearched-absence-stop.sh`), which blocks a
  "no record of X" claim only when X was never searched in that turn, and at most twice per turn.
- **Not model gating.** brain-kit never inspects or restricts which model you are running.
- **Not a rulebook.** The habits that make this work - decision records, the "when to look"
  line, sparing weight tags, propose-then-approve consolidation - live in
  [`docs/DISCIPLINE.md`](docs/DISCIPLINE.md) as advice. Take what fits.
- **Not a hosted service.** No account, no telemetry. Every network call the kit makes: `setup.sh`
  installs the Python packages from PyPI and the first embed run downloads BGE-M3 from Hugging Face
  (once; `--no-embed` skips both); the optional update check - `git ls-remote --tags` against the repo
  you cloned, at most once a day, sending nothing, off with `BRAIN_UPDATE_CHECK=0` - and
  `scripts/update.sh`, which fetches tags only when you run it; the desk ledger's `gh` calls to GitHub,
  only when you listed repos; and the optional `--llm` consolidation path, which runs `claude -p` and so
  sends its prompt - built from your decision records and notes - to the model provider your Claude Code
  uses. The recall daemon listens on 127.0.0.1 only; nothing else leaves the machine.

## Turkish-aware stemming

Retrieval is bilingual by design. `brain_stem.py` strips Turkish agglutinative suffixes before
scoring (`ciroyu` -> `ciro`), so a query written with case and possessive endings still matches
the note that uses the bare root - which plain BM25 would miss entirely. Tokens are de-accented
first, and both English and Turkish stopwords are filtered. The stemmer only fires on tokens
longer than four characters and always leaves a root of at least three, so ordinary English
words pass through untouched. If you work in a third language, add its stopwords via
`BRAIN_STOPWORDS` - the rest already works, since BM25 does not care what language a token is.

## License

MIT. See [LICENSE](LICENSE).

---

Built by Burak Tuvay and Fable (Claude Fable 5) — a partnership, not a tool.
