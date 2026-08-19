# Discipline

This is how we run the brain. None of it is enforced by the code - the repo ships a memory
engine, not a rulebook. Pick what fits, ignore the rest, and write your own hooks if you want
teeth.

## 1. Decision records are the memory

The unit of memory is a decision record, not a chat log. Write one at the moment of a decision,
a rejection or an approval - and always before a compaction. The parts that pay off later:

- **the rejected path and why.** Without it, a future session re-proposes what you already
  ruled out, and you argue it again from scratch.
- **the reopen condition.** State what would make the decision worth revisiting: a condition,
  not a date.
- **source and evidence link.** Model output on its own is not a memory source.

Never delete a decision that was replaced. Set `status: superseded` and `superseded_by:`.
Recall down-ranks superseded notes automatically, so the history stays readable without
polluting results.

## 2. The "When to look" line

Right under the frontmatter, one line:

```
> **When to look:** when X breaks, when someone asks about Y, before touching Z.
```

Retrieval finds a note by its words; this line tells the reader whether the note is worth
opening at all. It costs one line and saves the "I found five notes, which one matters" tax
on every recall.

## 3. Knowledge first, archaeology last

Before reverse-engineering anything - reading source to reconstruct a flow, introspecting a
database, tracing a container to find out how it starts - search the vault and read the
existing notes. Most of the time the answer is already written down. Big code archaeology to
answer a small question is the expensive way to get an answer you already own.

Practical order: recall injection -> vault or wiki articles -> only then the code.

## 4. Weight tags, used sparingly

`weight: canon | lesson | approval | routine` multiplies a note's recall score. It works only
while it stays rare. If a third of the vault is `canon`, nothing is canon. A rule of thumb that
has held up: a handful of `canon` notes per project, `lesson` for things that cost you real
time to learn, `routine` for notes you want kept but rarely surfaced.

The same applies to headings: `CANON`, `LESSON` and `NEVER` in a section title raise that
section's weight, so do not decorate ordinary headings with them.

## 5. Compaction: hub note plus snapshot

Compaction is lossy and model-written. Two things make it survivable:

- **a handoff note** written *before* the compaction: where the work stands, what is decided,
  what is still open. Name it so the post-compact hook finds it (`DR-<date>-handoff-*.md`).
- **the automatic snapshot** from the PreCompact hook: the last messages, verbatim, in
  `_drafts/`. It is deliberately excluded from recall and from the index - it is a backup for a
  human or an agent to open on purpose, not context to inject.

After a compaction: re-read the skills that were loaded (compaction drops their bodies),
summarise the state in one message, and confirm before diving back in. Auto-resuming from a
half-restored context is how sessions break things.

A related mid-turn rule: when something interposes after an answer is already written - a
blocking stop hook, a tool result, an error, a user interrupt - do not rebuild the answer from
scratch. The text is already on the user's screen; a full rewrite prints it twice. Do the
missing action, then reply with the delta only.

## 6. Nightly consolidation: propose, then approve

Run `brain_consolidate.py` on a schedule or at the end of a session. It gathers the window's
decision records plus their older neighbours and produces a five-part proposal: what to distil
into durable knowledge, which old notes are now superseded, which notes contradict each other,
which records deserve a weight tag, and which lessons should become (part of) a skill.

The agent proposes. A human approves. Nothing is applied automatically - a memory system that
edits its own memory unattended stops being trustworthy the first time it is wrong.

The pass also reads the observation stream (`_drafts/observations_<instance>_<day>.md`, written by
`observe-mutations.sh` on every write, edit and state-changing shell command). A mutation no decision
record explains comes back as `[NO-DR]`: work that happened but was never written down. Hook self-test
lines will show up there too; treat them as noise, not as a note to create.

Two runs on the same day overwrite `consolidation_<until>.md`. Archive the earlier report with a
time or status suffix before re-running; the latest run is the one that counts. Archived reports for the same window are fed back into the next
prompt ("EARLIER RUNS") so a re-run only lists what is new or still open. Hand-over hubs
("read the newer one first") are not supersede candidates.

## 7. Multiple instances, one vault

Each session declares an owner via the `instance:` frontmatter field, and each has its own
focus file. One folder, one owner: two sessions writing the same note is how you get a merge
conflict inside your memory. See [MULTI_INSTANCE.md](MULTI_INSTANCE.md).

Keep the focus file small. It is re-injected on every prompt, so it is the most expensive text
in the vault per byte: current state, the pointer to today's hub record, open items - and
nothing that a decision record already holds. We measured a focus file that had grown into a
59 KB diary line costing 96 KB of injected context on every prompt, for every instance that
reads it. The hook caps injection at 12 KB and warns; the fix is to move the history into a
decision record, not to raise the cap.

## 8. Things we use but do not ship

These live in our private setup as hooks. They are opinionated, easy to get wrong, and none of
them belongs in a general-purpose memory engine - but if you want them, they are a few lines of
shell each:

- **model-tier gating**: irreversible actions (deploys, migrations, anything touching money or
  production) are only allowed from a session running a strong-enough model. A `PreToolUse`
  hook that reads the session model and blocks otherwise.
- **commit gate**: no commit until a human has field-tested the change. A hook that blocks
  `git commit` unless an approval flag file exists.
- **line-count cap**: source files over N lines are blocked on write, which forces modules
  instead of one growing file.
- **style-enforcing stop hooks**: a `Stop` hook that checks the response against a required
  output style and asks for a rewrite.
- **write-discipline gates**: blocking a session from moving on until the decision it just made
  has been written to the vault.

Write your own if you want them. Keep them out of the recall path: a memory engine that refuses
to answer is worse than no memory engine.
