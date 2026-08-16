#!/usr/bin/env python3
"""brain_searchd - warm BGE-M3 dense-recall daemon (the dense half of hybrid recall).

HTTP 127.0.0.1:8799   GET /search?q=<text>&k=5&scope=<project-slug>   GET /health
Source: <vault>/.index/embeddings.jsonl (kept fresh by the embed hook). Reloads automatically when
the file's mtime changes. Cosine only - no reranker (measured: slower and worse on this corpus).
CPU on purpose: the model stays resident at ~2-3 GB and a warm query takes ~80 ms.
Scope: `vault/` and `memory/` entries are visible to everyone; `imem/<slug>/` (per-project memory)
only to the instance whose slug matches. If the daemon is down, brain_recall.py falls back to BM25.

Env:  BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_EMBED_MODEL (BAAI/bge-m3) . BRAIN_SEARCHD_PORT (8799)
Run:  <venv>/bin/python scripts/brain_searchd.py   (launchd / systemd unit: see docs/DENSE_RECALL.md)"""
import os, json, time, pathlib, threading, urllib.parse, warnings
from http.server import BaseHTTPRequestHandler, HTTPServer
warnings.filterwarnings("ignore")
import numpy as np
np.seterr(all="ignore")

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
VAULT = pathlib.Path(os.environ.get("BRAIN_DIR", str(BRAIN_ROOT / "vault")))
EMB_FILE = VAULT / ".index" / "embeddings.jsonl"
EMB_MODEL = os.environ.get("BRAIN_EMBED_MODEL", "BAAI/bge-m3")
PORT = int(os.environ.get("BRAIN_SEARCHD_PORT", "8799"))
_LOCK = threading.Lock()
_S = {"mtime": 0.0, "entries": [], "mat": None}


def _load():
    """embeddings.jsonl -> memory, only when its mtime changed (a few thousand chunks: <1 s)."""
    try:
        mt = EMB_FILE.stat().st_mtime
    except OSError:
        return
    if mt == _S["mtime"]:
        return
    ent = [json.loads(l) for l in EMB_FILE.read_text().splitlines() if l.strip()]
    ent = [e for e in ent if "vector" in e]
    with _LOCK:
        _S["entries"] = ent
        _S["mat"] = np.array([e["vector"] for e in ent], dtype="float32") if ent else None
        _S["mtime"] = mt
    print(f"brain_searchd: index loaded, {len(ent)} chunks", flush=True)


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
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); p = urllib.parse.parse_qs(u.query)
        if u.path == "/health":
            _load()
            return self._send({"ok": True, "entries": len(_S["entries"]), "index_mtime": _S["mtime"],
                               "model": EMB_MODEL})
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
