#!/usr/bin/env python3
"""brain_wiki - the shared docs roots recall indexes read-only next to the vault (one root or several).

Env:  BRAIN_WIKI_DIR         one docs root, tagged "wiki" (unchanged from single-root installs)
      BRAIN_WIKI_DIRS        further roots, ";"-separated, tagged "wiki2", "wiki3", ...
      BRAIN_WIKI_SCOPE_RX    visibility regex for BRAIN_WIKI_DIR, matched against the session's project slug
      BRAIN_WIKI_SCOPE_RXS   the parallel ";"-separated regexes for BRAIN_WIKI_DIRS; empty = every session
";" and not "|" or ":" because a scope value is a regex, where "|" is alternation and ":" occurs in groups.
Every root tag starts with "wiki", so the places that used to test `root == "wiki"` test is_wiki(root) and an
existing brain.db built from a single BRAIN_WIKI_DIR needs no rebuild. The engines that apply the scope:
brain_bm25 (file scan), brain_index_search (SQLite), brain_searchd (dense). brain_recall_print resolves a hit
back to its real path with resolve(). Why: one machine serving several products keeps one docs tree per product
and shows each only to the sessions working on it (found necessary 2026-09-07 with a third product's KB)."""
import os, re, pathlib


def roots():
    """[(path, tag, scope_regex), ...] in env order; blank entries are skipped, tags follow the kept order."""
    dirs = [os.environ.get("BRAIN_WIKI_DIR", "")] + os.environ.get("BRAIN_WIKI_DIRS", "").split(";")
    rxs = [os.environ.get("BRAIN_WIKI_SCOPE_RX", "")] + os.environ.get("BRAIN_WIKI_SCOPE_RXS", "").split(";")
    out = []
    for d, rx in zip(dirs, rxs + [""] * len(dirs)):
        d = d.strip()
        if d:
            out.append((pathlib.Path(os.path.expanduser(d)), "wiki" if not out else f"wiki{len(out) + 1}", rx.strip()))
    return out


ROOTS = roots()
_BY_TAG = {t: (p, rx) for p, t, rx in ROOTS}
_IDX = {}


def is_wiki(tag):
    return str(tag).startswith("wiki")


def visible(tag, slug):
    """May a session with this project slug see this docs root? A tag no root is configured for = hidden
    (stale index rows). No regex = everyone; else the slug must exist and match."""
    if tag not in _BY_TAG:
        return False
    rx = _BY_TAG[tag][1]
    return True if not rx else bool(slug) and bool(re.search(rx, slug))


def resolve(tag, name):
    """Real file path for a docs hit. Since 2026-09-10 index rows carry the path under the root
    (sub/dir/note.md) and it is joined directly; a bare basename (older rows, the file-scan fallback)
    still resolves through a lazy walk of the root. Two same-named notes in different folders no
    longer collapse onto whichever the walk met first."""
    if "/" in name and tag in _BY_TAG:
        return os.path.join(_BY_TAG[tag][0], name)
    if tag not in _IDX:
        idx = {}
        for dp, dn, fn in os.walk(_BY_TAG[tag][0] if tag in _BY_TAG else "/nonexistent"):
            dn[:] = [d for d in dn if not d.startswith(".") and d != "_archive"]
            for f in fn:
                if f.endswith(".md"):
                    idx.setdefault(f, os.path.join(dp, f))
        _IDX[tag] = idx
    return _IDX[tag].get(name, f"{tag}/{name}")
