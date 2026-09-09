#!/usr/bin/env python3
"""brain_recall_print.py - renders the AUTO-RECALL block that hooks/_auto_retrieve.sh injects into the prompt.

stdin: the JSON list produced by brain_recall.py. stdout: the text block. Everything else is env:
  RECALL_PROMPT_WORDS  word count of the prompt (the "no note on this" line needs a real question, >= 6 words)
  RECALL_PROMPT_TEXT   the prompt itself (only hashed, for the docs-topic marker below)
  RECALL_INSTANCE      instance name, if the install has one (marker file name)
  BRAIN_ROOT, BRAIN_DIR, BRAIN_WIKI_DIR / BRAIN_WIKI_DIRS, BRAIN_MEMORY2, BRAIN_DENSE_MIN as in the hook

Why a separate file (7 Sep 2026): this used to live inside the hook as a single-quoted `python3 -c '...'` block.
One apostrophe in a comment broke the quoting, the hook errored, and because it is a global UserPromptSubmit hook
every session on the machine got "A hook blocked your prompt" until it was fixed. A script file has no quoting class
to get wrong, and a Python error here is swallowed (recall must never break a session)."""
import sys, json, os, re, time, hashlib, subprocess


def main():
    try:
        r = json.load(sys.stdin)
    except Exception:
        r = []
    if not r:
        if int(os.environ.get("RECALL_PROMPT_WORDS", "0") or 0) >= 6:
            print("AUTO-RECALL: no matching note - treat this as NOT KNOWN: say so, label any guess as a hypothesis, do not invent; ask if it matters.")
        return
    DM = float(os.environ.get("BRAIN_DENSE_MIN", "0.62") or 0.62)

    def tier(x):
        s = str(x.get("score", ""))
        return "STRONG" if s.endswith("bd") or (x.get("cos") is not None and float(x["cos"]) >= DM) else "FAIR"

    tiers = [tier(x) for x in r]
    # Dense-daemon health read off the results: no "d" tag anywhere means the dense side never answered this turn.
    dense_ok = any("d" in str(x.get("score", "")) or x.get("dense_answered") for x in r)
    root = os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain"))
    vault = os.environ.get("BRAIN_DIR") or os.path.join(root, "vault")
    # Docs roots (scripts/brain_wiki.py): a hit carries its root tag (wiki, wiki2, ...); the tag resolves to the real path.
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import brain_wiki as bw
        has_docs, is_wiki, wiki_path = bool(bw.ROOTS), bw.is_wiki, bw.resolve
    except Exception:  # a docs-root problem must not take recall down with it
        has_docs, is_wiki, wiki_path = False, (lambda t: str(t).startswith("wiki")), (lambda t, n: f"{t}/{n}")

    # Trust order: DOCS -> CODE -> everything else UNVERIFIED. Nobody labels at write time; the reader sees it here.
    docs = [x for x in r if is_wiki(x.get("root"))]
    rest = [x for x in r if not is_wiki(x.get("root"))]
    print("AUTO-RECALL (closest to this message - trust order DOCS -> CODE -> everything else UNVERIFIED; "
          "use it before re-deriving or reverse-engineering anything) - confidence: %d strong, %d fair%s:" % (
              tiers.count("STRONG"), tiers.count("FAIR"),
              "" if dense_ok else " - dense engine did not answer (BM25 only; check brain_searchd on 8799)"))
    # Docs-topic marker: a real (not pulled) docs hit means this prompt is about the documented system. A Stop hook can
    # read the marker and refuse to end the turn until a doc was actually opened. Written as a hash of the prompt so the
    # gate can match it to the same turn; removed when the topic moves on. Optional - nothing else depends on it.
    try:
        pr = os.environ.get("RECALL_PROMPT_TEXT", "")
        state = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "brain-kit-state")
        os.makedirs(state, exist_ok=True)
        mk = os.path.join(state, "wiki_topic." + (os.environ.get("RECALL_INSTANCE") or "default"))
        if any(not x.get("wiki_pull") for x in docs) and pr:
            open(mk, "w").write(hashlib.sha256(pr.encode("utf-8")).hexdigest()[:16])
        elif os.path.exists(mk):
            os.remove(mk)
    except Exception:
        pass
    if docs:
        print("  SOURCE (shared docs - Read the path; a claim about how the system works is built from here and from the code):")
        for x in docs:
            h = (x.get("heading") or "").strip()
            x["path"] = wiki_path(x["root"], os.path.basename(x["path"]))
            tag = " (low score, surfaced by docs-priority)" if x.get("wiki_pull") else ""
            print("  %s [%s] %s:%s%s%s  (%s)" % (tier(x), x["score"], x["root"], x["note"], (" > " + h) if h else "", tag, x["path"]))
            hint = (x.get("hint") or "").strip()
            if hint:
                print("      what: " + hint[:130])
            tx = " ".join((x.get("text") or "").split())[:200]
            if tx:
                print("      " + tx)
            paths = []
            for m in re.findall(r"[\w./-]+\.(?:py|sh|sql|js|jsx|ts|go|rs|yml|yaml|toml)\b", (x.get("hint") or "") + " " + (x.get("text") or "")):
                m = m.lstrip("./")
                if m and m not in paths and ("/" in m or m.endswith((".py", ".sh"))):
                    paths.append(m)
            if paths:
                print("      code: " + " - ".join(paths[:5]) + "  (docs-to-code bridge: open before judging)")
    elif has_docs:
        print("  SOURCE (shared docs): no match - if this is a how-does-it-work question, find the doc and open the code; the notes below are not a source for that.")
    if rest:
        print("  UNVERIFIED (notes/memory/inference - valid for decisions and history; not a source for how the system behaves until checked against the code):")
    for x in rest:
        t = tier(x)
        h = (x.get("heading") or "").strip()
        line = "  %s [%s] %s:%s" % (t, x["score"], x["root"], x["note"])
        if h:
            line += " > " + h
        print(line + "  (" + x["path"] + ")")
        if t != "STRONG":  # diet: FAIR notes are title + address only
            continue
        hint = (x.get("hint") or "").strip()
        if hint:
            print("      what: " + hint[:130])
        tx = " ".join(x.get("text", "").split())[:200]
        if tx:
            print("      " + tx)
    # Belief layer (optional): active beliefs tied to the surfaced notes; silent if .index/beliefs.db was never built.
    try:
        o = subprocess.run([sys.executable, os.path.join(root, "scripts", "beliefs_recall.py")] + [x.get("path", "") for x in rest],
                           capture_output=True, text=True, timeout=1.5).stdout
        if o.strip():
            print(o.rstrip())
    except Exception:
        pass
    # Usage reinforcement: count surfaced notes into <vault>/.index/recall_counts.json; brain_bm25 reads it as a small boost.
    try:
        cf = os.path.join(vault, ".index", "recall_counts.json")
        try:
            c = json.load(open(cf))
        except Exception:
            c = {}
        for x in rest:
            b = os.path.basename(x.get("path", ""))
            if not b:
                continue
            e = c.get(b) or {"c": 0}
            if not isinstance(e, dict):
                e = {"c": int(e)}
            e["c"] = e.get("c", 0) + 1
            e["ts"] = int(time.time())
            c[b] = e
        json.dump(c, open(cf, "w"), ensure_ascii=False)
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
