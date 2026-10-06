#!/usr/bin/env python3
"""brain_verdict - the verdict ledger: which notes were in front of the model when a correction came.

The kit's other importance signals say how a note was written (`weight:`) or how often it was opened (the usage
boost); none says whether it helped. A correction is the outcome signal, and hooks/salience-inject.sh already notices
it. With BRAIN_VERDICT=1 the hook calls `moment` here, which lists the notes recall showed and the notes the model
opened in the last turns, and asks for one row in a ledger note. Measured on the author's install over one week
(29 September to 5 October 2026): of 44 rows, 31 said the right note was already in context and the mistake happened
anyway, 2 that a note existed and recall did not show it, 0 that no note existed, 11 that the word was no correction.

  moment <transcript.jsonl> <signal> [n=3]  the hook's output: the time of the corrected prompt, for the last n turns
                     that showed or opened a note the notes shown (AUTO-RECALL lines) and opened (Read of a vault or
                     memory note, the same test as brain_usage_count.py), and the ledger row to add. Note names only.
  report [ledger]    counts derived from the ledger: rows per verdict and, for each note, the two counters kept apart -
                     rule load (`in-view`) and misses (`not-surfaced`). Rule load ranks the shelf candidates (at most 7)
                     for the RULES: line of the focus file; misses feed brain_bm25's capped boost. A verdict outside
                     the four values is listed as unrecognised and not counted.

Ledger: a markdown table, `| time | signal | prompt | in context | verdict | note |`, verdict one of in-view, no-record,
not-surfaced, not-a-correction. A row is corrected by changing its verdict cell, never deleted. Nothing here writes the
ledger or the focus file. Standard library only; every failure prints less, never raises into the hook.
Env: BRAIN_ROOT . BRAIN_DIR . BRAIN_VERDICT_LEDGER (default <vault>/knowledge/verdict-ledger.md) . BRAIN_VERDICT_PROMPT
     (the correcting prompt, so `moment` does not take it for the corrected one) . BRAIN_MEMORY / BRAIN_MEMORY2"""
import os, sys, re, json, datetime

BRAIN_ROOT = os.path.expanduser(os.environ.get("BRAIN_ROOT", "~/brain"))
VAULT = os.path.expanduser(os.environ.get("BRAIN_DIR") or os.path.join(BRAIN_ROOT, "vault"))
VERDICTS = ("in-view", "no-record", "not-surfaced", "not-a-correction")
HEADER = "| time | signal | prompt | in context | verdict | note |"
SHOWN_RX = re.compile(r"^\s*(?:STRONG|FAIR)\s+\[[^\]]*\]\s+[a-z0-9]+:(.+?)(?:\s+>\s+.*)?\s+\(([^()]*)\)\s*$")
# Prompts that are not the human talking: client bookkeeping and harness notifications (salience-inject.sh skips the same).
SKIP = ("<local-command", "<command-name", "<command-message", "<task-notification>", "<system-reminder>", "<bash-")
NOTIF_RX = re.compile(r"system notification - not user input|monitor event:", re.I)


def ledger_path():
    return os.environ.get("BRAIN_VERDICT_LEDGER") or os.path.join(VAULT, "knowledge", "verdict-ledger.md")


def _names(cell):
    out = []
    for k in re.split(r"\s*[·,;]\s*", cell or ""):
        k = k.strip().strip("`").replace("[[", "").replace("]]", "").strip()
        k = re.sub(r"\.md$", "", k.rsplit("/", 1)[-1])
        if k and k not in ("-", "—"):
            out.append(k)
    return out


def rows(path=None):
    """The ledger table -> (rows, unrecognised rows). Header and separator are skipped; `\\|` stays inside a cell."""
    good, bad = [], []
    try:
        lines = open(path or ledger_path(), encoding="utf-8").read().splitlines()
    except Exception:
        return good, bad
    for ln in lines:
        if not ln.startswith("|"):
            continue
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", ln.strip().strip("|"))]
        if len(cells) < 6 or set(cells[0]) <= set("-: ") or cells[0].lower() == "time":
            continue
        r = {"time": cells[0], "signal": cells[1], "prompt": cells[2], "verdict": cells[4].strip("` ").lower(),
             "notes": _names(cells[5])}
        (good if r["verdict"] in VERDICTS else bad).append(r)
    return good, bad


def counters(rs):
    """Per note: rule load (in-view) and misses (not-surfaced), never summed - one counter would rank both the same way."""
    per = {}
    for r in rs:
        for n in r["notes"]:
            c = per.setdefault(n, [0, 0])
            c[0] += r["verdict"] == "in-view"
            c[1] += r["verdict"] == "not-surfaced"
    return per


def boost_words(path=None):
    """{note: the prompt summaries of its `not-surfaced` rows}; brain_bm25 tokenises them with its own tokenizer."""
    m = {}
    for r in rows(path)[0]:
        if r["verdict"] == "not-surfaced":
            for n in r["notes"]:
                m[n] = (m.get(n, "") + " " + r["prompt"]).strip()
    return m


