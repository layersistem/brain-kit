#!/usr/bin/env python3
"""brain_searchd - warm BGE-M3 dense-recall daemon (the dense half of hybrid recall).

HTTP 127.0.0.1:8799   GET /search?q=<text>&k=5&scope=<project-slug>   GET /health
Source: <vault>/.index/brain.db, the SQLite index brain_index.py maintains (`chunks.embedding`,
kept fresh by the embed hook). Reloads automatically when the file's mtime changes - a plain
read-only connection, so there is no half-written-line failure mode to guard against. Cosine
only - no reranker (measured: slower and worse on this corpus). CPU on purpose: the model stays
resident at ~2-3 GB and a warm query takes ~80 ms.
Scope: `vault/` and `memory/` entries are visible to everyone; `imem/<slug>/` (per-project memory)
only to the instance whose slug matches. If the daemon is down, brain_recall.py falls back to BM25.

Env:  BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_EMBED_MODEL (BAAI/bge-m3) . BRAIN_SEARCHD_PORT (8799)
Run:  <venv>/bin/python scripts/brain_searchd.py   (launchd / systemd unit: see docs/DENSE_RECALL.md)"""
import os, json, time, pathlib, sqlite3, threading, urllib.parse, warnings
from http.server import BaseHTTPRequestHandler, HTTPServer
warnings.filterwarnings("ignore")
import numpy as np
np.seterr(all="ignore")

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
EMB_FILE = VAULT / ".index" / "brain.db"
EMB_MODEL = os.environ.get("BRAIN_EMBED_MODEL", "BAAI/bge-m3")
PORT = int(os.environ.get("BRAIN_SEARCHD_PORT", "8799"))
_LOCK = threading.Lock()
_S = {"mtime": 0.0, "entries": [], "mat": None, "loaded_at": 0.0}
_RELOADING = {"on": False}


def _load_blocking(mt):
    """brain.db -> memory: a read-only connection against brain_index.py's `chunks` table."""
    ent, vecs = [], []
    with sqlite3.connect(f"file:{EMB_FILE}?mode=ro", uri=True) as c:
        for rel, note, heading, text, blob in c.execute(
                "SELECT c.rel, f.note, c.heading, c.text600, c.embedding FROM chunks c JOIN files f ON f.rel = c.rel "
                "WHERE c.embedding IS NOT NULL ORDER BY c.id"):
            ent.append({"path": rel, "note": note, "heading": heading or "", "text": text or ""})
            vecs.append(np.frombuffer(blob, dtype="float32"))
    with _LOCK:
        _S["entries"] = ent
        _S["mat"] = np.vstack(vecs) if vecs else None
        _S["mtime"], _S["loaded_at"] = mt, time.time()
    print(f"brain_searchd: index loaded, {len(ent)} chunks", flush=True)


def _load():
    """brain.db -> memory, only when its mtime changed. Hot-swap: once an index is already
    resident, a reload runs on a background thread and queries keep answering from the old index
    until it finishes - a synchronous reload (~1-2 s on a few thousand chunks) could outlast the
    client's short HTTP timeout and surface as a BrokenPipe with an empty dense-recall result for
    that turn. Only the very first load (no index yet) is synchronous, since there is nothing to
    fall back to."""
    try:
        mt = EMB_FILE.stat().st_mtime
    except OSError:
        return
    if mt == _S["mtime"] or _RELOADING["on"]:
        return
    if _S["mat"] is None:
        return _load_blocking(mt)  # first load: no prior index to serve from, must block
    _RELOADING["on"] = True

    def _bg():
        try:
            _load_blocking(mt)
        finally:
            _RELOADING["on"] = False

    threading.Thread(target=_bg, daemon=True).start()


def _visible(path, scope):
    if path.startswith("imem/"):
        return bool(scope) and path.startswith(f"imem/{scope}/")
    return True


def search(q, k=5, scope=""):
    _load()
    with _LOCK:
        ent, mat = _S["entries"], _S["mat"]
    if mat is None:
        return []
    qv = np.array(EMB.encode([q], normalize_embeddings=True)[0], dtype="float32")
    cos = mat @ qv
    out, seen = [], set()
    for i in cos.argsort()[::-1]:
        e = ent[i]
        if not _visible(e["path"], scope) or e["note"] in seen:
            continue
        seen.add(e["note"])
        root = "memory" if e["path"].startswith(("memory/", "imem/")) else "brain"
        out.append({"root": root, "note": e["note"], "heading": e.get("heading", ""), "path": e["path"],
                    "score": round(float(cos[i]), 3), "text": e["text"][:600]})
        if len(out) >= k:
            break
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        try:
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        except BrokenPipeError:
            print("client-gone (timed out before response?)", flush=True)  # one line, not a traceback

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); p = urllib.parse.parse_qs(u.query)
        if u.path == "/health":
            _load()
            # `vault` lets brain_recall.py verify this daemon serves ITS vault: two installs on one
            # machine both default to :8799, and without this check the second one silently recalls
            # the first one's notes (found 2026-09-03 in an isolated-install test).
            return self._send({"ok": True, "entries": len(_S["entries"]), "index_mtime": _S["mtime"],
                               "model": EMB_MODEL, "vault": str(VAULT.resolve())})
        q = (p.get("q", [""])[0]).strip(); k = int(p.get("k", ["5"])[0]); scope = p.get("scope", [""])[0]
        try:
            r = search(q, k, scope) if q else []
        except Exception as ex:
            r = []; print("search-err:", ex, flush=True)
        self._send(r)


if __name__ == "__main__":
    print(f"brain_searchd: loading {EMB_MODEL} ...", flush=True)
    from sentence_transformers import SentenceTransformer
    EMB = SentenceTransformer(EMB_MODEL, device="cpu")
    EMB.encode(["warm-up"], normalize_embeddings=True)
    _load()
    print(f"brain_searchd: ready on http://127.0.0.1:{PORT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
