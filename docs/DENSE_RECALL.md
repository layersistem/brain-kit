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
re-measure on yours with `ml/brain_eval`-style gold pairs before changing them.

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
