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

Practical order: recall injection -> vault or wiki articles -> only then the code. If the wiki is yours to shape,
[WIKI.md](WIKI.md) describes a layout and an article shape that recall reads well, including how to write code paths
so that a wiki hit points at the code.

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

A third thing steers the summary itself: a "Compact Instructions" section in `CLAUDE.md` that says what
the summary must keep (README, "Compact Instructions").

After a compaction: re-read the skills that were loaded (compaction drops their bodies),
summarise the state in one message, and confirm before diving back in. Auto-resuming from a
half-restored context is how sessions break things. The exception is self-compact
([self-compact.md](self-compact.md)): there the agent compacted itself in order to carry on, it
wrote the handoff record and the focus summary first, and the post-compact hook tells it to
continue from them instead of asking (1.2.0).

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
59-kilobyte diary line costing 96 kilobytes of injected context on every prompt, for every instance that
reads it. The hook caps its whole output at 8,500 characters and, when the focus does not fit,
says so in the first line (Claude Code hands the model only a 2-kilobyte preview of a hook output past
about 10,000 characters, so a warning at the end would never be seen); the fix is to move the
history into a decision record, not to raise the cap.

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

One pattern from that private setup is written up here because it is not opinionated at all, just
cheaper: [`WATCHERS.md`](WATCHERS.md) - when a session waits for something that happens elsewhere,
put the waiting in a process outside the model and let the event wake the session. A polling loop
pays for its whole context on every empty look.

## 9. Measuring a session from its own transcript

Two lessons that cost us a wrong answer each, both about the JSONL transcript the agent writes as it
goes. `scripts/usage_report.py` implements them; if you write your own accounting, start here.

**One response is many lines, and they all carry the same bill.** An assistant response lands in the
transcript as one line *per content block* - thinking, text, each tool call - and every one of those
lines repeats the same `message.id` and the same `usage` object. Counting lines, or summing `usage`
per line, therefore counts the same tokens several times over: 1.85x to 2.6x on our own transcripts,
which is the difference between "this agent is fine" and "this agent is the most expensive thing we
run". Count distinct `message.id` values and take each one's `usage` once. Context per call is
`input + cache_read + cache_creation`; once a session is warm the cache read is most of it, so
leaving it out makes a long session look free.

**A message typed while the model is working does not arrive as its own turn.** It is absorbed into
the turn already in flight - in Claude Code's transcript as a `queue-operation` / `remove` record
marked `absorbed_mid_turn`, with no separate user line. Any count of "how many times did the human
speak" that reads user lines alone will miss them, and any watcher that waits for a new user turn
before reacting will wait forever. Look for the absorbed record, not only for the turn.

The general rule behind both: a transcript is an append-only log of an implementation, not a receipt.
Before you quote a number from it, take one hour of it apart by hand and check that the parser and
the eye agree.

## 10. Editing a record: one status line, changed in place

A record changes state over its life: a decision goes from `active` to `superseded`, a belief from
`expected` to `confirmed`. The change is an edit of the one line that holds the state, made where that
line stands, the way an exact-string replace works: the old line must be unique in the file, and after
the edit there is still exactly one. Three things never happen:

- **A second status line or block.** Appending "status: superseded" under the old one leaves two
  answers in the file, and which one counts depends on the reader: the ranking (`brain_bm25.py`) takes
  the first `status:` line of the front matter, `beliefs_rebuild.py` keeps the last `- status:` line of
  a belief entry, a person usually reads the newest. A consolidation pass can check for it: more than one
  `status:` line in a record's front matter, or more than one `- status:` line in one `## B###` entry of
  the belief ledger, is a defect.
- **A deleted record.** A replaced decision stays, marked `superseded` with a `superseded_by:` link
  (§1); the history of why something was dropped is part of the memory.
- **A silent rewrite of the body.** When a record's conclusion changes, add a dated section saying
  what changed and why. The old reasoning stays readable under it.

`origin_session:` (optional, in the record template) holds the first 8 characters of the id of the
session that wrote the record; with `BRAIN_SHOW_SESSION=1` the clock line shows them. It is how a later
consolidation finds the transcript a decision came out of. An edit by another session does not change it.

## 11. Expectations: the prediction before the outcome

Decision records say what was decided, and the verdict ledger says what went wrong. Neither says what you expected
before the outcome was known, so a surprise leaves no trace, and a "works" written after the fact cannot be told apart
from a lucky guess. One line next to the work fills that gap (expectation memory; `BRAIN_EXPECT=0` turns it off). Write it in the focus file or in the
decision record before you deliver, before you write "works" or "passed", and before you judge a result you have not
measured yet:

```
@expect 2026-11-13 the export finishes in under 60 seconds on the full vault · measure: the timer line in the job log · written: 2026-11-10
```

The date is the day the outcome will be known. The measure is something a later session can check without asking you;
a line whose measure is "it should be fine" is not worth writing, and neither is a line on a record that makes no claim.
On its day the DUE block shows the line. Close it where it stands: `@expect✓ held: <what happened>`,
`@expect✗ missed: <what happened>`, or `@expect✓ void: <why>` when the question stopped mattering. Keep the missed
ones; they show where a claim ran ahead of the evidence. `scripts/brain_expect.py` prints the counts and the hit rate,
and `--closed` lists the missed lines first. A missed line that changes what you believe is a candidate `falsified`
entry in the belief ledger ([BELIEFS.md](BELIEFS.md)).

A prediction that never gets its line is the common failure, so with the switch on `postwrite-check.sh` reminds you.
It does not look at length or tense: it looks for a small vocabulary that separates a prediction from a task sentence
or a description of how something works (`BRAIN_EXPECT_RX`, case ignored, whole words only; by default
`expect|estimate|predict|likely|probably|should hold|to watch`, so "expected", "unexpected" and "unlikely" do not
count). When the text you just wrote to a decision record, a
knowledge note, a hub note in `moc/` or a focus file holds one of those words and no `@expect` marker, one sentence
follows the write, naming the words it found. It never blocks. Text inside fenced code, inline backticks and double
quotes is not scanned, since an example or a quotation is not your prediction. An instance is reminded at most once in
15 minutes, and a write that carries `@expect` starts that period again, so you are not reminded right after writing
an expectation. If your records are not in English, set the pattern to the words you actually use; a broad pattern
such as any future tense reminds on most writes, and a reminder that is usually wrong stops being read.

Predictions are also written outside the vault notes: a status line, a ledger entry, a message to another instance.
The check lives in one sourced file, `hooks/_expect_remind.sh`, so a script of your own can run it after its write and
share the same quiet period:

```bash
E="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-kit.env"; [ -f "$E" ] && { set -a; . "$E"; set +a; }
H="${BRAIN_ROOT:-$HOME/brain}/hooks"; . "$H/_expect_remind.sh"; . "$H/_instance.sh"
printf '%s' "$line" | expect_remind "the status line" || true   # prints the reminder or nothing
```

The first line matters: the hooks read `brain-kit.env` on every run, a script of yours does not, and a session does not
put `BRAIN_ROOT`, `BRAIN_EXPECT` or `BRAIN_EXPECT_RX` into the environment of the commands it runs. Without it the
function does not see a `BRAIN_EXPECT=0` or a pattern of your own, or the file is not found at all. The function returns 0 on
every path, also under `set -euo pipefail`; the `|| true` keeps a script with those options going all the same, since
the function was written for the hooks, which run without them. The kit ships no such script.
