#!/usr/bin/env python3
"""brain_recall_print.py - renders the AUTO-RECALL block that hooks/_auto_retrieve.sh injects into the prompt.

stdin: the JSON list produced by brain_recall.py. stdout: the text block. Everything else is env:
  RECALL_PROMPT_WORDS  word count of the prompt (the "no note on this" line needs a real question, >= 6 words)
  RECALL_PROMPT_TEXT   the prompt itself (hashed for the docs-topic marker; also tokenised for the repeat filter)
  RECALL_INSTANCE      instance name, if the install has one (marker file name)
  RECALL_SESSION_ID    this session's id, from the hook payload - scopes the "already shown" list
  RECALL_TRANSCRIPT    this session's transcript path, from the hook payload - a compact there resets that list
  BRAIN_ROOT, BRAIN_DIR, BRAIN_WIKI_DIR / BRAIN_WIKI_DIRS, BRAIN_MEMORY2, BRAIN_DENSE_MIN as in the hook
  BRAIN_RECALL_REPEAT_FILTER  0 (default since 1.2.0): every hit is printed every time; 1 turns the repeat filter on

Why a separate file (7 Sep 2026): this used to live inside the hook as a single-quoted `python3 -c '...'` block.
One apostrophe in a comment broke the quoting, the hook errored, and because it is a global UserPromptSubmit hook
every session on the machine got "A hook blocked your prompt" until it was fixed. A script file has no quoting class
to get wrong, and a Python error here is swallowed (recall must never break a session)."""
import sys, json, os, re, time, hashlib, subprocess

# ---- Repeat filter (23 Sep 2026). Measured over 1529 prompt/read pairs on the author's install: a note that
# was already shown earlier in the same session, carries only the FAIR tier and shares no word with the prompt
# was read afterwards 1.2% of the time against a 6.2% baseline - 339 lines, 22% of everything recall printed,
# for four of the 95 notes that were actually opened. A handover-style note (hub, handoff, closing, compact)
# that has never been opened is the same case: 171 lines, 3.5%. Both are dropped on the second showing, so a
# note still gets its one chance per session. Shared-docs hits are never filtered - they are the trust anchor.
# 1.2.0, three changes. (1) The filter is off unless BRAIN_RECALL_REPEAT_FILTER=1: the first version did not know
# about compaction, and on the author's install a session that kept one id through 25 compactions lost notes the
# model no longer had in context (full recall blocks on prompts of 6+ words fell from 80% to 43%). (2) It is off
# without a session id: scripts/brain-search has none, so every manual search shared one state file and a repeated
# search came back empty (the first call printed hits, the next 5 of 5 printed nothing). (3) When it is on, the list
# is reset whenever a compact boundary shows up in the transcript since the last prompt, so "already shown" means
# "shown since the last compact". The state (seen2_<instance>_<session>.json) is not written while the filter is off.
_TR = str.maketrans("çğıöşüâîûÇĞİÖŞÜ", "cgiosuaiuCGIOSU")   # de-accent, same map as brain_bm25
_WORD = re.compile(r"[a-z0-9]+")
HUB_RX = re.compile(r"hub|handoff|handover|closing|compact")  # names of notes that summarise instead of deciding


def toks(text):
    return {w for w in _WORD.findall((text or "").translate(_TR).lower()) if len(w) >= 3}


def name_toks(name):
    return toks((name or "").replace("-", " ").replace("_", " "))


def state_dir():
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude")), "brain-kit-state")


def marker_path():
    """Docs-topic marker for the optional Stop gate; the hook removes the same path when it skips a prompt."""
    return os.path.join(state_dir(), "wiki_topic." + (os.environ.get("RECALL_INSTANCE") or "default"))


def _sid():
    return re.sub(r"[^A-Za-z0-9_-]", "", os.environ.get("RECALL_SESSION_ID", "") or "")[:64]


