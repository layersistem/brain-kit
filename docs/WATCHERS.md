# Keep the watcher outside the model

A pattern, not a feature: nothing in brain-kit implements it for you. It is here because it is the
single cheapest change we know of for any setup where a session waits for something that happens
elsewhere - a build, a queue, a file another process writes, a message from a second agent.

## The failure it fixes

The obvious way to wait is to let the model wait: check, sleep, check again. Every one of those
checks is a full turn, and a turn is not cheap - the whole conversation is re-read to produce a
one-line "nothing yet". A session polling a quiet channel every minute pays for its entire context
sixty times an hour to learn nothing. The cost does not depend on the answer; it depends on how
often you ask.

The second failure is subtler: polling tools usually have a ceiling (a maximum wait, a maximum
number of iterations), so a long quiet stretch ends with the loop expiring rather than the event
arriving, and the session has to re-arm anyway - having paid for every empty look in between.

## The shape

Put the waiting in a process that costs nothing to be idle, and let the model be woken by the
event:

1. **A watcher outside the session.** A shell loop, a `systemd --user` unit, a launchd agent, an
   `inotifywait`/`fswatch` - whatever your machine already has. It polls, or better, blocks on a
   file descriptor. It holds no conversation, so its idle cost is zero.
2. **One event, one wake.** When the thing happens, the watcher delivers it once - appends a line to
   a queue file, writes a note into the vault, triggers whatever mechanism your agent CLI has for
   handing a session new input.
3. **The session re-arms and stops thinking about it.** After handling the event the session starts
   the watcher again and moves on. No timer in the model's head, no "let me check again in a
   minute".

The rule of thumb: if the answer to "did anything happen?" is almost always no, the question must
not cost a turn.

## Worth building in

- **Re-arm after every event, including a failure.** A watcher that dies silently turns into a
  session waiting forever for a message that will never come. Log its exits somewhere you will look.
- **Give it a deadline.** A watcher with no end date outlives the work it was started for. Hours,
  not days, and let it announce its own expiry.
- **One line in, not a stream.** The point is to spend a turn only when there is something to do; a
  watcher that forwards everything it sees puts the polling cost back, just on the other side.
- **Never let the watcher act.** It observes and delivers. Anything with consequences stays in the
  session, where it can be reasoned about and refused.

## How to tell it worked

Count turns, not seconds. Before: one turn per poll interval, most of them empty. After: one turn per
event. `scripts/usage_report.py` prints calls per project and context per call, which is where an
idle polling loop shows up as a wall of cheap-looking calls that add up to real money.
