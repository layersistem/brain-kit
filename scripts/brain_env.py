#!/usr/bin/env python3
"""brain_env - the settings in <agent-config-dir>/brain-kit.env, for a script that runs without a hook around it.

Every hook sources brain-kit.env when it runs. A script started by hand, from a timer or from a shell does not, so a
vault path set only in that file (where setup.sh and INTRO_PROMPT.md put it) was invisible to it: the script fell back
to ~/brain/vault and printed the default vault's numbers without a warning (issue #22). load() reads the file into
os.environ before the script builds its paths, the way the shell reads it, and never executes it:

- A variable that is set and not empty before load() starts wins over every line of the file, so a value exported on
  the command line decides. The hooks, which source the file, differ here: a plain `NAME=value` line overrides an
  exported value there (issue #24). The lines setup.sh writes, `NAME="${NAME:-value}"`, keep the exported value in both.
- Otherwise the file is read top to bottom and a later line overrides an earlier one. `${NAME:-word}` keeps the value
  NAME has at that line (from the environment or an earlier line) when it is not empty, `${NAME-word}` when it is set.
- Quoting as in the shell: single quotes literal, double quotes expand $NAME and ${NAME} and drop the backslash before
  \\ " $ `; an unquoted # that starts a word begins a comment. Several assignments on one line, `;` between statements
  and an `export` in front are read. A line that would run a command (a word that is not an assignment, which also
  makes the assignments in front of it temporary) is skipped; $(...) and backticks are kept as text, never run.
- Measured against bash 3.2 and 5.2, the scripts and the hooks also differ on a line that runs a command or $(...)
  (the hook runs it), on CRLF line ends (the hook keeps the CR in the value), on ~ inside double quotes (the hook keeps
  it as text, the scripts' paths expand it), and on shell syntax this reader does not take: $'...', $"...", +=, a
  backslash at the end of a line, a quote over several lines, a function, a here-document, an array, a redirection,
  ${#NAME}, $$, operators other than - = + (with or without :), and a quote left open or a syntax error, where bash
  stops reading. A lone CR or a form feed ends a line here.

desk_ledger.py has read brain-kit.env since 1.2.0; its reader moved here (issue #22) and now follows these rules too.
Env: CLAUDE_CONFIG_DIR (~/.claude)"""
import os, re

_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_PARAM = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:?)([-=+]?)")


def _close(s, i):
    """Index of the } that ends the ${ whose body starts at i (quotes and backslashes skipped), or -1."""
    depth, q = 1, ""
    while i < len(s):
        c = s[i]
        if c == "\\" and q != "'":
            i += 2; continue
        if q:
            q = "" if c == q else q
        elif c in "'\"":
            q = c
        elif s.startswith("${", i):
            depth += 1; i += 1
        elif c == "}":
            depth -= 1
            if not depth:
                return i
        i += 1
    return -1


def _dq_end(s, i):
    """Index of the " that closes a double-quoted part starting at i, or len(s)."""
    while i < len(s):
        if s[i] == "\\":
            i += 2; continue
        if s.startswith("${", i):
            j = _close(s, i + 2); i = (j if j >= 0 else len(s)) + 1; continue
        if s[i] == '"':
            return i
        i += 1
    return len(s)


def _expand(s, cur, dq=False):
    """The value of one shell word (or of the inside of double quotes when dq), with variables taken from cur."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\":
            if i + 1 < len(s) and (not dq or s[i + 1] in '\\"$`'):
                out.append(s[i + 1]); i += 2; continue
            out.append(c); i += 1; continue
        if c == "'" and not dq:
            j = s.find("'", i + 1); j = len(s) if j < 0 else j
            out.append(s[i + 1:j]); i = j + 1; continue
        if c == '"' and not dq:
            j = _dq_end(s, i + 1)
            out.append(_expand(s[i + 1:j], cur, True)); i = j + 1; continue
        if c == "$":
            m = _NAME.match(s, i + 1)
            if m:
                out.append(cur.get(m.group(0), "")); i = m.end(); continue
            m, j = _PARAM.match(s, i), _close(s, i + 2)
            if m and j > 0:
                name, colon, op = m.groups()
                word = s[m.end():j]
                have = name in cur and (cur[name] != "" or not colon)
                if not op and not word:
                    out.append(cur.get(name, "")); i = j + 1; continue
                if op in ("-", "="):
                    v = cur[name] if have else _expand(word, cur, dq)
                    if op == "=" and not have:
                        cur[name] = v
                    out.append(v); i = j + 1; continue
                if op == "+":
                    out.append(_expand(word, cur, dq) if have else ""); i = j + 1; continue
        out.append(c); i += 1
    return "".join(out)


def _statements(line):
    """The line split like the shell: a list of statements, each a list of raw words; stops at a comment."""
    stmts, words, w, i, n = [], [], None, 0, len(line)
    while i < n:
        c = line[i]
        if c in " \t;":
            if w is not None:
                words.append(w); w = None
            if c == ";":
                stmts.append(words); words = []
            i += 1; continue
        if c == "#" and w is None:
            break
        start = i
        if c == "\\":
            i += 2
        elif c == "'":
            j = line.find("'", i + 1); i = (n if j < 0 else j) + 1
        elif c == '"':
            i = _dq_end(line, i + 1) + 1
        elif line.startswith("${", i):
            j = _close(line, i + 2); i = (n if j < 0 else j) + 1
        else:
            i += 1
        w = (w or "") + line[start:i]
    if w is not None:
        words.append(w)
    return stmts + [words]


def load():
    """Read <CLAUDE_CONFIG_DIR>/brain-kit.env into os.environ by the rules above. A missing or unreadable file changes
    nothing. Bytes that are not UTF-8 reach os.environ as they are in the file, as the shell passes them on
    (surrogateescape), and a NUL byte is dropped, as bash 5 drops it."""
    path = os.path.join(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")), "brain-kit.env")
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            lines = fh.read().replace("\0", "").splitlines()
    except OSError:
        return
    kept = {k for k, v in os.environ.items() if v}
    cur = dict(os.environ)
    for ln in lines:
        for words in _statements(ln):
            if words[:1] == ["export"]:
                words = [x for x in words[1:] if not _NAME.fullmatch(x)]
            pairs = [x.split("=", 1) for x in words]
            if not words or any(len(p) != 2 or not _NAME.fullmatch(p[0]) for p in pairs):
                continue   # empty, or it would run a command
            for name, raw in pairs:
                if name not in kept:
                    cur[name] = _expand(raw, cur)
    for name, v in cur.items():   # ${NAME:=word} sets NAME as well, so compare instead of listing the assignments
        if name not in kept and os.environ.get(name) != v:
            os.environ[name] = v
