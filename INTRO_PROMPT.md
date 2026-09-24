# INTRO_PROMPT - paste this into a fresh agent session

You are installing **brain-kit**: a persistent memory layer that survives compaction and gives
this session access to what previous sessions decided. Follow this file top to bottom, run the
commands yourself, verify the results, and finish with a five-line report.

Two engines, neither of which calls an API:

- **Recall** - `brain_recall.py`: BM25 (pure stdlib; reads a prebuilt SQLite index when
  `BRAIN_INDEX=sqlite`, else rescans the vault) fused with dense BGE-M3 hits from the
  `brain_searchd` daemon (recommended, run as a service - docs/DENSE_RECALL.md); runs on every
  prompt through a hook. Without the daemon it is plain BM25.
- **Index/Embed** - `brain_index.py`, backed by `brain_embed.py`'s BGE-M3 model (local CPU), runs
  whenever a note is written and keeps `.index/brain.db` current for both engines.

Nothing leaves this machine. **BGE-M3 is a requirement of the full kit** (the model is downloaded
once by the first embed run; with torch and the caches the full install takes about 13 GB of disk);
`--no-embed` is a degraded BM25-only mode for machines that cannot carry it - see README
"Requirements".

Once installed, a few short lines land at the top of every prompt. Nothing to set up - just know
what they mean (full table: README "What gets injected, and when"):

- **clock** (`time-inject.sh`) - date, weekday, time, session age. Write absolute dates from it;
  "yesterday" and "an hour ago" are guesses without it.
- **DUE** (`due-inject.sh`) - `@due YYYY-MM-DD[ HH:MM] text` lines from your focus file or your own
  decision records: overdue, today, tomorrow; the coming week once a day. Put promises there; when
  done, change the line to `@due✓`.
- **context** (`context-inject.sh`, Claude Code only) - how full the window is. WARNING (50%):
  compact at the next clean boundary, prepare the handoff record now. HARD (65%): compact now - and
  when self-compact is installed, "self-compact now": write the handoff record and the focus summary,
  start `scripts/self-compact.sh` as the LAST command of the turn, call nothing else, end the turn
  (`docs/self-compact.md`). The first turn after a compaction prints "no measurement yet" and no order.
- **absence gate** (`unsearched-absence-stop.sh`, end of turn) - if your answer says a named thing has
  no record, is unknown or is being waited for, and you never searched for that name this turn, the
  turn is blocked with the two searches to run: `brain-search "<name>"` and `gh issue list --search`.
  Search by the name you resolved during the work, not by the words of the prompt.
- **AUTO-RECALL** - notes closest to your prompt, tagged STRONG (both engines agree) or FAIR
  (title only). "no note matched this sentence" is not proof that nothing is recorded: search by the
  concrete name with `brain-search` first; if that finds nothing either, say you don't know - don't
  invent.
- **SALIENCE** (`salience-inject.sh`) - fires only when the user corrects you; tag this turn's
  decision record `weight: lesson`.
- **update notice** (`update-notice.sh`) - at session start, at most once a day: one line if a newer
  release is tagged. It downloads and changes nothing. Applying it is a separate step the user has to
  ask for - `scripts/update.sh`, procedure in [`UPGRADE.md`](UPGRADE.md).

Pick your track:

- **A** - fresh project, no notes yet.
- **B** - existing project, or markdown notes you already keep.

---

## A. Fresh project

### A1. Install

Before you run it, ask the user the installer's three questions yourself - you run it without a
terminal, so the installer asks nothing and an absent flag takes the default:

