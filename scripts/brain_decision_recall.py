#!/usr/bin/env python3
"""brain_decision_recall - decision-time recall, the body of hooks/decision-recall.sh (PreToolUse, Write|Edit).

Prompt recall (hooks/_auto_retrieve.sh) builds its query from what the user typed, and runs only when the user types.
The moment memory matters most, a decision record being written, happens in a tool turn where nothing recalls
anything, and the decision's own words ("cap the retry budget on the export job") rarely resemble the words of the
older lesson that argues against it ("we removed client-side throttling from the sync path"). When a Write or Edit
targets <vault>/decision/*.md this script prints two views into the model's context before the write lands:

  A TOPIC      the closest notes to the decision: the file name's slug plus the first 300 characters being written.
               The record being written is left out, and so are the notes that go to B.
  B OBJECTION  the notes from the same ranking that live under a research folder (BRAIN_DECISION_OBJECTION_DIRS,
               default "research digs"), so a strategic lesson or a piece of counter-evidence is not outranked by
               routine notes. When none rank, a second query adds lesson words (BRAIN_DECISION_WIDEN); when that
               finds nothing either, one line says that no match is not the same as no record.

Origin (author's install, October 2026): a decision was written while a research note that argued against it sat in
the vault. Prompt recall showed no strong note in that turn and never ran during the tool turns that followed.

Output: one JSON object with hookSpecificOutput.additionalContext, because PreToolUse does not pass plain stdout to
the model. There is no permission decision in it: the write goes through the user's normal permission flow. Any error
prints nothing. A line per firing goes to <agent-config-dir>/brain-kit-state/decision-recall.log (epoch|file|A|B|widened).
Usage: brain_decision_recall.py < hook-input.json"""
import json
import os
import pathlib
import re
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
K = 14                 # one ranking feeds both views; B needs depth, since research notes rarely rank in the top 5
A_MAX = B_MAX = 4
SNIP = 300
WIDEN_DEFAULT = "research lesson precedent abandoned rejected failed removed counter evidence"


def vault_dir():
    root = os.environ.get("BRAIN_ROOT") or os.path.expanduser("~/brain")
    return os.environ.get("BRAIN_DIR") or os.path.join(root, "vault")


def target(o):
    """(path, query) when the tool call writes a decision record, else None. Paths are compared after resolving
    symlinks, so a vault reached through a link or a mount point matches the BRAIN_DIR it is configured as."""
    ti = o.get("tool_input") or {}
    fp = ti.get("file_path") or ""
    if not fp.endswith(".md"):
        return None
    dec = os.path.realpath(os.path.join(vault_dir(), "decision"))
    real = os.path.realpath(fp)
    if not real.startswith(dec + os.sep):
        return None
    slug = re.sub(r"^DR-\d{4}-\d{2}-\d{2}-?", "", pathlib.Path(fp).stem)
    slug = re.sub(r"[-_]+", " ", slug).strip()
    text = (ti.get("content") or "") + " " + (ti.get("new_string") or "")
    snip = re.sub(r"\s+", " ", text).strip()[:SNIP]
    q = (slug + " " + snip).strip()
    return (real, q) if q else None


def where(r, bw):
    """A hit's readable path: vault and docs-root hits resolve to the real file; anything else keeps its tagged path."""
    p = r.get("path") or ""
    tag, _, rest = p.partition("/")
    if tag == "vault" and rest:
        return os.path.join(vault_dir(), rest)
    if bw is not None and bw.is_wiki(r.get("root")) and rest:
        try:
            return str(bw.resolve(r.get("root"), rest))
        except Exception:
            return p
    return p


def line(r, path):
    h = (r.get("heading") or "").strip()[:70]
    return "    [%s] %s%s  (%s)" % (r.get("score", "?"), r.get("note", "?"), (" > " + h) if h else "", path)


def main():
    try:
        o = json.load(sys.stdin)
    except Exception:
        return
    hit = target(o)
    if not hit:
        return
    real, q = hit
    sys.path.insert(0, str(HERE))
    import brain_recall as br                  # imported only for a decision write: every other Write/Edit stays cheap
    try:
        import brain_wiki as bw
    except Exception:
        bw = None
    dirs = os.environ.get("BRAIN_DECISION_OBJECTION_DIRS", "research digs").split()

    def objection(r):
        p = "/" + (r.get("path") or "")
        return any("/%s/" % d.strip("/") in p for d in dirs)

    def ranked(query):
        out = []
        for r in br.recall(query, K):
            p = where(r, bw)
            if os.path.realpath(p) != real:
                out.append((r, p))
        return out

    rows = ranked(q)
    a = [x for x in rows if not objection(x[0])][:A_MAX]
    b = [x for x in rows if objection(x[0])][:B_MAX]
    widened = 0
    if dirs and not b:
        widened = 1
        b = [x for x in ranked(q + " " + os.environ.get("BRAIN_DECISION_WIDEN", WIDEN_DEFAULT)) if objection(x[0])][:B_MAX]
    if not a and not b and not dirs:
        return                                 # objection view switched off and nothing on topic: nothing to say
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    root = os.environ.get("BRAIN_ROOT") or os.path.expanduser("~/brain")
    name = pathlib.Path(real).name
    out = ["DECISION-TIME RECALL - %s is being written. What the vault already holds on this decision (a title seen "
           "is not a note read: open the ones that bear on it, and if one argues against the decision, say so in "
           "the record):" % name]
    if a:
        out.append("  A TOPIC (closest notes):")
        out += [line(r, p) for r, p in a]
    if b:
        out.append("  B OBJECTION (%s - lessons and counter-evidence first):" % ", ".join(d.strip("/") + "/" for d in dirs))
        out += [line(r, p) for r, p in b]
    elif dirs:
        out.append("  B OBJECTION: nothing under %s matched - no match is not the same as no record. For a large "
                   "decision, search by the domain's own name: %s \"<name>\"" % (
                       ", ".join(d.strip("/") + "/" for d in dirs), os.path.join(root, "scripts", "brain-search")))
    out.append("  (off: touch %s)" % os.path.join(cfg, "brain-decision-recall.disabled"))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "additionalContext": "\n".join(out)}}, ensure_ascii=False))
    try:
        st = os.path.join(cfg, "brain-kit-state")
        os.makedirs(st, exist_ok=True)
        with open(os.path.join(st, "decision-recall.log"), "a") as f:
            f.write("%d|%s|%d|%d|%d\n" % (time.time(), name, len(a), len(b), widened))
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
