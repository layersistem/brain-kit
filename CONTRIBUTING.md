# Contributing

Thank you for taking the time. This file says how to file a useful issue, how a pull request gets accepted, and what the maintainers will not merge.

## Who maintains this

Burak Tuvay and Athena, a Claude agent. Athena does the measuring, writing and reviewing; Burak accepts every release on his own vault before it is tagged. Expect review comments to ask for numbers.

## Before you file an issue

1. Search the existing issues for the script or hook name (`context-inject.sh`, `brain_index.py`) and for the exact error string. Names match; titles rarely do.
2. Read the section of `CHANGELOG.md` for the version you run (`VERSION` next to your install). Several behaviours changed between releases and the entry usually says why.
3. Run `scripts/update.sh --dry-run` and check that you are on the latest tag. Bugs are fixed on the latest release only.

## Filing a bug

Use the bug report template. The fields it asks for are the ones needed to reproduce: your kit version, OS and shell, the Claude Code version, the hook or script involved, what happened, what you expected, and one line of evidence from a transcript or a log. Redact anything personal from that line first; the vault is yours and nobody here wants to read it.

A report that says "recall returned the wrong note" cannot be worked on. One that says "on prompt X, recall printed notes A, B and C, and the answer was in note D, whose title contains these words" can be.

## Proposing a change

Open an issue before a large pull request. The kit is opinionated in a few places: recall never injects unbounded text from outside the machine, the vault format is stable, and hooks stay inside the latency budget the CHANGELOG states. A change that crosses one of those lines will be declined even if the code is good. An issue costs ten minutes; a declined pull request costs an afternoon.

## Pull requests

- One topic per pull request. A fix and a refactor go in two.
- Shell scripts run on the stock bash 3.2 of macOS and on Linux. Check syntax with `bash -n` under bash 3.2 if you have it, and avoid features newer than 3.2 (associative arrays, `${var,,}`, `mapfile`).
- Python code runs on the version stated under Requirements in `README.md`, standard library only unless the file already imports something else.
- Hooks print nothing on the happy path and exit 0 on every failure they can survive. A hook that blocks the session on a missing optional dependency will not be merged.
- Anything that adds text to the model's context needs a sentence in the pull request saying where the text comes from and how it is bounded. Text from a network, a remote tag or another user is filtered before it reaches the context.
- Add a `CHANGELOG.md` entry under an "Unreleased" heading, written for the person who will read it during an upgrade: what changed, why, and what they must do.
- Measured claims carry the method. "Faster" is not a claim; "14.4 s to 1.0 s per note over 1453 runs, measured from transcripts" is.
- No secrets, no personal transcripts and no vault content in the diff or the description.

Fill in the pull request template; the review reads it first.

## Review and release

Pull requests are reviewed by Athena, who may ask for a measurement or a smaller diff. Accepted changes are merged by the maintainers, land in the next tagged release with a CHANGELOG entry, and the GitHub Release for that tag credits the contributor.

## Security

Do not report a vulnerability in a public issue. See `SECURITY.md`.

## Licence

By contributing you agree that your contribution is licensed under the MIT licence in `LICENSE`.
