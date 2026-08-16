#!/usr/bin/env python3
"""brain_consolidate - the nightly consolidation pass (proposal only).

Collects the decision records written in a window, finds each one's older BM25 neighbours
(supersede candidates) and writes a prompt to <vault>/_drafts/consolidation_<until>_prompt.md.
Default mode is PROMPT-ONLY: hand that file to an in-session agent, or pass --llm to run a
headless CLI. Either way the output is a PROPOSAL - a human decides what gets applied.

Usage: brain_consolidate.py [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--llm]
       brain_consolidate.py --verify <report.md>
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_CONSOLIDATE_CMD (default: claude -p)
Kill switch: <root>/.brain-loop.disabled
"""
import sys, os, re, subprocess, datetime, pathlib, argparse
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from distill_lock import acquire, release, kill_active, log_event, budget_left, note_call
import consolidate_prompt as P
import brain_bm25 as bm

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
DEC, DRAFTS = VAULT / "decision", VAULT / "_drafts"
BODY_CAP, TOTAL_CAP, NEIGH_K = 3200, 60000, 6
SECTIONS = ("## 1. DISTILL", "## 2. SUPERSEDE", "## 3. CONFLICT", "## 4. WEIGHT", "## 5. SKILL")


def _fm(text):
    """frontmatter -> (dict of flat key: value, index where the body starts)."""
    d, end = {}, 0
    if text.startswith("---"):
        e = text.find("\n---", 3)
        if e != -1:
            end = e + 4
            for m in re.finditer(r"(?m)^(\w[\w-]*):[ \t]*(.+)$", text[3:e]):
                d[m.group(1).lower()] = m.group(2).strip().strip('"')
    return d, end

def _date_of(p, meta):
    m = re.match(r"\d{4}-\d{2}-\d{2}", meta.get("date") or "") or re.search(r"(\d{4}-\d{2}-\d{2})", p.name)
    return m.group(0) if m else ""


def _notes():
    return {p.stem: p for p in VAULT.rglob("*.md") if "_drafts" not in p.parts}


def collect(since, until):
    items = []
    for p in sorted(DEC.glob("*.md")):
        text = p.read_text(errors="ignore"); meta, end = _fm(text)
        d = _date_of(p, meta)
        if not d or not (since <= d <= until):
            continue
        body = text[end:]
        heads = [h.strip("# ").strip() for h in re.findall(r"(?m)^#{1,3} .+$", body)]
        items.append({"note": p.stem, "path": p, "meta": meta, "date": d, "headings": heads,
                      "body": " ".join(body.split())[:BODY_CAP], "neighbors": []})
    return items


def neighbors(it, since, notes):
    """Older notes on the same topic (written before the window, not already superseded)."""
    q = it["meta"].get("topic") or " ".join(it["headings"][:3]) or it["note"]
    out = []
    try:
        for r in bm.search(q, k=NEIGH_K + 4):
            src = notes.get(r["note"])
            if r["note"] == it["note"] or r["root"] != "vault" or not src:
                continue
            m2, _ = _fm(src.read_text(errors="ignore")); d2 = _date_of(src, m2)
            if d2 and d2 >= since:
                continue                     # inside the window or newer -> not a candidate
            out.append((r["note"], r["score"], r["heading"]))
            if len(out) >= NEIGH_K:
                break
    except Exception as e:
        log_event("neighbour-fail", note=it["note"], err=str(e)[:120])
    return out


def build_prompt(since, until):
    items = collect(since, until)
    if not items:
        return None, []
    notes = _notes()
    for it in items:
        it["neighbors"] = neighbors(it, since, notes)
    total = 0
    for it in items:                         # total cap: newest DR stays whole, older ones shrink
        total += len(it["body"])
        if total > TOTAL_CAP:
            it["body"] = it["body"][:800] + " ...[truncated]"
    return P.build(f"{since}..{until}", items, set(notes), P.observations(DRAFTS, since, until), P.previous_reports(DRAFTS, until)), items


def verify(report):
    """Machine gate: all four sections present and no wikilink pointing at a missing note."""
    fails = [s for s in SECTIONS if s not in report]
    valid = {p.stem for p in VAULT.rglob("*.md")}
    ghosts = sorted({l.strip() for l in re.findall(r"\[\[([^\]|#]+)", report) if l.strip() not in valid})
    if ghosts:
        fails.append("ghost-links: " + ", ".join(ghosts[:8]))
    return not fails, fails


def headless(prompt):
    """Optional --llm path. Uses whatever CLI BRAIN_CONSOLIDATE_CMD names; no model is hardcoded."""
    if not budget_left():
        log_event("abort", reason="daily-call-cap"); sys.exit(3)
    note_call()
    cmd = os.environ.get("BRAIN_CONSOLIDATE_CMD", "claude -p").split() + [prompt]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError("consolidation CLI rc=%s %s" % (r.returncode, (r.stderr or "")[:200]))
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since"); ap.add_argument("--until"); ap.add_argument("--llm", action="store_true")
    ap.add_argument("--verify", help="run a finished report through the gate (file path)")
    a = ap.parse_args()
    if a.verify:
        ok, fails = verify(pathlib.Path(a.verify).read_text())
        print("OK" if ok else "FAIL: " + "; ".join(fails)); sys.exit(0 if ok else 1)
    until = a.until or str(datetime.date.today())
    since = a.since or str(datetime.date.fromisoformat(until) - datetime.timedelta(days=1))
    if kill_active():
        log_event("skip", reason="kill-switch"); return
    if not acquire():
        log_event("skip", reason="locked"); return
    try:
        prompt, items = build_prompt(since, until)
        if not prompt:
            print("no decision records in window:", since, until); return
        DRAFTS.mkdir(parents=True, exist_ok=True)
        pp = DRAFTS / f"consolidation_{until}_prompt.md"; pp.write_text(prompt)
        log_event("prompt", since=since, until=until, n=len(items), chars=len(prompt))
        print(f"prompt: {pp} ({len(items)} DR, {len(prompt)} chars)")
        if a.llm:
            rep = headless(prompt); ok, fails = verify(rep)
            out = DRAFTS / f"consolidation_{until}.md"; out.write_text(rep)
            log_event("done" if ok else "verify-fail", out=out.name, fails=fails)
            print(out, "OK" if ok else fails)
    finally:
        release()


if __name__ == "__main__":
    main()
