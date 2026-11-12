---
topic: "Verdict ledger - one row per correction: which notes were in context, and whether one was in view and not followed (scripts/brain_verdict.py report)"
status: active
---

# Verdict ledger

> **When to add a row:** the SALIENCE line fired on a correction and the VERDICT block under it named the notes that
> were in context. One row, written in the same turn, from that block; the hook never writes this file.
> **When to read it:** `python3 <brain-root>/scripts/brain_verdict.py report` - rule load per note (in view and not
> followed) ranks the candidates for the `RULES:` line of the focus file; misses (not surfaced) feed recall's capped boost.

The verdict is one of `in-view` (the note was in context and the mistake happened anyway), `no-record` (no note covered
it: write one), `not-surfaced` (a note existed and recall did not show it) or `not-a-correction` (the word was no
correction). A row you disagree with gets a new verdict in its cell; a row is never deleted. `prompt` is the corrected
prompt in at most twelve words, `in context` the note names from the VERDICT block, `note` the name the verdict is about.

| time | signal | prompt | in context | verdict | note |
|---|---|---|---|---|---|
