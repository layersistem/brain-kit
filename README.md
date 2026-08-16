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

- Python >= 3.10, `jq`, a POSIX shell. macOS and Linux tested.
- **BGE-M3 (`BAAI/bge-m3`) is required for the full kit.** `setup.sh` installs
  `sentence-transformers` + `torch` into `<BRAIN_ROOT>/.venv` and the first embed run downloads
  the model (~2 GB, once, from Hugging Face; offline afterwards). It powers the embed hook, the
  duplicate check on write, `brain_search.py`, and the hybrid recall daemon
  (`docs/DENSE_RECALL.md`) - the configuration we measured best (BM25 hit@1 0.80 -> hybrid 0.87).
  Budget ~2 GB disk for the model and ~3 GB RAM if you run the daemon resident.
- `./setup.sh --no-embed` is the fallback for machines that cannot carry the model: BM25 recall,
  focus injection, compact snapshots and consolidation still work; embedding, dedup-on-write and
  dense recall stay off. It is a degraded mode, not the recommended one.
- Optional: Obsidian. The vault is plain markdown with `[[wikilinks]]`; graph view and backlinks
  make orphan notes and missing links visible at a glance.

## Quick start

```bash
git clone https://github.com/<you>/brain-kit && cd brain-kit
./setup.sh                       # or: ./setup.sh --no-embed   (BM25 only, no model download)
BRAIN_ROOT=~/brain python3 ~/brain/scripts/brain_bm25.py "example decision" 3
```

Restart your agent session afterwards so the hooks load. `--minimal` installs only recall,
embedding and the compact hooks; the default profile adds the vault hygiene check, the
observation stream and the consolidation skill. Then run the dense-recall daemon as a service
(recommended, `docs/DENSE_RECALL.md`) - recall is hybrid the moment it is up, BM25-only until then.

## Model-first install

You do not have to run any of this yourself. Open Claude Code in the cloned folder and paste
[`INTRO_PROMPT.md`](INTRO_PROMPT.md) into it. It has two tracks - a fresh project and an
existing one with notes you already keep - and the model runs the installer, verifies the hooks
landed in `settings.json`, checks that recall answers a query, and reports back in five lines.

## Architecture

