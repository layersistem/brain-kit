#!/usr/bin/env python3
"""consolidate_prompt - builds the prompt for the consolidation pass.

Input: a window of decision records plus, for each one, the older BM25 neighbours that may
now be obsolete. Output: one markdown prompt asking for a four-part PROPOSAL report.
The agent proposes; a human applies. Nothing here writes to the vault."""

CONTRACT = """You are the consolidation agent for a second brain - the waking equivalent of
sleep consolidation. Below is a window of decision records (DR) plus, for each one, older
neighbouring notes found by BM25.

PRODUCE = one markdown report (no other prose), titled '# Consolidation proposal <window>',
with exactly four sections:

## 1. DISTILL (decision record -> durable layer)
One line each: `- [target] <target-file or NEW:<slug>> <- <source-DR> - <one-sentence summary> (evidence: <DR heading/line>)`
target is one of: knowledge (reusable technical or process know-how) . memory (working style,
authority, preference) . canon (a rule that belongs in the project instructions).
Only information that actually appears in the DR and will be needed again; not one-off ops detail.
Target file names come ONLY from the VALID-NOTES list below, or are prefixed `NEW:`.

## 2. SUPERSEDE (old -> new)
One line each: `- <old-note> -> <new-DR> - <same topic, and what it invalidated> (confidence: high|medium)`
Only pairs where a newer decision genuinely invalidates an older one. "Related" is NOT superseded.
Write 'medium' when unsure; if doubtful, leave it out. Applying means adding `status: superseded`
plus `superseded_by:` to the old note.

## 3. CONFLICT / DUPLICATE
Note pairs that state the same fact differently or repeat each other, with a suggestion for which
one should be canonical.

## 4. WEIGHT CANDIDATES
Decision records with no `weight:` frontmatter whose body carries CANON/LESSON/NEVER markers:
`- <DR> -> weight: canon|lesson`

RULES: never add information that is not in the DRs (no invention) . note names only from the
VALID-NOTES list (no ghost links) . summarise, do not copy DR text . every proposal carries its
evidence (which DR, which section) . never write a secret, token or password value . short and
technical, no decoration. An empty section may simply say 'none'."""


def build(window, items, valid_notes):
    """items: [{note, meta, headings, body, neighbors:[(note, score, heading)]}]"""
    parts = [CONTRACT, f"\nWINDOW: {window}\n", "VALID-NOTES (only these names may be used):",
             ", ".join(sorted(valid_notes)), "\n=== DECISION RECORDS ==="]
    for it in items:
        m = it["meta"]
        parts.append(f"\n--- {it['note']} | date={m.get('date','?')} status={m.get('status','?')} "
                     f"weight={m.get('weight','-')} ---\ntopic: {m.get('topic','')}\n"
                     f"headings: {' . '.join(it['headings'][:12])}\n{it['body']}")
        if it["neighbors"]:
            parts.append("OLDER NEIGHBOURS (BM25): " + " . ".join(
                f"{n} [{s:.0f}] <<{h[:50]}>>" for n, s, h in it["neighbors"]))
    return "\n".join(parts)
