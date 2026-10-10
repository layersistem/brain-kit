# Project wiki convention

A docs root is a folder of markdown that recall indexes read-only next to the vault: `BRAIN_WIKI_DIR` for one,
`BRAIN_WIKI_DIRS` with `BRAIN_WIKI_SCOPE_RXS` for several (README "Configuration"). Recall prints its hits in a SOURCE
block above the vault's RECORD block, with a `code:` line of the file paths the article names. Any tree of markdown
works as a docs root. This document describes a layout and an article shape that recall reads well, for a project
whose wiki you are free to shape. It is advice, like [DISCIPLINE.md](DISCIPLINE.md): nothing in the kit checks it.

The behaviour described below was measured on a test wiki with the kit's own recall hook, BM25 only, both through the
SQLite index that `setup.sh` configures and through the plain file scan. The one number about the dense engine is read
from its code.

## Layout

```
wiki/
  schema.md       the writing rules: the namespaces, the front matter, the article shape
  index.md        one line per article, grouped by namespace
  code/           how the system works: services, jobs, data flow, configuration
  corporate/      how the organisation works: processes, policies, who decides what
  customer/       one article per customer: setup, contract terms, history
  <namespace>/    add one when a group of articles has a different reader
```

The indexer reads every `.md` file under the root, at any depth. It skips hidden folders, `_drafts/`, `_archive/` and
files named `MEMORY.md`. The SQLite index also skips a file whose first 2,000 characters contain `noindex: true`; the
file scan, the fallback when the index is missing, does not read that line.

`schema.md` is what a writer, a person or an agent, reads before adding an article. To the kit it and `index.md` are
ordinary articles: indexed, ranked and shown like any other. Give both a `topic:` line, so a question such as "where
is the retry logic documented" can land on the index.

## Namespaces

No script in the kit reads a `namespace:` field, and the kit gives a namespace folder no meaning of its own. A docs
root is one unit: a session that may see the root sees every namespace in it. Two setups follow from that.

- One root for the whole wiki, `BRAIN_WIKI_DIR=~/code/shop/wiki`. The namespace shows in the path recall prints
  (`.../wiki/code/payment-retries.md`), and every session sees all of it.
- One root per namespace. Each root gets a scope regex, so a namespace reaches only the sessions that need it:

  ```
  BRAIN_WIKI_DIR=~/code/shop/wiki/code
  BRAIN_WIKI_SCOPE_RX=shop-api
  BRAIN_WIKI_DIRS=~/code/shop/wiki/customer
  BRAIN_WIKI_SCOPE_RXS=support-desk
  ```

  A scope regex is matched against the session's project directory written the way Claude Code names its project
  folders: slashes, spaces and underscores become hyphens, so a session opened in `/home/ana/code/shop-api` matches
  `shop-api`. The roots are tagged `wiki`, `wiki2`, ... in recall output. On the test wiki, a session in `shop-api` did
  not see the customer article and a session in `support-desk` saw it as `wiki2:acme-onboarding`; the code article did
  not reach the `support-desk` session.

## Article shape

```markdown
---
namespace: code
topic: payment retry backoff for failed card charges
last_verified: 2026-10-01
---
# Payment retries

> **When to look:** a charge fails twice, or someone changes the retry limits.

## Backoff schedule

The delay doubles on every attempt, up to five attempts. The schedule is built in
services/billing/retry.go, and scripts/replay.sh re-sends a failed charge by hand.

## Ledger reconciliation

...
```

- `topic:` is printed as the `what:` line under the hit, cut at 130 characters. Its words join the file name and the
  section heading as name words, and a rare query word that matches a name word raises the score. Recall takes the
  first of `recall_hint:`, `description:` and `topic:` that the front matter has, so an article with a `description:`
  shows that line instead. An article with none of the three is still found, without a `what:` line.
- `namespace:` is for the people and tools that maintain the wiki: a schema check, a script that moves articles, a
  reader who opened the file on its own. Keep it equal to the folder name.
- `last_verified:` (or `date:`) works as it does on a vault note: the age decay counts from it. A `status:` that marks
  the article as replaced (`superseded`, `stale`, `obsolete`, ...) pushes it down the ranking. On the test wiki, of two
  articles with the same text, the one verified a year earlier ranked second, and an article marked `superseded`
  ranked below a live one although its text matched the query better.
- The second-level headings (`##`) split the article into sections, and a section is what recall points at
  (`wiki:payment-retries > Backoff schedule`). The text above the first of them is a section too, named after the
  title. BM25 and the dense engine read the first 4,000 characters of a section; the `code:` line reads the first
  600, and the excerpt under the hit shows the first 200. A long section is better split under two headings
  than left with a tail no query reaches.
- The "When to look" line ([DISCIPLINE.md](DISCIPLINE.md) §2) goes right under the title, so it is in the excerpt
  whenever the opening section is the hit.

## Code paths and the `code:` line

Recall collects file paths from the `topic:` line and from the first 600 characters of the section that matched, and
prints up to five of them. For the article above, the query "how does the payment retry backoff schedule work for
failed card charges" printed (header line left out, `<wiki>` standing for the root):

```
  SOURCE (shared docs - Read the path; a claim about how the system works is built from here and from the code):
  FAIR [1.00b] wiki:payment-retries > Backoff schedule  (<wiki>/code/payment-retries.md)
      what: payment retry backoff for failed card charges
      ## Backoff schedule The delay doubles on every attempt, up to five attempts. The schedule is built in services/billing/retry.go, and scripts/replay.sh re-sends a failed charge by hand.
      code: services/billing/retry.go - scripts/replay.sh  (docs-to-code bridge: open before judging)
```

What makes a path appear on that line:

- Write it as a plain path relative to the repository root. Backticks around it are fine.
- The extension has to be one of `.py`, `.sh`, `.sql`, `.js`, `.jsx`, `.ts`, `.go`, `.rs`, `.yml`, `.yaml`, `.toml`.
  On the test wiki, `web/src/card.test.ts` was listed and `web/src/CardForm.tsx` was not. Name other files in the
  text anyway; they are only left off the `code:` line.
- The path needs a folder part: `services/billing/retry.go` is listed, a bare `main.go` is not. A bare name ending in
  `.py` or `.sh` is listed.
- An absolute path loses its leading slash: `/srv/app/services/hooks/verify.go` printed as
  `srv/app/services/hooks/verify.go`, which no longer points anywhere. Relative paths avoid that.
- Name the files near the top of the section that explains them. On the test wiki, a path that started 795
  characters into its section was not on the line.

## Keeping it current

The write hook re-indexes vault and memory notes only. An article edited under a docs root reaches the SQLite index on
the next round of the index sweeper (every two minutes, when its timer is installed) or with
`"$BRAIN_ROOT/.venv/bin/python" "$BRAIN_ROOT/scripts/brain_index.py" update`. Until then recall shows the old text;
on the test wiki the new path appeared right after the `update`. A very large tree can stay out of the encoder with
`BRAIN_WIKI_EMBED=0`.

The kit never writes into a docs root, checks an article's front matter or holds up any work until an article has
been read. The reading order in [DISCIPLINE.md](DISCIPLINE.md) §3 is advice; a hook that enforces it is one you write
yourself (§8).
