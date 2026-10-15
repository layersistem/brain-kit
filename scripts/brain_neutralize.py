#!/usr/bin/env python3
"""brain_neutralize - the printed copy of a recalled note, made safe to put in front of the model (issue #14).

A note can quote anything: a harness tag copied out of a transcript (`<system-reminder>`), a message frame another
agent treats as an order, a zero-width character pasted along with a token. Recall prints excerpts into the context
of every prompt, so a quoted tag would arrive looking like a live one. Claude Code strips invisible characters and
neutralises its own markup in MEMORY.md; this does the same for what the recall renderer and decision-time recall
print. Only the printed copy changes. The vault is never touched, so a note written by hand or synced in from
elsewhere is covered too.

On with BRAIN_RECALL_NEUTRALIZE=1 (any other value, or unset, leaves every byte as it was). Two rules:
  - U+200B, U+200C, U+200D, U+2060 and U+FEFF are removed;
  - a harness tag, opening or closing, becomes `[tag: name]` / `[tag: /name]` (HARNESS_TAGS below)."""
import os
import re

ZERO_WIDTH = dict.fromkeys(map(ord, "​‌‍⁠﻿"))
HARNESS_TAGS = ("system-reminder", "task-notification", "user-prompt-submit-hook", "local-command-stdout",
                "local-command-stderr", "local-command-caveat", "command-name", "command-message", "command-args")
_TAG = re.compile(r"<(/?)(%s)\b[^<>\n]{0,200}>" % "|".join(HARNESS_TAGS), re.I)


def on():
    return os.environ.get("BRAIN_RECALL_NEUTRALIZE") == "1"


def neutralize(text):
    """Invisible characters first, so a tag split by one (`<system\\u200b-reminder>`) is still caught."""
    return _TAG.sub(lambda m: "[tag: %s%s]" % (m.group(1), m.group(2).lower()), text.translate(ZERO_WIDTH))
