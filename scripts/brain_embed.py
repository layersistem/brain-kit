#!/usr/bin/env python3
"""brain_embed - local BGE-M3 embedder for the vault (CPU).

Vectorises every *.md section in the vault (plus any extra memory roots) and stores the
result in <vault>/.index/embeddings.jsonl. Hash-incremental: unchanged files are not
re-embedded. Nothing leaves the machine - no API key, no network call after the model is
cached once.

Usage: brain_embed.py
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_MEMORY . BRAIN_MEMORY2 .
       BRAIN_EMBED_MODEL (default BAAI/bge-m3)
"""
import os, re, json, hashlib, pathlib

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
MEMORY = pathlib.Path(os.environ.get("BRAIN_MEMORY", str(BRAIN_ROOT / "memory")))
MEMORY2 = pathlib.Path(os.environ.get("BRAIN_MEMORY2", "/nonexistent"))
ROOTS = [(VAULT, "vault"), (MEMORY, "memory"), (MEMORY2, "memory")]
MODEL_NAME = os.environ.get("BRAIN_EMBED_MODEL", "BAAI/bge-m3")
INDEX_DIR = VAULT / ".index"
EMB_FILE = INDEX_DIR / "embeddings.jsonl"
MANIFEST = INDEX_DIR / "manifest.json"
MAX_CHARS = 4000                     # per-section cap fed to the encoder


def md_files():
    for root, tag in ROOTS:
        if not root.exists():
            continue
        for p in root.rglob("*.md"):
            parts = p.relative_to(root).parts
            if any(part.startswith(".") for part in parts):
                continue             # .index / .obsidian / hidden dirs
            if "_drafts" in parts or "_archive" in parts or p.name == "MEMORY.md":
                continue             # drafts, archive and the memory index stay out
            yield root, tag, p


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


def load_existing():
    by_path = {}
    if EMB_FILE.exists():
        for line in EMB_FILE.read_text().splitlines():
            if line.strip():
                e = json.loads(line)
                by_path.setdefault(e["path"], []).append(e)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    return by_path, manifest


def main():
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    by_path, manifest = load_existing()
    out, to_embed, new_manifest = [], [], {}
    for root, tag, f in md_files():
        rel = f"{tag}/{f.relative_to(root)}"
        text = f.read_text(encoding="utf-8", errors="ignore")
        h = sha(text)
        new_manifest[rel] = h
        if manifest.get(rel) == h and rel in by_path:
            out.extend(by_path[rel])         # unchanged -> reuse the stored vectors
            continue
        for i, (heading, chunk) in enumerate(chunk_file(text)):
            to_embed.append({"path": rel, "note": f.stem, "heading": heading,
                             "chunk_id": i, "text": chunk})
    reused = len(out)
    if to_embed:
        from sentence_transformers import SentenceTransformer
        print(f"loading model: {MODEL_NAME} (cpu) - {len(to_embed)} chunks to embed", flush=True)
        model = SentenceTransformer(MODEL_NAME, device="cpu")   # CPU on purpose: small and stable
        vecs = model.encode([e["text"] for e in to_embed], normalize_embeddings=True,
                            batch_size=16, show_progress_bar=True)
        for e, v in zip(to_embed, vecs):
            e["vector"] = [round(float(x), 6) for x in v]
            out.append(e)
    with EMB_FILE.open("w") as fh:
        for e in out:
            fh.write(json.dumps(e, ensure_ascii=False) + "\n")
    MANIFEST.write_text(json.dumps(new_manifest, ensure_ascii=False, indent=2))
    print(f"OK - {len(new_manifest)} files, {len(out)} chunks "
          f"({reused} reused, {len(to_embed)} new). -> {EMB_FILE}")


if __name__ == "__main__":
    main()
