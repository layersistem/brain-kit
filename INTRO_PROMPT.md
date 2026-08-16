# INTRO_PROMPT - paste this into a fresh agent session

You are installing **brain-kit**: a persistent memory layer that survives compaction and gives
this session access to what previous sessions decided. Follow this file top to bottom, run the
commands yourself, verify the results, and finish with a five-line report.

Two engines, neither of which calls an API:

- **Recall** - `brain_recall.py`: BM25 (pure stdlib, ~100 ms) fused with dense BGE-M3 hits from
  the `brain_searchd` daemon (recommended, run as a service - docs/DENSE_RECALL.md); runs on every
  prompt through a hook. Without the daemon it is plain BM25.
- **Embed** - `brain_embed.py`, BGE-M3 on local CPU, runs whenever a note is written.

Nothing leaves this machine. **BGE-M3 is a requirement of the full kit** (~2 GB model, downloaded
once by the first embed run); `--no-embed` is a degraded BM25-only mode for machines that cannot
carry it - see README "Requirements".

Pick your track:

- **A** - fresh project, no notes yet.
- **B** - existing project, or markdown notes you already keep.

---

## A. Fresh project

### A1. Install

```bash
cd <the brain-kit checkout>
./setup.sh                 # add --no-embed to skip torch and the model download
```

The installer prints six steps. Read them. If a step fails, report the exact error line and
stop - do not continue on a broken install.

### A2. Verify the install (do not skip)

```bash
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
python3 -c "import json;h=json.load(open('${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json'))['hooks'];print({k:[c['command'] for g in v for c in g['hooks']] for k,v in h.items()})"
python3 "$BRAIN_ROOT/scripts/brain_bm25.py" "example decision" 3
```

Expect hook entries for `UserPromptSubmit`, `PostToolUse`, `PreCompact` and `SessionStart`, and
JSON from the second command. `[]` means the vault is empty, which on a truly fresh install is
possible - the seeded example decision record should make it non-empty.

### A3. Set the focus and write the first decision record

Ask the user what they are working on. Then:

1. Rewrite `$BRAIN_ROOT/vault/focus/_FOCUS_main.txt` - first line `SUMMARY: <one line>`, then
   what is happening now, next, and what is waiting.
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
./setup.sh
```

Then choose one of two shapes and tell the user which you picked:

- **Point the vault at the existing notes.** Best when there is already a notes folder or an
  Obsidian vault. Set `BRAIN_DIR` to it in `<agent-config-dir>/brain-kit.env`, then create the
  subfolders brain-kit expects inside it: `decision/ knowledge/ memory/ moc/ focus/ _drafts/`.
  Existing files stay where they are - retrieval walks the whole tree.
- **Keep the new vault and link the old notes in.** Best when the existing notes belong to
  something else (a repo wiki, product docs). Leave `BRAIN_DIR` alone and set `BRAIN_WIKI_DIR`
  to the other tree; it gets indexed read-only alongside the vault.

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
"$BRAIN_ROOT/.venv/bin/python" "$BRAIN_ROOT/scripts/brain_embed.py"      # skip if --no-embed
python3 "$BRAIN_ROOT/scripts/brain_bm25.py" "<a phrase you know is in the notes>" 5
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
