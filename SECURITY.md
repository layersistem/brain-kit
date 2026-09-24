# Security Policy

## What this kit touches

The kit installs hooks that run inside your Claude Code session with your user's permissions, a local index over your own notes, an optional dense recall daemon, and optional timers. The daemon listens on 127.0.0.1 only. The kit's own network use is limited to three things: the embedding model is fetched from Hugging Face on first use and cached, the daily update notice runs one `git ls-remote --tags` against the repository you cloned, and the optional desk ledger reads your repositories through `gh`. Nothing about you or your vault is sent anywhere.

Anything that lets text from outside your machine reach the model's context without being bounded, that reads or writes outside the vault and the kit's own state directory, that exposes the daemon beyond the loopback interface, or that runs with more privilege than the session has, is a security bug here.

## Supported versions

The latest tagged release. Fixes ship as a new tag with a `CHANGELOG.md` entry, and `scripts/update.sh` applies them.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting on this repository (Security tab, "Report a vulnerability"), or write to info@layersistem.com with "brain-kit security" in the subject. Include the kit version, the file involved, the steps to reproduce and what an attacker gains.

You will get an acknowledgement in the advisory thread or by reply, then a fix or a reasoned decision, and credit in the release notes unless you ask not to be named.

## Secrets and personal data

The vault, the index and the transcripts the kit reads are yours and never leave your machine through the kit. A path by which they could is in scope. When you report, redact your own data first; a reproduction on a throwaway vault is best.
