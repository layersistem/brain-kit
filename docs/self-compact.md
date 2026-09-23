# Self-compact: the agent compacts its own session

## The problem

The context hook (`hooks/context-inject.sh`) tells the model how full its window is and, past the
hard threshold, tells it to write the handover note and let the session compact. That leaves one
step to a human: someone has to type `/compact`. At 03:00, with nobody at the keyboard, the session
sits at 70% until the next tool result pushes it into auto-compaction - which happens mid-turn, with
no handover note, and the model wakes up with the summary the vendor wrote and nothing else.

`scripts/self-compact.sh` removes that last step. The agent writes the note, starts the script as the
last command of its turn, and ends the turn. The script lives outside the model and does the rest.

## What the script does

```
turn ends  ->  /compact sent to the tmux pane  ->  new compact boundary in the transcript  ->  continuation line typed in
```

1. **Waits for the turn to end.** Claude Code prints "esc to interrupt" in the pane while it is busy;
   the script polls `tmux capture-pane` every 5 s until that text is gone, for up to 30 minutes.
2. **Sends `/compact`** with `tmux send-keys` to the session named in `SELF_COMPACT_TMUX_SESSION`,
   else `<project>/.claude/self-compact-session` (written by `setup.sh` when you opt in), else the
   session that owns `$TMUX_PANE`.
3. **Watches the transcript** (`~/.claude/projects/<project slug>/*.jsonl`, newest file, sub-agent
   transcripts skipped) and counts compact boundaries from the JSON fields (`subtype ==
   compact_boundary` or `isCompactSummary`), never by text search - a session's own tool output can
   contain the string. Up to 20 minutes.
4. **Sends the continuation line**: argument 1, or a default that says "you compacted yourself, read
   the handover note and the focus file, continue from the next step, do not ask whether to start".

Every step is logged with a timestamp to `<agent-config-dir>/brain-kit-state/self-compact.log`,
starting with a "started" line the moment the script runs. Success reads `compact done, continuation
line sent`. The exit codes: 1 no tmux, no session name or no transcript; 2 the turn did not end in 30
minutes; 3 no boundary in 20 minutes (the continuation line is then NOT sent); 4 another copy is
already running for this project.

**Double-launch lock.** Two copies would send two `/compact` and two continuation lines, so the script
writes a pid file per project and a second copy exits with "already running". The check matches the
live process's own command line (`bash .../self-compact.sh`), not the shell that launched it - a
`bash -c "(setsid nohup .../self-compact.sh ...)"` wrapper also contains the script's name and used
to be mistaken for a running copy.

**Manual compacts.** If you typed `/compact` yourself, start the script with `SKIP_COMPACT=1`: it
skips step 2, waits for the boundary and sends the continuation line.

## What the model is told

`context-inject.sh` changes its hard-threshold line when self-compact is installed (the script is
present and executable under `$BRAIN_ROOT/scripts/` and `BRAIN_SELF_COMPACT` is not `0`):

> HARD: past 325k - hard threshold reached, self-compact now: write the handover note + focus summary,
> then launch self-compact as the LAST command of the turn (docs/self-compact.md), then call no other
> tool and end the turn

The block `setup.sh` appends to the project's `CLAUDE.md` when you opt in (`docs/SELF_COMPACT_BLOCK.md`)
spells the same order out, with the exact command:

```bash
(setsid nohup "$BRAIN_ROOT/scripts/self-compact.sh" "<the first thing to do after the compact, one line>" >/dev/null 2>&1 &)
```

The "last command, then no other tool" part matters: the script waits for the turn to end before it
sends `/compact`, so anything the model does after launching it only delays the compact, and a tool
call that runs past the 30-minute wait makes the script give up.

The first turn after the compact prints `CONTEXT: first turn after compact, no measurement yet` - the
hook has no `usage` line for the new context yet, and printing the pre-compact number would order a
second compaction on the first turn after the first. That line carries no threshold order.

## Installing

`setup.sh` asks:

```
Install self-compact (requires tmux; the agent compacts itself at the hard threshold)? [y/N]
tmux session name [<current session, if any>]:
```

Yes writes the session name to `<project>/.claude/self-compact-session`, appends the block above to
`<project>/CLAUDE.md`, and sets `BRAIN_SELF_COMPACT=1` in `brain-kit.env`. No (the default, and the
answer when stdin is not a terminal and no flag is given) leaves the script in place without its
executable bit and sets `BRAIN_SELF_COMPACT=0`, so the context hook keeps its older wording.
Non-interactive: `--self-compact=<session>` or `--self-compact=no`. `scripts/update.sh` keeps
whichever you chose: it restores the executable bit to what it was before the update.

To turn it on later by hand: `chmod +x "$BRAIN_ROOT/scripts/self-compact.sh"`, set
`BRAIN_SELF_COMPACT=1` in `brain-kit.env`, write the session name to
`<project>/.claude/self-compact-session`, and append `docs/SELF_COMPACT_BLOCK.md` to the project's
`CLAUDE.md`.

## Testing it without a live session

```bash
PATH=/usr/bin:/bin bash scripts/self-compact.sh          # on a box without tmux: "tmux not found", exit 1, no hang
SELF_COMPACT_TMUX_SESSION=nosuch bash scripts/self-compact.sh   # "tmux session 'nosuch' not found", exit 1
```

The double-launch lock: start one copy, start a second for the same project, the second logs
"already running" and exits 4 while the first keeps waiting.

## Limits

- Claude Code only, and only inside tmux. Other CLIs have no `/compact` to send and no pane to read.
- The busy check reads the last six lines of the pane for "esc to interrupt". A theme or a future
  release that renames that text makes the script wait the full 30 minutes and give up; the log says so.
- The script never decides *whether* to compact. That call stays with the model and the context hook's
  thresholds (`BRAIN_CTX_WARN`, `BRAIN_CTX_HARD`, `<project>/.claude/ctx-thresholds`).
