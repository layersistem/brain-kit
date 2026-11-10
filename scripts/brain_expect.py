#!/usr/bin/env python3
"""brain_expect - counts the expectation lines in this instance's focus file and decision records (issue #18).

An expectation is written before the outcome is known, next to the work, and closed on the same line once it is:

  open     @expect YYYY-MM-DD[ HH:MM] <what I expect to happen> · measure: <how it will show> · written: YYYY-MM-DD
  closed   @expect✓ held: <what happened>  |  @expect✗ missed: <what happened>  |  @expect✓ void: <why it no longer applies>

With BRAIN_EXPECT=1, hooks/due-inject.sh brings an open line back on its date and hooks/postwrite-check.sh reminds a
write that reads like a prediction and carries none. This script only reads: it prints how many lines are open (and
how many of those are past their date), held, missed and void, and the hit rate held / (held + missed); void counts in
neither. Lines inside fenced code blocks and inside inline backticks are format examples, not expectations, and are
not counted.

  brain_expect.py [--instance NAME] [--open] [--closed]
    --open     every open line, oldest date first (default: the five oldest)
    --closed   every closed line, missed first, then held, then void

Scope is the one due-inject.sh scans: focus/_FOCUS_<instance>.txt and the decision records whose first 8 lines carry
`instance: <instance>`. Instance: --instance, else BRAIN_INSTANCE, else the nearest .brain-instance above the project
dir (CLAUDE_PROJECT_DIR or the current dir), else <vault>/.brain-instance, else `main`. Nothing here writes the vault
or the belief ledger; a missed expectation is a candidate `falsified` entry there (docs/BELIEFS.md), written by you.
Standard library only. Env: BRAIN_ROOT . BRAIN_DIR . BRAIN_INSTANCE"""
import argparse, datetime, glob, os, re, sys

BRAIN_ROOT = os.path.expanduser(os.environ.get("BRAIN_ROOT", "~/brain"))
VAULT = os.path.expanduser(os.environ.get("BRAIN_DIR") or os.path.join(BRAIN_ROOT, "vault"))
MARK_RX = re.compile(r"@expect(✓|✗| (?=\d{4}-\d{2}-\d{2}))")
OPEN_RX = re.compile(r"^(\d{4}-\d{2}-\d{2})(?: (\d\d:\d\d))?\s*(.*)$")
TICK_RX = re.compile(r"`[^`]*`")
DATE_RX = re.compile(r"^\d{4}-\d{2}-\d{2}(?: \d\d:\d\d)?\s*")
ORDER = {"missed": 0, "held": 1, "void": 2}


def instance(arg):
    if arg:
        return arg
    if os.environ.get("BRAIN_INSTANCE"):
        return os.environ["BRAIN_INSTANCE"]
    d = os.path.abspath(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    for f in [os.path.join(p, ".brain-instance") for p in _parents(d)] + [os.path.join(VAULT, ".brain-instance")]:
        try:
            name = "".join(open(f, encoding="utf-8").readline().split())
        except OSError:
            continue
        if name:
            return name
    return "main"


def _parents(d):
    while d and d != os.path.dirname(d):
        yield d
        d = os.path.dirname(d)


def files(inst):
    out = [p for p in [os.path.join(VAULT, "focus", f"_FOCUS_{inst}.txt")] if os.path.isfile(p)]
    own = re.compile(rf"^instance: *{re.escape(inst)} *$")
    for p in sorted(glob.glob(os.path.join(VAULT, "decision", "*.md"))):
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                head = [next(fh, "") for _ in range(8)]
        except OSError:
            continue
        if any(own.match(h.rstrip("\n")) for h in head):
            out.append(p)
    return out


def scan(path):
    """(state, date or None, text, line number) for every expectation in the file, examples left out."""
    found, fence = [], False
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        return found
    for no, raw in enumerate(lines, 1):
        if raw.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence or "@expect" not in raw:
            continue
        # a marker inside an inline code span is an example; the spans are blanked to find the markers, and the text
        # is cut from the line as written, so a measure written as code (`make check`) is still shown
        s = TICK_RX.sub(lambda t: " " * len(t.group()), raw)
        marks = list(MARK_RX.finditer(s))
        for i, m in enumerate(marks):
            body = raw[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(raw)].strip()
            if m.group(1) in ("✓", "✗"):
                body = DATE_RX.sub("", body)   # a line closed with its date kept: `@expect✓ 2026-11-13 held: ...`
                st = "missed" if m.group(1) == "✗" else "void" if body.lower().startswith("void") else "held"
                found.append((st, None, body, no))
            else:
                o = OPEN_RX.match(body)
                if o:
                    found.append(("open", o.group(1), o.group(3), no))
    return found


def main():
    ap = argparse.ArgumentParser(description="Count expectation lines (read-only).")
    ap.add_argument("--instance")
    ap.add_argument("--open", action="store_true", help="list every open line")
    ap.add_argument("--closed", action="store_true", help="list every closed line, missed first")
    a = ap.parse_args()
    inst = instance(a.instance)
    today = datetime.date.today().isoformat()
    rows = []
    for p in files(inst):
        rows += [(st, d, t, os.path.relpath(p, VAULT), no) for st, d, t, no in scan(p)]
    n = {k: sum(1 for r in rows if r[0] == k) for k in ("open", "held", "missed", "void")}
    opened = sorted([r for r in rows if r[0] == "open"], key=lambda r: (r[1], r[3], r[4]))
    past = sum(1 for r in opened if r[1] < today)
    closed = n["held"] + n["missed"]
    rate = f"{n['held']}/{closed} = {round(100 * n['held'] / closed)}%" if closed else "nothing closed yet"
    print(f"expectations ({inst}) - {datetime.datetime.now():%Y-%m-%d %H:%M}")
    print(f"open {n['open']} (past their date {past}) · held {n['held']} · missed {n['missed']} · void {n['void']}"
          f" · hit rate {rate}")
    shown = opened if a.open else opened[:5]
    if shown:
        print("open lines" + ("" if a.open else " (oldest 5)") + ":")
        for _, d, t, p, no in shown:
            print(f"  {'!' if d <= today else ' '} {d} {t[:110]}  ({p}:{no})")
    if a.closed:
        done = sorted([r for r in rows if r[0] in ORDER], key=lambda r: (ORDER[r[0]], r[3], r[4]))
        print("closed lines (missed first):" if done else "no closed lines")
        for st, _, t, p, no in done:
            t = re.sub(r"^(held|missed|void)\b\s*:?\s*", "", t, flags=re.I)
            print(f"  {st}: {t[:110]}  ({p}:{no})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