1. Context window: `auto` (the default: the hooks use the model's own window) or a number of tokens
   to narrow it -> `--context-window=<N|auto>`.
2. Self-compact (needs tmux; the agent compacts itself at the hard threshold): a tmux session name,
   or no (the default) -> `--self-compact=<tmux session|no>`.
3. The caveman skill (compressed chat replies in every session of every project): yes or no (the
   default) -> `--caveman=<yes|no>`.

```bash
cd <the brain-kit checkout>
./setup.sh --project=<the user's project dir> --context-window=<N|auto> --self-compact=<session|no> --caveman=<yes|no>
# add --no-embed to skip torch and the model download
```

The installer prints eight steps. Read them. If a step fails, report the exact error line and
stop - do not continue on a broken install.

### A2. Verify the install (do not skip)

```bash
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
python3 -c "import json;h=json.load(open('${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json'))['hooks'];print({k:[c['command'] for g in v for c in g['hooks']] for k,v in h.items()})"
python3 "$BRAIN_ROOT/scripts/brain_bm25.py" "example decision" 3
```

Expect hook entries for `UserPromptSubmit`, `PostToolUse`, `PreCompact`, `SessionStart` and `Stop`, and
JSON from the second command. `[]` means the vault is empty, which on a truly fresh install is
possible - the seeded example decision record should make it non-empty.

### A3. Set the focus and write the first decision record

Ask the user what they are working on. Then:

1. Rewrite `$BRAIN_ROOT/vault/focus/_FOCUS_main.txt` - first line `SUMMARY: <one line>`, then
   what is happening now, next, and what is waiting. Keep the whole file short: it is injected
   verbatim on every prompt. SUMMARY under ~700 characters, the file under ~500 tokens; history
   belongs in decision records, not here. `scripts/context_budget.sh` measures it.
2. Write `$BRAIN_ROOT/vault/decision/DR-<today>-<slug>.md` for the first real decision of this
   session, using the seeded example as the shape: frontmatter (`instance`, `date`, `topic`,
   `status`, `weight`), a `> **When to look:**` line, then DECISION / ALTERNATIVES / RATIONALE /
   REOPEN. If there is no decision yet, say so and skip - do not invent one.

### A4. Prove recall works

Tell the user: *"send me any message mentioning `<a distinctive word from that record>`"*. On
that next message an AUTO-RECALL block appears at the top of your context listing the note. If
it does not:

- the session started before the hooks were installed -> restart it;
- `settings.json` has no `_auto_retrieve.sh` entry -> re-run `setup.sh`;
- the query shares no rare words with the note -> that is the relevance gate doing its job, try
  a more specific word.

### A5. Report (five lines)

Where the brain is installed, how many hooks are wired, whether recall answered, which files you
created, and what the user should do next (keep the focus file current; write a decision record
at the moment of each decision).

---

## B. Existing project, or notes you already keep

### B1. Install, then decide where the vault points

```bash
cd <the brain-kit checkout>
./setup.sh --project=<the user's project dir> --context-window=<N|auto> --self-compact=<session|no> --caveman=<yes|no>
```

Ask the user the three questions from A1 first and pass the answers as those flags. Then choose one
of two shapes and tell the user which you picked:

- **Point the vault at the existing notes.** Best when there is already a notes folder or an
  Obsidian vault. Set `BRAIN_DIR` to it in `<agent-config-dir>/brain-kit.env` (a later `setup.sh`
  run keeps it), then create the
  subfolders brain-kit expects inside it: `decision/ knowledge/ memory/ moc/ focus/ _drafts/`.
  Existing files stay where they are - retrieval walks the whole tree.
- **Keep the new vault and link the old notes in.** Best when the existing notes belong to
  something else (a repo wiki, product docs). Leave `BRAIN_DIR` alone and set `BRAIN_WIKI_DIR`
  to the other tree; it gets indexed read-only alongside the vault. Several doc roots, each scoped to
  the sessions that need it: `BRAIN_WIKI_DIRS` and `BRAIN_WIKI_SCOPE_RXS`, `;`-separated (README
  "Configuration").

Check what you are about to index first: `find <notes dir> -name '*.md' | wc -l`. Thousands of
files are fine for BM25 but make the first embedding pass slow - tell the user the number.

### B2. Backfill frontmatter where it is cheap

Existing notes work as-is. Two additions raise recall quality a lot, so do them for the notes
that matter, not for all of them:

- `topic:` in the frontmatter - recall injects it as the "what" line.
- `date:` on anything time-bound - it drives the recency boost and the age decay.

Do not rewrite note bodies. This is a memory install, not a documentation refactor.

### B3. Build the index and test both paths

```bash
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
"$BRAIN_ROOT/.venv/bin/python" "$BRAIN_ROOT/scripts/brain_index.py" build --embed   # drop --embed if --no-embed
BRAIN_INDEX=sqlite python3 "$BRAIN_ROOT/scripts/brain_bm25.py" "<a phrase you know is in the notes>" 5
"$BRAIN_ROOT/.venv/bin/python" "$BRAIN_ROOT/scripts/brain_search.py" "<the same idea, other words>" -k 5
```

BM25 should return the note you expected. If it returns `[]` on a phrase you know exists, verify
the instrument before blaming the corpus: check that the file is inside `BRAIN_DIR`, that it is
not under `_drafts/` or `_archive/`, and that your query shares more than one rare word with it.

### B4. First consolidation run

```bash
python3 "$BRAIN_ROOT/scripts/brain_consolidate.py" --since <a date> --until <today>
```

That writes a prompt file into `vault/_drafts/`. Hand it to a subagent (use the strongest model
you have available - this is a judgement task), have it write the four-section report next to the
prompt, then gate it:

```bash
python3 "$BRAIN_ROOT/scripts/brain_consolidate.py" --verify <report path>
```

Show the report to the user. Apply only what they approve. If the window contains no decision
records yet, the script says so - that is expected on an install day.

### B5. Report (five lines)

Which shape you picked and where the vault points, how many notes are indexed, whether BM25 and
semantic search both returned the expected note, whether consolidation had anything to work on,
and what the user should do next.
