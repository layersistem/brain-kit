#!/usr/bin/env python3
"""What your sessions cost, per project, read from the agent's own transcripts.

Usage: usage_report.py [START_UTC] [END_UTC]     ISO, e.g. 2026-09-19T21:00:00Z
                                                 default: today 00:00 local time -> now

Source: <agent-config-dir>/projects/*/*.jsonl - the transcript Claude Code writes as it goes. Every
assistant message carries a `usage` block; this sums it.

Two things make a naive sum wrong, both measured the hard way (docs/DISCIPLINE.md 9):

* One API response lands in the transcript as one line *per content block*, and every one of those
  lines repeats the same `message.id` and the same `usage`. Counting lines inflates the bill - 1.85x
  to 2.6x on our own transcripts. Here a call is a distinct `message.id` (falling back to `uuid`).
* Context per call is input + cache_read + cache_creation. Cache reads are most of it once a session
  is warm, so leaving them out makes a long session look free.

The "equiv" column weighs the four token kinds by their list-price ratios (cache_read 0.1,
cache_create 1.25, input 1, output 5) to get one comparable number. It is not anyone's billing
formula - it exists so you can rank projects and days against each other.
"""
import glob
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone

CFG = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
# A "user turn" means a human typed something. These prefixes are the machinery that arrives through
# the same channel: hook output, injected reminders, slash-command echoes, harness notifications.
MACHINE = re.compile(
    r"^(<system-reminder>|<command-name|<local-command|<task-notification|\[Request interrupted"
    r"|\[SYSTEM NOTIFICATION|Stop hook|Caveat: |This session is being continued"
    r"|Base directory for this skill)"
)


def parse_when(arg, fallback):
    if not arg:
        return fallback
    return datetime.fromisoformat(arg.replace("Z", "+00:00")).astimezone(timezone.utc)


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""


def collect(start, end):
    rows = defaultdict(lambda: defaultdict(float))
    models = defaultdict(lambda: defaultdict(int))
    for path in glob.glob(os.path.join(CFG, "projects", "*", "*.jsonl")):
        if os.path.getmtime(path) < start.timestamp():
            continue                                   # file untouched since the window opened
        project = os.path.basename(os.path.dirname(path))
        seen = set()
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                stamp = rec.get("timestamp")
                if not stamp:
                    continue
                when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                if not (start <= when < end):
                    continue
                msg = rec.get("message") or {}
                if rec.get("type") == "user":
                    body = text_of(msg.get("content")).strip()
                    if body and not MACHINE.match(body) and not rec.get("isSidechain"):
                        rows[project]["user_turns"] += 1
                    continue
                usage = msg.get("usage")
                if rec.get("type") != "assistant" or not usage:
                    continue
                key = msg.get("id") or rec.get("uuid")   # one response, many lines, one id
                if key in seen:
                    continue
                seen.add(key)
                row = rows[project]
                row["calls"] += 1
                row["sub"] += 1 if rec.get("isSidechain") else 0
                for name, field in (("input", "input_tokens"),
                                    ("cread", "cache_read_input_tokens"),
                                    ("ccreate", "cache_creation_input_tokens"),
                                    ("output", "output_tokens")):
                    row[name] += usage.get(field) or 0
                models[project][(msg.get("model") or "?").replace("claude-", "")] += 1
    return rows, models


def equivalent(row):
    return row["cread"] * 0.1 + row["ccreate"] * 1.25 + row["input"] + row["output"] * 5


def main():
    now = datetime.now(timezone.utc)
    midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    start = parse_when(sys.argv[1] if len(sys.argv) > 1 else None, midnight.astimezone(timezone.utc))
    end = parse_when(sys.argv[2] if len(sys.argv) > 2 else None, now)
    rows, models = collect(start, end)

    def m(x):
        return f"{x / 1e6:8.1f}M"

    local = datetime.now().astimezone().tzinfo
    print(f"window: {start.astimezone(local):%d %b %H:%M} -> {end.astimezone(local):%d %b %H:%M}"
          f" ({datetime.now().astimezone():%Z})")
    print(f"{'project':<30}{'calls':>6}{'sub':>5}{'user':>6}{'ctx/call':>10}"
          f"{'cache_read':>11}{'c_create':>10}{'input':>10}{'output':>10}{'equiv':>10}  models")
    total = defaultdict(float)
    for project, row in sorted(rows.items(), key=lambda kv: -equivalent(kv[1])):
        if not row["calls"]:
            continue
        ctx = (row["input"] + row["cread"] + row["ccreate"]) / row["calls"]
        names = ",".join(f"{k}:{v}" for k, v in sorted(models[project].items(), key=lambda kv: -kv[1]))
        print(f"{project[:29]:<30}{int(row['calls']):>6}{int(row['sub']):>5}{int(row['user_turns']):>6}"
              f"{ctx / 1e3:>9.0f}k{m(row['cread'])}{m(row['ccreate'])}{m(row['input'])}"
              f"{m(row['output'])}{m(equivalent(row))}  {names}")
        for key, value in row.items():
            total[key] += value
    if total["calls"]:
        ctx = (total["input"] + total["cread"] + total["ccreate"]) / total["calls"]
        print(f"{'TOTAL':<30}{int(total['calls']):>6}{int(total['sub']):>5}{int(total['user_turns']):>6}"
              f"{ctx / 1e3:>9.0f}k{m(total['cread'])}{m(total['ccreate'])}{m(total['input'])}"
              f"{m(total['output'])}{m(equivalent(total))}")
    else:
        print("(no assistant messages in this window)")


if __name__ == "__main__":
    main()
