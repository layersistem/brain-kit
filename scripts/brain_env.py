#!/usr/bin/env python3
"""brain_env - the settings in <agent-config-dir>/brain-kit.env, for a script that runs without a hook around it.

Every hook sources brain-kit.env when it runs. A script started by hand, from a timer or from a shell does not, so a
vault path set only in that file (where setup.sh and INTRO_PROMPT.md put it) was invisible to it: the script fell back
to ~/brain/vault and printed the default vault's numbers without a warning (issue #22). load() reads the file into
os.environ before the script builds its paths. Lines of the form NAME=value, NAME="value", NAME='value' and
NAME="${NAME:-value}" are read, with an optional `export` in front; anything else in the file is skipped, never
executed. A variable that is already in the environment wins, so a value exported on the command line still decides,
and a script started by a hook (which has loaded the file already) sees exactly what it saw before.

The parser moved here unchanged from scripts/desk_ledger.py (1.2.0), which now imports it.
Env: CLAUDE_CONFIG_DIR (~/.claude)"""
import os, re


def expand(v):
    """Shell-style value inside double quotes: a backslash before a backslash, a double quote, a dollar sign or a
    backtick is dropped, and $NAME / ${NAME} are taken from the environment."""
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v) and v[i + 1] in '\\"$`':
            out.append(v[i + 1]); i += 2; continue
        if c == "$":
            m = re.match(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))", v[i:])
            if m:
                out.append(os.environ.get(m.group(1) or m.group(2), "")); i += m.end(); continue
        out.append(c); i += 1
    return "".join(out)


def load():
    """Read <CLAUDE_CONFIG_DIR>/brain-kit.env into os.environ, never overriding a variable that is already set.
    A missing or unreadable file changes nothing."""
    path = os.path.join(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")), "brain-kit.env")
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return
    for ln in lines:
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", ln)
        if not m or m.group(1) in os.environ:
            continue
        name, v = m.group(1), m.group(2).strip()
        quote = v[0] if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'" else ""
        if quote:
            v = v[1:-1]
        d = re.fullmatch(r"\$\{" + name + r":?-(.*)\}", v, re.S)
        if d:
            v = d.group(1)
        os.environ[name] = v if quote == "'" else expand(v)
