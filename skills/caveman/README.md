# caveman

Talk like smart caveman in chat. Write like a careful human in deliverables. One base skill, two surfaces.

## What it does

Part 1, chat: compresses every model response to caveman prose. Drops articles, filler, pleasantries and hedging. Keeps every technical detail, code block, error string and symbol exact. Cuts roughly 65 to 75 percent of output tokens. The mode persists for the whole session until changed or stopped.

Three intensity levels:

| Level | What changes |
|-------|--------------|
| `lite` | Drop filler and hedging. Sentences stay full. Professional but tight. |
| `full` | Default. Drop articles, fragments OK, short synonyms. |
| `ultra` | Bare fragments. Abbreviations for prose words (DB, auth, fn). Arrows for causality. |

Auto-clarity: caveman drops to normal prose for security warnings, irreversible-action confirmations, multi-step sequences where fragment ambiguity risks a misread, and when the user repeats a question. It resumes after the clear part.

Part 2, deliverables: any text a third person reads as a finished product (email, article, wiki page, report, release note, UI copy, issue body) is not compressed. The skill switches to full-sentence prose and applies a distilled version of the humanizer catalog: 33 AI-writing tells grouped into content, language, style and rhetoric, each with its fix. Em and en dashes are a hard rule. A false-positive list keeps it from flattening legitimate prose. The full humanizer with before/after examples ships alongside as a reference and is opened only for long deliverables.

## How to invoke

```
/caveman              # full mode (default)
/caveman lite         # lighter compression
/caveman ultra        # extreme compression
stop caveman          # back to normal prose
```

The deliverable surface needs no command. Writing for a third reader triggers it.

## Example output

Question: "Why does my React component re-render?"

Normal prose:
> Your component re-renders because you create a new object reference each render. Wrapping it in `useMemo` will fix the issue.

Caveman (full):
> New object ref each render. Inline object prop = new ref = re-render. Wrap in `useMemo`.

Caveman (ultra):
> Inline obj prop → new ref → re-render. `useMemo`.

## History

Until 1 September 2026 this skill carried three classical-Chinese (wenyan) levels and a one-line bridge pointing at the separate humanizer skill. Field use showed the bridge was never followed: loading a second file is a separate decision, and models skipped it. The humanizer rules were distilled into this file (130 lines, about 2k tokens, against 8.6k for the full humanizer) and the wenyan levels were removed.

## See also

- [`SKILL.md`](./SKILL.md): the LLM-facing instructions
- [`../humanizer/SKILL.md`](../humanizer/SKILL.md): the full pattern catalog with examples

Bundled with brain-kit as an optional skill: terse output leaves more of the context window for recall injections. Nothing in the memory engine depends on it. Delete the folder if you prefer normal prose.
