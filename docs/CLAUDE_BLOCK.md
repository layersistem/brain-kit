
<!-- brain-kit-operating-rules -->
## Memory (brain-kit)

- Recall runs on every prompt. When an AUTO-RECALL line is relevant, use it before re-deriving
  or reverse-engineering anything - a past session already did that work.
- Write `<vault>/decision/DR-<date>-<slug>.md` at the moment of a decision, rejection or
  approval, and before a compaction. A decision needs a source and an evidence link.
- Never delete a replaced decision: set `status: superseded` and `superseded_by:` instead.
- The vault holds decisions and lessons. Plans belong in your task list, not here.
- Keep `<vault>/focus/_FOCUS_<instance>.txt` current - it is injected verbatim every prompt.
- A page named `<vault>/moc/MOC-<Name>.md` or `<vault>/<name>-instance-hub.md` carries a `## Status` section:
  one dated line per delivery. It is printed whenever a prompt names the page.
<!-- /brain-kit-operating-rules -->
