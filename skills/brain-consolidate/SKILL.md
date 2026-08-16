---
name: brain-consolidate
description: >
  Nightly consolidation for the brain vault (the waking equivalent of sleep consolidation).
  Use when asked to "consolidate", "distil today's decisions", "scan for superseded notes",
  at the end of a session or before a compaction. Collects a window of decision records,
  finds their older neighbours, and produces a five-part PROPOSAL report. The agent never
  applies anything - the human approves.
---

# brain-consolidate

Decision records pile up. Reusable knowledge stays buried inside them, older records that a
newer decision has invalidated are never marked, and contradictions sit there unnoticed. This
skill turns that cleanup into a reviewable proposal.

## Flow (3 steps)

1. **Build the prompt**

   ```bash
   python3 "$BRAIN_ROOT/scripts/brain_consolidate.py" --since YYYY-MM-DD --until YYYY-MM-DD
   ```

   Writes `<vault>/_drafts/consolidation_<until>_prompt.md`. Default window: yesterday..today.
   No arguments needed for the normal nightly run.

2. **Write the report.** Hand the prompt file to a subagent - use the strongest model you have
   available, since this is a judgement task, not a formatting task. The subagent reads the
   prompt file and writes the five sections (DISTILL, SUPERSEDE, CONFLICT/DUPLICATE, WEIGHT, SKILL DISTILLATION
   CANDIDATES) to `<vault>/_drafts/consolidation_<until>.md`. It touches no other file.

   Gate the result before showing it:

   ```bash
   python3 "$BRAIN_ROOT/scripts/brain_consolidate.py" --verify <report.md>
   ```

   That checks all five sections exist and that no `[[wikilink]]` points at a missing note.

3. **Show the human the report.** Only approved items get applied:
   - distil -> write or edit the target note in `knowledge/` or `memory/`
   - supersede -> add `status: superseded` and `superseded_by:` to the old note
   - weight -> add `weight:` to the decision record's frontmatter

   Nothing is applied without approval. That is the whole safety model.

## Limits

- The agent adds no information that is not in the decision records; note names come only from
  the valid-notes list; secret values are never written into a report.
- "Related" is not "superseded". Only a newer decision that genuinely invalidates an older one.
- Kill switch `<BRAIN_ROOT>/.brain-loop.disabled` and the daily call cap in `distill_lock.py`
  both apply to scheduled runs.
- The headless path (`--llm`) shells out to `BRAIN_CONSOLIDATE_CMD` (default `claude -p`). If
  that CLI is not on PATH, use an in-session subagent instead - the prompt file is the same.
- Two runs on the same day overwrite `consolidation_<until>.md`; archive the earlier report with a
  time/status suffix first. The latest run is the one that counts.
  Archived reports for the same window are fed back into the next prompt as "EARLIER RUNS", so a
  re-run does not re-propose items already applied.
- A compact-hub whose body already says it was handed over ("superseded by / read that one first")
  is not a supersede candidate; only propose `status: superseded` on a real content conflict.
- The prompt carries the observation stream (`observe-mutations.sh`). `[NO-DR]` lines are candidates
  for a missing decision record; hook self-test lines are noise - report them, do not create notes.