def _prompt(o):
    if o.get("type") != "user" or o.get("isSidechain") or o.get("isMeta"):
        return None
    org = o.get("origin")
    if isinstance(org, dict) and org.get("kind") not in (None, "human"):
        return None
    c = (o.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return None
        c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    s = " ".join(c.split()) if isinstance(c, str) else ""
    return None if not s or s.startswith(SKIP) or NOTIF_RX.search(s) else s


def turns(tp, tail=6_000_000):
    """Human turns from the transcript's last `tail` bytes: {prompt, ts, shown[], opened[]}."""
    try:
        from brain_usage_count import counted          # the usage counter's own vault/memory test
    except Exception:
        counted = lambda fp: False
    out, cur = [], None
    try:
        with open(tp, "rb") as fh:
            fh.seek(0, 2); fh.seek(max(0, fh.tell() - tail))
            data = fh.read().decode("utf-8", "replace")
    except Exception:
        return out
    for line in data.split("\n"):
        try:
            o = json.loads(line) if line.startswith("{") else None
        except Exception:
            o = None
        if not o:
            continue
        t, p = o.get("type"), _prompt(o)
        if p is not None:
            cur = {"prompt": p, "ts": o.get("timestamp", ""), "shown": [], "opened": []}
            out.append(cur)
        elif cur is not None and t == "attachment":
            a = o.get("attachment") or {}
            c = a.get("content") or a.get("stdout") or ""
            if a.get("hookEvent", a.get("hookName")) == "UserPromptSubmit" and isinstance(c, str) and "AUTO-RECALL" in c:
                for ln in c.split("\n"):
                    m = SHOWN_RX.match(ln)
                    n = m and re.sub(r"\s+\([^()]*\)$", "", m.group(1)).strip()
                    if n and n not in cur["shown"]:
                        cur["shown"].append(n)
        elif cur is not None and t == "assistant" and not o.get("isSidechain"):
            for b in (o.get("message") or {}).get("content") or []:
                if not (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Read"):
                    continue
                fp = str((b.get("input") or {}).get("file_path") or "")
                n = os.path.basename(fp)[:-3] if counted(fp) else ""
                if n and n not in cur["opened"]:
                    cur["opened"].append(n)
    return out


def _local(ts):
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M")
    except Exception:
        return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


def moment(tp, signal, n=3, maxlen=1400):
    ts = turns(tp) if tp else []
    cur = " ".join((os.environ.get("BRAIN_VERDICT_PROMPT") or "").split())[:600]
    if ts and cur and ts[-1]["prompt"][:600] == cur:
        ts = ts[:-1]                                   # the correction itself, already in the transcript
    when = _local(ts[-1]["ts"] if ts else "")
    ctx = [t for t in ts if t["shown"] or t["opened"]][-n:]
    parts = ['T-%d "%s": shown %s | opened %s' % (i, " ".join(t["prompt"].split()[:6]), " · ".join(t["shown"]) or "-",
                                                  " · ".join(t["opened"]) or "-") for i, t in enumerate(reversed(ctx), 1)]
    s = " ‖ ".join(parts) or "no note was shown or opened in the recent turns"
    s = s if len(s) <= maxlen else s[:maxlen - 1] + "…"
    lp = ledger_path()
    print("VERDICT: notes in context before this correction -> %s" % s)
    print("  -> add ONE row to %s%s:" % (lp, "" if os.path.exists(lp) else
          " (a new note: start its table with `%s` and `|---|---|---|---|---|---|`)" % HEADER))
    print("     | %s | %s | <what was corrected, at most 12 words> | <notes from the list above> | %s | <note name(s), or -> |"
          % (when, signal, " / ".join(VERDICTS)))
    print("     in-view = the note was in context and the mistake happened anyway; no-record = no note covered it (write "
          "the lesson note now, name it in the row); not-surfaced = a note existed and recall did not show it; "
          "not-a-correction = the word meant something else. Counts: python3 %s report"
          % os.path.join(BRAIN_ROOT, "scripts", "brain_verdict.py"))


def report(path=None):
    rs, bad = rows(path)
    per = counters(rs)
    print("verdict ledger: %s" % (path or ledger_path()))
    print("rows %d - %s - unrecognised %d" % (len(rs), " - ".join("%s %d" % (v, sum(r["verdict"] == v for r in rs))
                                                                  for v in VERDICTS), len(bad)))
    print("per note (rule load = in-view, misses = not-surfaced; kept apart):")
    print("  load  miss  note")
    for n, (ld, ms) in sorted(per.items(), key=lambda x: (-x[1][0], -x[1][1], x[0])):
        print("  %4d  %4d  %s" % (ld, ms, n))
    shelf = [n for n, c in sorted(per.items(), key=lambda x: (-x[1][0], x[0])) if c[0]][:7]
    print("shelf candidates (rule load, at most 7; one enters, one leaves) for the RULES: line of the focus file: %s"
          % (", ".join("%s (%d)" % (n, per[n][0]) for n in shelf) or "none"))
    print("notes with rule load 2 or more: %d" % sum(1 for c in per.values() if c[0] >= 2))
    for r in bad:
        print("  unrecognised verdict, not counted: %s | %s" % (r["time"], r["verdict"]))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["moment"] and len(a) >= 3:
        moment(a[1], a[2], int(a[3]) if len(a) > 3 and a[3].isdigit() else 3)
    elif a[:1] == ["report"]:
        report(a[1] if len(a) > 1 else None)
    else:
        print(__doc__)
        sys.exit(2)