```
  your prompt
      |
      +--> [UserPromptSubmit] _focus_inject.sh ----> current focus file, verbatim
      +--> [UserPromptSubmit] _auto_retrieve.sh ---> brain_recall.py --> top-k notes injected
                                                     |-- brain_bm25 (zero model, ~100 ms, stdlib only)
                                                     '-- brain_searchd daemon (warm BGE-M3, ~80 ms,
                                                         RRF-fused; recommended, run as a service;
                                                         absent -> plain BM25; docs/DENSE_RECALL.md)
      +--> [UserPromptSubmit] time-inject.sh -------> a clock: now (with weekday), session age,
                                                     minutes since your last prompt
      +--> [UserPromptSubmit] due-inject.sh --------> @due lines whose day has come (overdue, today,
                                                     tomorrow) + once a day the coming week
      +--> [UserPromptSubmit] context-inject.sh ----> how full the context is, delta since last prompt,
                                                     warning before auto-compaction (Claude Code only)
  you write a note
      +--> [PostToolUse] brain-embed-after-write.sh --> brain_embed.py --> .index/embeddings.jsonl
      |                                                 (BGE-M3, local CPU, hash-incremental)
      +--> [PostToolUse] postwrite-check.sh ----------> ghost-link + empty-note check
  you mutate anything (write, edit, state-changing shell)
      +--> [PostToolUse] observe-mutations.sh --------> _drafts/observations_<instance>_<day>.md
                                                       (append-only trail, secrets masked, kept out
                                                        of retrieval; consolidation reads it and flags
                                                        work no decision record explains as [NO-DR])

  before compaction
      +--> [PreCompact] precompact-snapshot.sh ------> _drafts/compact_snapshot_<instance>.md
  after compaction
      +--> [SessionStart:compact] pointer ------------> "read the handoff note, then this snapshot"

  by hand / nightly
      brain_search.py       BGE-M3 retrieve (+ optional reranker; measured worse
                            than plain cosine here) - one-off deep search, still local
      brain_consolidate.py  window of decisions -> proposal report -> human approves
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
| Interoception | insula (the body's own state: fatigue, fullness) | `context-inject.sh` - context tokens, % of window, delta per prompt, warning at 80% | "how full am I, how fast am I filling, is the blackout near" - so the handoff note is written before compaction, not reconstructed after. Claude Code only: it reads the transcript's `usage` block; the number matches the app's Context window panel to the token |
| Re-orientation after a blackout | waking up: reticular activating system | `sessionstart-compact-pointer.sh` + the handoff note it points at | "where am I, what was I doing" after a compaction, without a search |
| Salience / emotional tagging | amygdala | `weight:` (canon > lesson > approval > routine) in the ranking, and the reflex that sets it: `salience-inject.sh` spots a correction in your prompt ("wrong", "undo", "why did you"; `BRAIN_SALIENCE_RX` for your language) and tells the model to tag this turn's record `weight: lesson`; `salience-postwrite.sh` warns if a decision record is then written without a weight | canon outranks routine at equal relevance; and what hurt gets encoded as a lesson without anyone remembering to do it |
| Forgetting | synaptic decay | age decay + `superseded` penalty | an old, undated-importance note fades instead of crowding out this week's |
| Sleep consolidation | hippocampus -> cortex replay | `brain_consolidate.py` proposal | distil episodes into knowledge, mark superseded, surface contradictions - a human approves |
| Implicit episodic trace | hippocampal indexing of what you did, not what you decided | `observe-mutations.sh` stream | every mutation leaves a one-line trace; consolidation matches traces to decisions and flags the unexplained ones |
| Metacognition | anterior cingulate | confidence tags on every recalled note (STRONG = both engines agreed or dense cosine over the floor, FAIR = one engine) + an explicit "no matching note - treat as not known" line when a real question finds nothing; discipline docs, `docs/DISCIPLINE.md` | knowing how much to trust what memory just handed you, knowing that you don't know (say so, label the guess a hypothesis) - and when the tool is wrong, when to stop, when to ask |

Not covered, on purpose: continual learning of the weights themselves. This kit does not train
anything; it gives a frozen model a memory it can read.

## What gets injected, and when

| Moment | Hook | What lands in context |
|---|---|---|
| every prompt | `_focus_inject.sh` | your focus file for this instance, verbatim |
| every prompt | `_auto_retrieve.sh` | top-k matching notes with a confidence tag each (STRONG/FAIR) and a count in the header; STRONG notes carry the "what" line + excerpt, FAIR notes only title + address (low confidence gets less room); on a real question (>= 6 words) with no match, one line saying so - not silence |
| every prompt | `time-inject.sh` | a clock: local date+weekday+time, session age, minutes since the last prompt |
| every prompt | `due-inject.sh` | what is due: `@due YYYY-MM-DD[ HH:MM] text` lines from your focus + your own decision records - overdue (days late), today (NOW once the hour passes), tomorrow; on the first prompt of the day also the coming week (2-7 days); silent otherwise |
| every prompt | `salience-inject.sh` | only when your prompt carries a correction signal: one line - "tag this turn's record `weight: lesson`" |
| after a note write | `salience-postwrite.sh` | only when a decision record is written weight-less after a correction in this session |
| every prompt | `context-inject.sh` | context ~Nk (P% of window), delta since last prompt, warning past 80% (`BRAIN_CTX_WARN`, `BRAIN_CTX_WINDOW`). **Claude Code only** - needs the hook's `transcript_path`; silent elsewhere |
| after a note write | `brain-embed-after-write.sh` | one line confirming the re-embed (or that it failed) |
| after a note write | `postwrite-check.sh` | only when a wikilink points at a missing note, or a note is empty |
| before compaction | `precompact-snapshot.sh` | nothing - it writes a file |
| after compaction | `sessionstart-compact-pointer.sh` | addresses: the handoff note and the snapshot |

Recall stays quiet when it has nothing good: below a relevance floor it returns no block at all,
because five irrelevant notes cost more than none.

## Configuration

Everything is environment variables; `setup.sh` writes the two that matter into
`<agent-config-dir>/brain-kit.env`, which every hook sources. An exported variable always wins.

| Variable | Default | What it does |
|---|---|---|
| `BRAIN_ROOT` | `~/brain` | install root: vault, scripts, hooks, venv |
| `BRAIN_DIR` | `$BRAIN_ROOT/vault` | the vault itself - point it at notes you already have |
| `BRAIN_INSTANCE` | `main` | this session's name (else `.brain-instance`) |
| `BRAIN_MEMORY` / `BRAIN_MEMORY2` | `$BRAIN_ROOT/memory`, none | extra roots indexed as timeless memory |
| `BRAIN_WIKI_DIR` | none | optional shared docs root, read-only, indexed alongside |
| `BRAIN_RECALL_K` | `5` | how many notes recall injects |
| `BRAIN_STOPWORDS` | empty | extra stopwords (also `<root>/.brain-stopwords`) |
| `BRAIN_EMBED` | `1` | `0` keeps the embedding hook idle (set by `--no-embed`) |
| `BRAIN_EMBED_MODEL` / `BRAIN_RERANK_MODEL` | BGE-M3 / bge-reranker-v2-m3 | local model overrides |
| `BRAIN_SEARCHD_URL` / `_TIMEOUT` / `_PORT` | `127.0.0.1:8799`, `0.3`, `8799` | dense-recall daemon (recommended, `docs/DENSE_RECALL.md`); absent = BM25 only |
| `BRAIN_DENSE_MIN` / `BRAIN_DENSE_JOIN` | `0.62` / `0.55` | dense cosine gates: answer-alone / enter-fusion |
| `BRAIN_PROJECT_NAME` / `_VOCAB` / `BRAIN_CWD_MARKERS` | empty | project scope filter (off by default) |
| `BRAIN_FOCUS_DIRS` / `BRAIN_ISOLATE_DIRS` | empty | directory globs where hooks speak, or stay silent |
| `BRAIN_CONSOLIDATE_CMD` | `claude -p` | CLI used by the optional `--llm` consolidation path |

## What this is not

- **Not an enforcement layer.** Nothing here blocks a tool call, gates a commit, or refuses an
  action. The only hook that pushes back is the vault hygiene check, and only about broken links
  and empty notes.
- **Not model gating.** brain-kit never inspects or restricts which model you are running.
- **Not a rulebook.** The habits that make this work - decision records, the "when to look"
  line, sparing weight tags, propose-then-approve consolidation - live in
  [`docs/DISCIPLINE.md`](docs/DISCIPLINE.md) as advice. Take what fits.
- **Not a hosted service.** No account, no telemetry, no network call after the one-time model
  download.

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
