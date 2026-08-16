#!/usr/bin/env python3
"""distill_lock - run guard for the consolidation pass: atomic lock, kill switch,
daily call cap and an append-only run log. Everything lives under BRAIN_ROOT, so a
second machine or a second checkout never shares state with this one.

The cap exists because the consolidation report is the only step that may call an LLM;
a scheduled loop that goes wrong should stop itself rather than run all night.

Env: BRAIN_ROOT (~/brain) . BRAIN_CONSOLIDATE_MAX_CALLS (default 20)
Files: <root>/.brain-consolidate.lock . .brain-consolidate.log . .brain-consolidate-calls.json
Kill switch: create <root>/.brain-loop.disabled to stop every scheduled run.
"""
import os, json, time, pathlib

BRAIN_ROOT = pathlib.Path(os.environ.get("BRAIN_ROOT", os.path.expanduser("~/brain")))
LOCK = pathlib.Path(os.environ.get("BRAIN_CONSOLIDATE_LOCK", str(BRAIN_ROOT / ".brain-consolidate.lock")))
LOG = BRAIN_ROOT / ".brain-consolidate.log"
KILL = BRAIN_ROOT / ".brain-loop.disabled"
CALL_CAP = int(os.environ.get("BRAIN_CONSOLIDATE_MAX_CALLS", "20"))
CALL_COUNT = BRAIN_ROOT / ".brain-consolidate-calls.json"
STALE_SEC = 7200            # a lock older than 2h is stale and gets reclaimed


def kill_active():
    return KILL.exists()


def acquire():
    """Atomic O_EXCL lock. False = already held (stale >2h locks are reclaimed)."""
    try:
        BRAIN_ROOT.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(LOCK), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        os.write(fd, str(os.getpid()).encode()); os.close(fd)
        return True
    except FileExistsError:
        try:
            if time.time() - LOCK.stat().st_mtime > STALE_SEC:
                LOCK.unlink(missing_ok=True); return acquire()
        except FileNotFoundError:
            return acquire()
        return False


def release():
    LOCK.unlink(missing_ok=True)


def _today():
    return time.strftime("%Y-%m-%d")


def _load_count():
    if CALL_COUNT.exists():
        try:
            return json.loads(CALL_COUNT.read_text())
        except Exception:
            return {}
    return {}


def budget_left():
    return _load_count().get(_today(), 0) < CALL_CAP


def note_call():
    today = _today()
    n = _load_count().get(today, 0) + 1
    CALL_COUNT.write_text(json.dumps({today: n}))    # today only - old days drop out


def log_event(event, **kw):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event}
    rec.update(kw)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
