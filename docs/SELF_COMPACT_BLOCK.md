
<!-- brain-kit-self-compact -->
## Self-compact (brain-kit)

When the CONTEXT line says "hard threshold reached, self-compact now", compact your own session; do
not wait for anyone. In this order:

1. Write the handover note (`<vault>/decision/DR-<date>-handoff-<slug>.md`) and refresh the focus
   file's SUMMARY.
2. As the LAST command of the turn, run
   `(setsid nohup "<brain-root>/scripts/self-compact.sh" "<the first thing to do after the compact, one line>" >/dev/null 2>&1 &)`
3. Call no other tool after it. End the turn.

The script waits for the turn to end, sends `/compact` to the tmux session, waits for the compact
boundary, then types the line you gave it into the window. Log:
`<agent-config-dir>/brain-kit-state/self-compact.log` - success is "compact done, continuation line
sent". A second copy started for the same project prints "already running" and exits, so do not
restart it. If the compact was issued by hand, start it with `SKIP_COMPACT=1`: it then only waits for
the boundary and sends the continuation line.
<!-- /brain-kit-self-compact -->
