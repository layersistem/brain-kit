# Dense recall (optional): the warm BGE-M3 daemon

BM25 is the default recall engine and it is good: on the author's 15-query set it reaches
hit@1 0.80 / MRR 0.89 in ~100 ms with no model at all. The optional dense layer adds a resident
BGE-M3 process and fuses its results with BM25 (reciprocal-rank fusion). Same set: hit@1 0.87 /
MRR 0.93. It is a modest gain, measured before it was switched on - install it only if you want it.

What it costs: one Python process holding the model (~2-3 GB RSS, idle CPU 0 %), ~80 ms per query,
and a service definition so it survives reboots. What it never costs: correctness. If the daemon is
down or slow (>0.8 s), `brain_recall.py` silently returns plain BM25 - and writes one line per call to
`<agent-config-dir>/brain-kit-state/dense_calls.log` (`epoch|ok/miss|ms|error|instance`), because a
silent fallback you cannot count is a fallback you will never notice. The budget was 0.3 s until it was
measured: a warm query answers in ~90 ms, but while the write hook embeds a note (10-14 s of CPU) the
daemon took 311 ms and lost the dense half for that turn. 0.8 s costs nothing on a quiet machine.

## How it fits

```
UserPromptSubmit -> _auto_retrieve.sh -> brain_recall.py
                                          |-- brain_bm25.search()          (in-process)
                                          |-- GET 127.0.0.1:8799/search    (brain_searchd, warm BGE-M3)
                                          '-- RRF fuse -> top-k -> injected
brain_searchd reads <vault>/.index/brain.db (the SQLite index brain_index.py maintains; kept fresh
by the embed hook on every note change) and reloads it whenever the file's mtime changes - no
restart needed after you write. A plain read-only connection, so there is no half-written-file
race to guard against, unlike the flat file this replaced.
```

Per-project memory is tagged `imem/<project-slug>/` by `brain_embed.py`; the daemon only returns
those entries to the instance whose slug matches (`scope=` parameter, derived from `BRAIN_MEMORY2`).
Vault and shared memory are visible to every instance. The shared docs roots (`BRAIN_WIKI_DIR`, plus
`BRAIN_WIKI_DIRS` for further ones - tagged `wiki`, `wiki2`, ...) are embedded too and visible to everyone,
unless `BRAIN_WIKI_SCOPE_RX` / `BRAIN_WIKI_SCOPE_RXS` narrow each one to the sessions whose slug matches -
one machine, several products, each session only sees its own product's docs (`scripts/brain_wiki.py`).

Tuning knobs (env, all optional): `BRAIN_SEARCHD_URL`, `BRAIN_SEARCHD_TIMEOUT` (0.8),
`BRAIN_DENSE_MIN` (0.62 - dense may answer alone, when BM25 is empty, only above this cosine),
`BRAIN_DENSE_JOIN` (0.55 - dense hits below this do not enter the fusion). The two thresholds came
from measuring gold cosines (min 0.61) against chit-chat cosines (max 0.595) on the author's vault;
re-measure on yours with `ml/brain_eval`-style gold pairs before changing them. A shared docs root can
sit at a different level than the vault - one measured case had gold passages at 0.51 cosine in an
English technical wiki while the vault's own gold started at 0.61 - so the fusion gate is also settable
per root tag: `BRAIN_DENSE_JOIN_ROOTS="wiki=0.48,wiki2=0.50"`. Roots not listed keep `BRAIN_DENSE_JOIN`.

## Running it as a service

macOS (launchd) - `~/Library/LaunchAgents/com.example.brain-searchd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.brain-searchd</string>
  <key>ProgramArguments</key><array>
    <string>/Users/you/brain/.venv/bin/python</string>
    <string>/Users/you/brain/scripts/brain_searchd.py</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>BRAIN_ROOT</key><string>/Users/you/brain</string>
    <key>TOKENIZERS_PARALLELISM</key><string>false</string>
    <key>OMP_NUM_THREADS</key><string>4</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>/Users/you/Library/Logs/brain-searchd.log</string>
  <key>StandardErrorPath</key><string>/Users/you/Library/Logs/brain-searchd.err</string>
</dict></plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.brain-searchd.plist
curl -s http://127.0.0.1:8799/health
```

Linux (systemd user unit) - `~/.config/systemd/user/brain-searchd.service`:

```ini
[Unit]
Description=brain-kit dense recall daemon (BGE-M3)
[Service]
Environment=BRAIN_ROOT=%h/brain TOKENIZERS_PARALLELISM=false OMP_NUM_THREADS=4
ExecStart=%h/brain/.venv/bin/python %h/brain/scripts/brain_searchd.py
Restart=always
RestartSec=15
[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now brain-searchd
```

## Why cosine only

A cross-encoder reranker (`bge-reranker-v2-m3`) was measured on the same set: MRR 0.86 at 7.5 s per
query - worse and two orders of magnitude slower than plain cosine on this kind of corpus (short,
title-led markdown sections). `brain_search.py` still offers it for one-off deep searches; the hook
path never uses it.

## Concurrency and the miss rate (measured 2026-09-09 → 2026-09-10)

`dense_calls.log` (`epoch|ok/miss|ms|error|instance`) makes the silent fallback measurable, so
measure it. On a machine running many sessions, the misses were not random: with concurrency
defined as other calls within ±1 s, the 0-3 buckets missed ~1% while the 4+ bucket missed 40.6%
(313/770 calls). The cause was several sessions being woken by the same event and all calling
the single-threaded daemon in the same second.

Two changes, both outside the daemon: stagger whatever wakes the sessions (a per-session random
delay of a few seconds before the recall call) and raise `BRAIN_SEARCHD_TIMEOUT` from 0.8 to
1.5. After that the 4+ bucket missed 0.6% (2/336) over the next 25 hours and 0% (0/213) on the
full following day; the in-burst median fell from 302 ms to 111 ms. Of the four remaining
misses two were an encoding error rather than latency and two were timeouts at zero concurrency.
Re-run the same query weekly; the 4+ bucket is the number to watch.

## Query length (measured 2026-09-23)

The rest of the misses came from the other end: the query itself. Encode time on CPU is linear in
query length, and nothing capped it, so a pasted document or a long report arriving as a prompt was
embedded in full - 20 words 0.38 s, 100 words 1.08 s, 300 words 2.8 s, 800 words 10.3 s, 2000 words
30 s, on an idle 24-core box. Two failures fall out of that. The client gives up after
`BRAIN_SEARCHD_TIMEOUT` and loses its dense half; and since the server is single-threaded, the
encode it abandoned keeps running, so every other session's query waits behind a query nobody is
waiting for any more. One 24-hour window on the author's machine: 29 such timeouts, each 1.5 s, all
of them long prompts, with the database side of the same queries answering in 8 ms.

The daemon now caps a query at `BRAIN_EMB_MAX_TOKENS` (192, applied as the model's `max_seq_length`)
and `BRAIN_Q_MAX_CHARS` (1500); `brain_recall.py` cuts at `BRAIN_DENSE_Q_MAX` (1500) before the call,
so a 15 KB query never travels. All five lengths above then answer in 0.35-0.73 s. A query is a
question, not a document: 192 tokens is roughly 130 words, and on two gold sets whose queries average
15.7 words, hit@1, hit@3 and MRR were identical before and after. Raise the cap if your prompts are
genuinely long and you have the CPU for it - and measure the miss rate afterwards, not before. The
daemon reads both values at startup, so restart it after a change.
