# Beliefs (optional): a ledger of falsifiable claims, separate from the record of what happened

A decision record is episodic: what you decided, on what date, having rejected what else. Useful
for "what did we try on this and why" - but re-reading ten records every time a session needs to
know whether something is still true does not scale, and nothing forces two records that quietly
contradict each other to ever be compared. The belief layer is a second, much smaller file next
to it: one line per distilled, falsifiable claim, carrying its own status, so a session can ask
"is this still true" without re-deriving the answer from history, and a contradiction between two
claims on the same topic gets caught mechanically instead of by luck.

This is opt-in and off by default. Nothing else in the kit depends on it. Turn it on when the
vault has enough decision records that the same question keeps getting re-answered from scratch.

## What it looks like

The source of truth is one markdown file, `knowledge/beliefs.md`, tracked in git like everything
else in the vault. Each belief is a fixed four-line block:

```
## B001 · default model tier
- status: active · evidence: decision · from: 2026-08-22 · superseded_by: -
- src: decision/DR-2026-08-22-example.md
- claim: The model floor for this project is the mid-size tier; there is no smaller fallback.
- note: reverses an earlier "smallest tier is the design floor" call
```

- **id** - `B001`, `B002`, ... never reused, never deleted, only appended to. History lives in the
  fact that old ids stay in the file with an updated status, not in editing them away.
- **status** - `active` (currently believed true) · `expected` (a stated prediction, not yet
  checked) · `confirmed` · `falsified` · `superseded` (something newer replaced it - see
  `superseded_by`) · `pending` (open, unresolved).
- **evidence** - `canon` (a standing rule) · `decision` · `measurement` · `observation` ·
  `lesson` · `assumption`. This is provenance, not confidence - a `lesson` is not weaker than a
  `decision`, it is a different kind of source.
- **topic** - the string the contradiction check groups on. Reuse an existing topic name if one
  already fits; a new topic per near-duplicate claim defeats the whole point.
- **src** - the decision record or knowledge note the claim was pulled from.
- **claim** - one sentence, falsifiable, standing on its own without the source record open.
- **note** - optional, short context a reader would otherwise have to open the source for.

## How it gets rebuilt

`.index/beliefs.db` is derived, disposable, and never hand-edited. `beliefs_rebuild.py rebuild`
re-reads the ledger, rebuilds the SQLite table from scratch, and carries an existing embedding
over untouched whenever a claim's text has not changed - so a rebuild never re-runs the encoder
unless something was actually added or edited. If the file were deleted, the command that built
it would reconstruct it from the ledger alone; nothing is lost by treating the DB as disposable.

```bash
scripts/beliefs_rebuild.py check              # validate the ledger; exits non-zero on error
scripts/beliefs_rebuild.py rebuild [--embed]  # ledger -> beliefs.db (embed also encodes new claims)
scripts/beliefs_rebuild.py report             # same-topic contradictions and multi-active topics
scripts/beliefs_rebuild.py suggest-topic "<a new claim>"   # nearest 3 existing topics (advisory)
```

The contradiction check in `report` is deterministic, not similarity-based: same topic, one
status in `{active, confirmed}` and another in `{superseded, falsified}` is flagged as a resolved
evolution worth a glance; two simultaneously `active` beliefs on the same topic are flagged for a
human to look at. Embeddings only back `suggest-topic`, which is advisory - deciding whether a
new claim belongs under an existing topic is a judgement call, not a threshold.

## Adding beliefs in bulk

Extracting beliefs out of a large backlog of existing decision records is a batch job, usually
handed to a subagent: it reads a batch of records and proposes candidates in the same block
format, using a temporary `T01-01`-style id since it does not know the ledger's current max id.
`beliefs_merge.py` renumbers a batch of candidate files onto the ledger's real ids, rewrites any
`superseded_by: T..` reference to the `B###` id it resolved to, flags duplicates and malformed
rows, and only writes with `--apply` - the default is a dry-run preview:

```bash
scripts/beliefs_merge.py batch-00.md batch-01.md          # preview: counts, status/evidence mix, errors
scripts/beliefs_merge.py --apply batch-00.md batch-01.md  # write
scripts/beliefs_merge.py --apply --skip T02-09,T03-04 batch-00.md   # drop specific candidates first
```

## How it reaches recall

`_auto_retrieve.sh` calls `beliefs_recall.py` right after printing its recall block, passing the
paths of whatever notes recall just surfaced. If any of those notes is a belief's `src`, the
active beliefs attached to it print in one small block, along with a pointer to anything on the
same topic that has since evolved - so the question "is there an active belief here, and does it
contradict anything" reaches the model before it renders a judgement, not after. Silent if
`.index/beliefs.db` does not exist yet, so turning this on is purely additive.

## Turning it on

1. Copy `vault-seed/knowledge/beliefs.md` into your vault's `knowledge/` (setup.sh does this if
   the file is not already there) and replace the two example beliefs with real ones, or start
   from zero and add lines as decisions land.
2. Run `scripts/beliefs_rebuild.py check` then `rebuild [--embed]`.
3. That is the whole install - `_auto_retrieve.sh` already calls `beliefs_recall.py` on every
   prompt and no-ops when the DB is missing, so there is no hook to wire up separately.
