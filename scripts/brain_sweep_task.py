#!/usr/bin/env python3
"""brain_sweep_task.py - Windows only: run scripts/brain_index_sweep.sh without a console window.

setup.sh registers a Task Scheduler entry ("brain-kit index sweep", every 2 minutes) that starts this file with the
kit's pythonw.exe. pythonw has no console, and the Git Bash process below is started with CREATE_NO_WINDOW, so nothing
flashes on the desktop. The sweeper itself is the same shell script macOS and Linux run from launchd and systemd; it
reads brain-kit.env on its own. Git Bash's location was written to <root>/winbin/bash.path by setup.sh ("bash" on a
Windows PATH can be the WSL launcher, which is a different thing). Standard library only; exits 0 on every path.
"""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
try:
    bash = (root / "winbin" / "bash.path").read_text(encoding="utf-8").strip()
    sweep = root / "scripts" / "brain_index_sweep.sh"
    if bash and sweep.is_file():
        subprocess.run([bash, "-l", str(sweep)], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
except Exception:
    pass
sys.exit(0)
