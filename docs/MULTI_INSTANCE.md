# Multiple instances, one vault

Several agent sessions on one machine can share a single vault. Nothing here is enforced by
code - it is convention plus three small mechanisms that keep sessions from overwriting each
other's memory.

## 1. `.brain-instance`

A one-line file naming the session that owns a directory. `setup.sh` writes one at the vault
root containing `main`. To give a project its own instance name, drop a `.brain-instance`
containing e.g. `web` in the project root.

The format is one line holding the name and nothing else - `vault-seed/instance-name.example`
is exactly that file.

Resolution order used by the hooks: `BRAIN_INSTANCE` in the environment, then the nearest
`.brain-instance` walking up from the **session's project directory** (`CLAUDE_PROJECT_DIR`,
which Claude Code hands to every hook; the shell cwd is only a fallback), then the vault's own
file, then `main`. This matters: a `cd` into another project inside a running session must not
change who the session is or whose per-project memory it reads - the identity is fixed at
session start. (Learned the hard way: an instance that `cd`'d into the vault folder was briefly
treated as the vault owner.)

## 2. Per-instance focus

Each instance gets `<vault>/focus/_FOCUS_<instance>.txt`. The focus hook injects only the file
belonging to the current instance, so two sessions working on different things do not pull each
other off course. The **first line** of that file is what the compact snapshot records, so keep
it a real one-line summary.

## 3. `instance:` frontmatter

Every note carries the instance that wrote it:

```yaml
---
instance: web
date: 2026-01-15
topic: why the build pipeline moved off the shared runner
---
```

It is a provenance field, not a filter: recall still surfaces notes from every instance, which
is the point - a decision made by one session must be visible to the next. What it gives you is
the ability to answer "who decided this, and where is that session's focus file".

## 4. Islands and hubs

Two working topologies, both fine:

- **Islands**: each instance owns a subject area and mostly writes there. Cross-references are
  occasional. Least contention, and how most people end up working.
- **Hub**: one instance owns the shared surfaces (infrastructure, the core scripts, anything
  several projects depend on). Others do not edit those files; they write down what they need
  as a spec - what, why, which file and line - and leave it for the owner.

One folder, one owner. Two sessions editing the same note produce a merge conflict inside your
memory, which is worse than a merge conflict in code because nobody reviews it.

## 5. Scope filtering

Recall can also filter by **project**, which is separate from instance. Set
`BRAIN_PROJECT_NAME`, `BRAIN_PROJECT_VOCAB` and `BRAIN_CWD_MARKERS` and notes belonging to a
different project stop competing for the top-k slots while you work. Notes tagged
`project: general` or `scope: hive` surface everywhere. Leave those variables empty and the
filter is off - which is the right default until one vault genuinely covers several projects.

## 6. Two sessions in one folder: session-bound identity

`.brain-instance` is per folder, so two sessions opened in the same folder get the
same name and write over each other's focus and notes. Since 2026-09-10 identity is
resolved per **session** first (`hooks/_instance.sh`):

1. `hooks/session-instance-bind.sh` runs on `SessionStart` (startup, resume,
   compact, clear) **and first on every `UserPromptSubmit`**. It binds a name to this
   session's `claude` process and to its `session_id`, under
   `<claude-dir>/brain-kit-state/session-instance/`. On a prompt it exits at once when
   the pid file exists and the session's sid file agrees with it; otherwise it re-binds.
   That second trigger exists because a desktop client once continued a window under a
   new `session_id` without firing `SessionStart`: no pid file, no sid file, and every
   hook fell back to the folder's name for a quarter of an hour. A line is printed only
   when the identity changes.
2. Every hook (and anything the Bash tool runs) reads the pid file first, then
   `BRAIN_INSTANCE`, then the nearest `.brain-instance`. Hooks and the Bash tool
   are descendants of the same `claude` process, so the pid is the one key that is
   per-session rather than per-folder.
3. To open a second instance in a folder that already has one, write a one-line
   ticket before opening the session:

   ```
   printf 'web /Users/me/project\n' > ~/.claude/brain-kit-state/next-instance
   ```

   The first session started under that folder consumes the ticket and becomes
   `web`; every other session there keeps resolving to the folder's name. Resume
   and compact keep the binding through the `sid-<session_id>` file.
4. A client that names its sessions (the desktop app writes `agent-name` /
   `custom-title` into the transcript) can hand the name over without a ticket:
   set `BRAIN_TITLE_MAP="web|frontend=web;api=api"` in `brain-kit.env`. The title is
   matched case-insensitively as a substring; the first rule that matches wins. The
   order of sources is therefore: bound session -> ticket -> title -> folder. Unset,
   the title source is skipped and nothing changes.

Measured on the day it shipped: a pid file set to a test name changed every hook's
identity at once; removing it restored the old one; the ticket was consumed exactly once. Rename the state files if you must, but
never write them by hand for a running session - that is how a session ends up
signing another one's name.
