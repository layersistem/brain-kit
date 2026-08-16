"""brain_project - active-project detection + per-note domain tag (recall scope filter).

One vault, many projects: while you work inside project A, notes that clearly belong to
project B are dropped from the recall corpus instead of competing for the top-k slots.
Active project = env BRAIN_PROJECT, else a cwd marker match. Ambiguous -> no filtering
(safe default: a wrong filter hides real memory, a missing filter only adds noise).

Everything is env-driven, so each install defines its own main project:
  BRAIN_PROJECT_NAME   name of the main project (lowercase)
  BRAIN_PROJECT_VOCAB  whitespace/comma separated domain words that identify it
  BRAIN_CWD_MARKERS    path fragments that mean "cwd is inside the main project"
Leave them empty and the filter is off (every note counts as 'general').
"""
import os, re

PROJECT_NAME = os.environ.get("BRAIN_PROJECT_NAME", "").strip().lower()
CWD_MARKERS = [m for m in re.split(r"[,\s]+", os.environ.get("BRAIN_CWD_MARKERS", "").strip()) if m]
PROJECT_VOCAB = {
    w for w in re.split(r"[,\s]+", os.environ.get("BRAIN_PROJECT_VOCAB", "").strip().lower()) if w
}


def is_project(tokens):
    """>=2 domain-vocab hits -> the note belongs to the main project (one hit is a coincidence).
    Empty vocab never matches, which means the filter is off."""
    if not PROJECT_VOCAB:
        return False
    return sum(1 for t in set(tokens) if t in PROJECT_VOCAB) >= 2


def note_project(text, tokens, name=""):
    """Note scope, in order: frontmatter 'scope: hive|global' > 'project:' > name prefix > vocab.
    'general' means the note surfaces in every project and is never filtered out."""
    head = text[:600]
    if re.search(r"(?mi)^scope:[ \t]*(hive|global)\b", head):
        return "general"
    m = re.search(r"(?mi)^project:[ \t]*([^\n]+)$", head)
    if m:
        return m.group(1).strip().lower()
    if PROJECT_NAME and name.lower().startswith(PROJECT_NAME):
        return PROJECT_NAME       # <project>-*.md / <project>_*.md is an explicit name signal
    return PROJECT_NAME if (PROJECT_NAME and is_project(tokens)) else "general"


def active_project():
    """env BRAIN_PROJECT wins; otherwise a cwd-marker match. Unclear -> '' (no filtering)."""
    p = os.environ.get("BRAIN_PROJECT", "").strip()
    if p:
        return p.lower()
    if PROJECT_NAME:
        cwd = os.getcwd()
        for marker in CWD_MARKERS:
            if marker and marker in cwd:
                return PROJECT_NAME
    return ""