def _filter_on():
    return os.environ.get("BRAIN_RECALL_REPEAT_FILTER", "0") == "1" and bool(_sid())


def _seen_file():
    """The per-session "already shown" list. Keyed by instance and session id so two sessions of the same
    instance, and two instances sharing a machine, never filter each other's lines."""
    inst = re.sub(r"[^A-Za-z0-9_-]", "", os.environ.get("RECALL_INSTANCE", "") or "")[:32] or "default"
    return os.path.join(state_dir(), "seen2_%s_%s.json" % (inst, _sid()))


_COMPACT_MARK = b'"subtype":"compact_boundary"'


def _compacted(st):
    """Has the session compacted since the last prompt? The state keeps the transcript path and the byte offset
    read so far, and only the new bytes are scanned. A missing, different or shorter transcript counts as a reset."""
    tp = os.environ.get("RECALL_TRANSCRIPT", "")
    try:
        size = os.path.getsize(tp) if tp else -1
    except OSError:
        size = -1
    old_tp, off = st.get("tp"), int(st.get("off", 0) or 0)
    st["tp"], st["off"] = tp, max(size, 0)
    if size < 0 or old_tp != tp or size < off:
        return old_tp is not None
    with open(tp, "rb") as fh:
        fh.seek(max(off - len(_COMPACT_MARK), 0))
        return _COMPACT_MARK in fh.read(size - off + len(_COMPACT_MARK))


def _load_seen():
    st = _load_json(_seen_file(), {})
    if not isinstance(st.get("notes"), dict):
        st = {"notes": {}}
    try:
        if _compacted(st):
            st["notes"] = {}
    except Exception:
        st["notes"] = {}
    return st


def _load_json(p, default):
    try:
        with open(p) as fh:
            v = json.load(fh)
        return v if isinstance(v, dict) else default
    except Exception:
        return default


def _sweep_seen():
    """Drop seen-lists older than two days. A session ends without telling anyone, so nothing else would."""
    try:
        cut = time.time() - 2 * 86400
        d = state_dir()
        for f in os.listdir(d):
            if f.startswith(("seen_", "seen2_")) and f.endswith(".json") and os.path.getmtime(os.path.join(d, f)) < cut:
                os.remove(os.path.join(d, f))
    except Exception:
        pass


