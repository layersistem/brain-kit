#!/usr/bin/env python3
"""brain_embed - local BGE-M3 embedder for the vault (CPU).

Adds a semantic vector to every *.md section (vault, plus any extra memory roots) that does not
already have one, writing into the SQLite index brain_index.py maintains. Hash-incremental:
a file whose content has not changed keeps its stored vector. Nothing leaves the machine - no
API key, no network call once the model is cached. This module also supplies the root
list, chunking and hashing helpers that brain_index.py, brain_searchd.py and brain_search.py all
build on; the scan-and-embed pass itself lives in brain_index.sync().

Usage: brain_embed.py
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_MEMORY . BRAIN_MEMORY2 .
       BRAIN_EMBED_MODEL (default BAAI/bge-m3)
"""
import os, re, sys, hashlib, pathlib

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
MEMORY = pathlib.Path(os.environ.get("BRAIN_MEMORY", str(BRAIN_ROOT / "memory")))
MEMORY2 = pathlib.Path(os.environ.get("BRAIN_MEMORY2", "/nonexistent"))
IMEM_TAG = f"imem/{MEMORY2.parent.name}"   # per-project memory: tagged by project slug, filtered per instance at search
ROOTS = [(VAULT, "vault"), (MEMORY, "memory"), (MEMORY2, IMEM_TAG)]
MODEL_NAME = os.environ.get("BRAIN_EMBED_MODEL", "BAAI/bge-m3")
INDEX_DIR = VAULT / ".index"
EMB_FILE = INDEX_DIR / "embeddings.jsonl"  # retired storage format; kept only so brain_index.py can migrate an old install once
MAX_CHARS = 4000                     # per-section cap fed to the encoder


def strip_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            return text[end + 4:].lstrip("\n")
    return text


def chunk_file(text):
    """[(heading, chunk)] - the H1 title is prepended to every chunk as context."""
    title = ""
    for line in text.splitlines():
        if line.startswith("# "):
            title = line[2:].strip()
            break
    body = strip_frontmatter(text)
    parts = re.split(r"(?m)^## ", body)
    raw = []
    if parts[0].strip():
        raw.append((title or "intro", parts[0].strip()))
    for p in parts[1:]:
        heading = p.splitlines()[0].strip() if p.strip() else ""
        raw.append((heading, "## " + p.strip()))
    out = []
    for heading, chunk in raw:
        ctx = f"{title}\n{chunk}".strip() if title else chunk
        out.append((heading, ctx[:MAX_CHARS]))
    return out or [(title or "doc", text[:MAX_CHARS])]


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import brain_index
    brain_index.sync(full=False, embed=True)


if __name__ == "__main__":
    main()
