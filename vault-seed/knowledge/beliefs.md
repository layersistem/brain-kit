---
topic: "Belief ledger - source (md); .index/beliefs.db is derived from it (scripts/beliefs_rebuild.py)"
status: active
weight: canon
---

# Belief ledger (source file)

> **When to check this:** before ruling on anything that leans on a decision record or a
> knowledge note (is there an active belief, does it contradict another one) - and before
> comparing an expected outcome against what actually happened.
> **When to add a line:** a new decision or measurement lands - append (ids only go up, an old
> line is never deleted; its status changes and it gets a `superseded_by` link instead).
> Source of truth is this file plus git; `.index/beliefs.db` is derived and rebuilt on demand by
> `scripts/beliefs_rebuild.py` - see docs/BELIEFS.md for the full mechanism.
> Format is fixed: a `## B### · <topic>` heading, a `status/evidence/from/superseded_by` line, a
> `src` line, a `claim` line, a `note` line. Status: active, expected, confirmed, falsified,
> superseded, pending. Evidence: canon, decision, measurement, observation, lesson, assumption.
> Topic is the key the contradiction check groups on: reuse an existing topic name if one already
> fits (`grep '^## B' knowledge/beliefs.md | sed ... | sort -u`) instead of minting a near-duplicate.

## B001 · example topic name
- status: active · evidence: decision · from: 2026-01-01 · superseded_by: -
- src: decision/DR-2026-01-01-example-decision.md
- claim: One falsifiable sentence - the actual thing you now believe, not a summary of the record it came from.
- note: optional context a reader would otherwise have to open the source record to get

## B002 · example topic name
- status: superseded · evidence: measurement · from: 2025-06-01 · superseded_by: B001
- src: decision/DR-2025-06-01-earlier-decision.md
- claim: An earlier claim on the same topic, since revised - kept in place so the evolution is visible, not deleted.
- note: why it changed, in a few words