def main():
    try:
        r = json.load(sys.stdin)
    except Exception:
        r = []
    if not r:
        if int(os.environ.get("RECALL_PROMPT_WORDS", "0") or 0) >= 6:
            # 1.2.0: this line used to say "treat this as NOT KNOWN". No match for the sentence is not the absence of a
            # record: a project scope, a wording in another language or a note split into sections all lose the match.
            bs = os.path.join(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")), "scripts", "brain-search")
            print("AUTO-RECALL: no note matched this sentence - no match is not the same as no record. Search by the "
                  "concrete name (rule, file, PR, device): `%s \"<name>\"`, and open what it finds before any "
                  "'not recorded / does not exist' verdict." % bs)
        return
    DM = float(os.environ.get("BRAIN_DENSE_MIN", "0.62") or 0.62)

    def tier(x):
        s = str(x.get("score", ""))
        return "STRONG" if s.endswith("bd") or (x.get("cos") is not None and float(x["cos"]) >= DM) else "FAIR"

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

    # Trust order: DOCS -> CODE -> RECORD (notes/memory). Nobody labels at write time; the reader sees it here.
    # 2026-09-10: the notes block used to be labelled UNVERIFIED and got skipped; a "nothing is written about this"
    # verdict was then given while the note that answered the question sat in the list. RECORD says what it is for.
    docs = [x for x in r if is_wiki(x.get("root"))]
    rest = [x for x in r if not is_wiki(x.get("root"))]
    # Repeat filter (see the module header). A note survives its first showing in a session unconditionally;
    # from the second on it is dropped when it is FAIR and shares no word with the prompt, or when it reads
    # like a handover note and has never been opened. Usage counts come from hooks/recall-usage-count.sh.
    on = _filter_on()                       # off by default and without a session id; state only while on
    st = _load_seen() if on else {"notes": {}}
    seen = st["notes"]
    if on:
        use = _load_json(os.path.join(vault, ".index", "recall_counts.json"), {})
        ptoks = toks(os.environ.get("RECALL_PROMPT_TEXT", ""))

        def _drop(x):
            nm = x.get("note", "")
            if int(seen.get(nm, 0) or 0) < 1:
                return False                      # first time this session: always print
            if tier(x) == "FAIR" and not (ptoks & name_toks(nm)):
                return True
            e = use.get(os.path.basename(x.get("path", "")) or nm)
            c = e.get("c", 0) if isinstance(e, dict) else int(e or 0)
            return bool(HUB_RX.search((nm or "").translate(_TR).lower())) and not c

        rest = [x for x in rest if not _drop(x)]
    if not docs and not rest:
        # Everything was filtered: print nothing at all. The "no matching note" line is not printed either -
        # notes did match, they were just shown a moment ago, and saying otherwise would be a lie the model
        # would act on. The docs marker is cleared as it would have been by a turn with no docs hit.
        try:
            if os.path.exists(marker_path()):
                os.remove(marker_path())
        except Exception:
            pass
        _sweep_seen()
        return
    tiers = [tier(x) for x in docs + rest]        # the count describes the lines actually printed
    print("AUTO-RECALL (closest to this message - trust order DOCS -> CODE -> RECORD(notes/memory); "
          "use it before re-deriving or reverse-engineering anything) - confidence: %d strong, %d fair"
          " - score: d=cosine, b=BM25 ratio, bd=RRF%s:" % (
              tiers.count("STRONG"), tiers.count("FAIR"),
              "" if dense_ok else " - dense engine did not answer (BM25 only; check brain_searchd on 8799)"))
    # Docs-topic marker: a real (not pulled) docs hit means this prompt is about the documented system. A Stop hook can
    # read the marker and refuse to end the turn until a doc was actually opened. Written as a hash of the prompt so the
    # gate can match it to the same turn; removed when the topic moves on. Optional - nothing else depends on it.
    try:
        pr = os.environ.get("RECALL_PROMPT_TEXT", "")
        os.makedirs(state_dir(), exist_ok=True)
        mk = marker_path()
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
            x["path"] = wiki_path(x["root"], x["path"].split("/", 1)[1] if "/" in x["path"] else x["path"])
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
        print("  SOURCE (shared docs): no match - if this is a how-does-it-work question, find the doc and open the code.")
    if rest:
        print("  RECORD (notes/memory/decisions - the SOURCE for decisions and history: no 'nothing written / not recorded' verdict before these are opened; for how the system behaves, verify against the code):")
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
    # 23 Sep 2026: the usage counter used to be written here, and it counted the wrong event. Every note this
    # renderer printed was scored as "used", so a note that recall kept surfacing and the model kept ignoring
    # climbed the ranking on the strength of being ignored often. Measured: notes at the counter's cap were
    # 71.7% of all injections and were opened 5.4% of the time, against 8.3% for notes below the cap. The
    # counter now lives in hooks/recall-usage-count.sh (PostToolUse on Read) and counts notes the model
    # actually opened; brain_bm25's multiplier is unchanged, only its input is. What is written here is the
    # per-session "already shown" list the repeat filter above reads - in the state dir, not in the vault.
    if on:
        try:
            for x in rest:
                nm = x.get("note", "")
                if nm:
                    seen[nm] = int(seen.get(nm, 0) or 0) + 1
            os.makedirs(state_dir(), exist_ok=True)
            tmp = _seen_file() + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(st, fh, ensure_ascii=False)
            os.replace(tmp, _seen_file())
        except Exception:
            pass
    _sweep_seen()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
