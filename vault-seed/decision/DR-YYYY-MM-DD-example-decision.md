---
instance: main
date: 2026-01-15
topic: how a decision record is written in this vault
status: active
weight: canon
---

# DR-YYYY-MM-DD-example-decision

> **When to look:** whenever you are about to write a decision record and want the shape,
> or when you wonder what belongs in the vault and what does not.

This file is the template and the example at once. Copy it, rename it
`DR-<date>-<short-slug>.md`, and replace the content. Delete it once you have real records.

## DECISION

Decision records hold **decisions, rejections, approvals and the lessons behind them** - not
plans and not task lists. A decision goes in at the moment it is made, and before a context
compaction can eat it.

Frontmatter carries the routing information recall uses:

- `instance:` - which session or person owns this note (see docs/MULTI_INSTANCE.md)
- `date:` - drives the recency boost and the age decay
- `topic:` - a one-line description; recall injects it as the "what" line
- `status:` - `active`, or `superseded` once a newer decision replaces it
- `weight:` - `canon`, `lesson`, `approval` or `routine`; use it sparingly, it is a multiplier

## ALTERNATIVES

Write down the paths you did **not** take and why. This is the part that pays off months
later: without it, a future session re-proposes the option you already rejected and you
re-derive the whole argument.

- Rejected: keeping decisions in the chat transcript. Reason: compaction is lossy and a
  transcript is not searchable across sessions.
- Rejected: one giant notes file. Reason: recall scores sections, so many small notes with
  real headings beat one file that always matches everything.

## RATIONALE

Evidence, links, measurements - whatever makes the decision checkable later. Model output on
its own is not a memory source: a decision needs a source and a link to the evidence.

Never delete a decision that was replaced. Mark it `status: superseded` and add
`superseded_by:` pointing at the newer record. Recall then down-ranks it instead of
pretending it never existed, which keeps the history readable.

## REOPEN

State what would make this decision worth revisiting - the condition, not a date. For example:
"reopen if the vault passes ~2000 notes and BM25 recall latency exceeds 300 ms".
