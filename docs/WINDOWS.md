# Installing brain-kit on Windows

This page is written for the model that does the install: Claude, GPT, Gemini, a local open model, any agent
that can run commands on the user's Windows 10 or 11 machine. A person can follow it too. Work through it top
to bottom. Every step has a check, the output a healthy machine prints, and what to do when the output differs.
Do not skip a check because the previous command printed no error: several failures on Windows are silent.

brain-kit installs natively on Windows. It does not need WSL, Docker or administrator rights.

## 0. What you are about to do

| | |
|---|---|
| Shell for the kit | **Git Bash**, which comes with Git for Windows. Claude Code runs its hooks in Git Bash, so the kit lives there. |
| Shell for the prerequisites | PowerShell or CMD, whichever your command tool gives you. |
| What gets installed | Git for Windows, Python 3.10 or newer, jq, the Microsoft Visual C++ runtime, then the kit itself. |
| Where the kit lands | `C:\Users\<name>\brain` (scripts, hooks, the note vault, a Python environment) and `C:\Users\<name>\.claude` (hook wiring, settings, skills). |
| Disk | Full install: about 6 GB (Python environment 1.1 GB, embedding model 4.3 GB, pip's download cache). `--no-embed`: under 100 MB. |
| Memory | The full install loads a 2.3 GB embedding model when it builds the index and again, in the background, after notes are written; budget about 3 GB of free memory for it. Measured on a 4 GB Windows 11 machine: the full install completes, the first load of the model took 14 minutes and a later load 100 seconds. With 4 GB or less, `--no-embed` is the lighter choice: keyword recall, the focus line, the hygiene check and consolidation do not need the model. |
| Time | Prerequisites: about 5 minutes. Full install: 15 to 30 minutes on a first run (measured: 24 minutes on a 4 GB Windows 11 machine, 10 of them downloads and 14 the first load of the model). `--no-embed`: under a minute. |

Two rules that prevent most failures:

1. **After every `winget install`, the shell you are in still has the old PATH.** A command that was just
   installed is "not recognized" until you start a new shell. Either start a new shell for the next step, or
   call the program by its full path. The checks below use full paths where that matters.
2. **Run kit commands in Git Bash, not in PowerShell or CMD.** From PowerShell, one Git Bash command looks
   like this (the `-l` matters: it gives Git Bash its own tools):

   ```powershell
   & "C:\Program Files\Git\bin\bash.exe" -lc "cd ~/brain-kit && ./setup.sh --yes-defaults"
   ```

   From CMD, drop the leading `& `. If your tool gives you a Git Bash prompt directly (the prompt shows
   `MINGW64`), run the part inside the quotes as it is.

## 1. Prerequisites

Do the five in order. Each block is: check, install if the check fails, check again in a **new** shell.

### 1.1 Git for Windows (gives you Git Bash)

Check (PowerShell or CMD):

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc "git --version; uname -s"
```

Healthy output: a version line and a line that starts with `MINGW64_NT`.

If the file is not found, install it and check again:

```powershell
winget install -e --id Git.Git --source winget --accept-package-agreements --accept-source-agreements
```

Without winget: download the installer from <https://git-scm.com/downloads/win> and accept its defaults.
If Git is installed somewhere else, find it with `where.exe git` and use the `bin\bash.exe` under that folder
everywhere this page says `C:\Program Files\Git\bin\bash.exe`.

### 1.2 Python 3.10 or newer

Check:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc "python --version"
```

Healthy output: `Python 3.10` or higher. **If the command prints nothing, opens the Microsoft Store, or says
"Python was not found", Python is not installed.** Windows ships two placeholder programs named `python` and
`python3` that only open the Store; they are not Python.

Install and check again in a new shell:

```powershell
winget install -e --id Python.Python.3.12 --source winget --accept-package-agreements --accept-source-agreements
```

Without winget: the installer from <https://www.python.org/downloads/windows/>, with **"Add python.exe to
PATH"** ticked. You do not need a `python3` command; the installer below looks for `python` as well and gives
the hooks their own `python3`.

### 1.3 jq

Check:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc "jq --version"
```

Healthy output: `jq-1.7` or higher. Install and check again in a new shell:

```powershell
winget install -e --id jqlang.jq --source winget --accept-package-agreements --accept-source-agreements
```

Without winget: download `jq-windows-amd64.exe` from <https://jqlang.github.io/jq/download/>, rename it to
`jq.exe` and put it in a folder that is on PATH.

### 1.4 Microsoft Visual C++ runtime (full install only)

The embedding model runs on PyTorch, and PyTorch does not load on a Windows that lacks this runtime. A fresh
Windows does not have it. Skip this step only if you will install with `--no-embed`.

Check:

```powershell
Test-Path "$env:SystemRoot\System32\msvcp140.dll"
```

Healthy output: `True`. If it prints `False`:

```powershell
winget install -e --id Microsoft.VCRedist.2015+.x64 --source winget --accept-package-agreements --accept-source-agreements
```

Without winget: <https://aka.ms/vs/17/release/vc_redist.x64.exe>.

### 1.5 Claude Code

The kit's hooks are wired into Claude Code. Check:

```powershell
claude --version
```

If it is not recognized, install it and check again in a new shell:

```powershell
winget install -e --id Anthropic.ClaudeCode --source winget --accept-package-agreements --accept-source-agreements
```

The user signs in the first time `claude` starts; that step needs the user's browser and you cannot do it for
them. The kit can be installed before or after the sign-in.

## 2. Get the kit

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc "git clone https://github.com/layersistem/brain-kit ~/brain-kit && cd ~/brain-kit && git log --oneline -1 && cat VERSION"
```

Healthy output: a commit line and a version number. `~` in Git Bash is `C:\Users\<name>`, so the clone is at
`C:\Users\<name>\brain-kit`. The repository sets its own line endings; you do not need to change any Git setting.

If you were given a ZIP instead of a clone, unpack it to `C:\Users\<name>\brain-kit`.

## 3. Run the installer

Choose one:

- **Full** (recommended): keyword recall plus semantic recall with a local embedding model.

  ```powershell
  & "C:\Program Files\Git\bin\bash.exe" -lc "cd ~/brain-kit && ./setup.sh --yes-defaults 2>&1 | tee ~/brain-kit-setup.log; echo EXIT=`${PIPESTATUS[0]}"
  ```

- **Keyword recall only**, for a machine with little memory (4 GB or less) or little disk. Ask the machine first:
  `powershell -NoProfile -Command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)"`
  prints the memory in GB.

  ```powershell
  & "C:\Program Files\Git\bin\bash.exe" -lc "cd ~/brain-kit && ./setup.sh --yes-defaults --no-embed 2>&1 | tee ~/brain-kit-setup.log; echo EXIT=`${PIPESTATUS[0]}"
  ```

  (The backtick before `$` is for PowerShell. In CMD or at a Git Bash prompt, write `${PIPESTATUS[0]}`
  without it.)

`--yes-defaults` answers every question with its default, so nothing waits for input; since 1.8.0 that includes the
caveman skill (compressed replies in every session), so add `--caveman=no` to leave it out. The full install is quiet
for several minutes during step `(2/8)` (it downloads PyTorch) and again at `building the index` (it downloads
the 2.3 GB model once and loads it; on a machine with 4 GB of memory that last step alone took 14 minutes, with
no output and almost no CPU use, while Windows read the new files for the first time). **Silence is not a hang.**
Give the command a timeout of at least 45 minutes and do not start a second copy while the first one runs. To
see that it is alive from another shell: the file `~/brain-kit-setup.log` shows the step it is in.

Healthy output ends like this:

```
== done - restart your agent session so the hooks load, then read README.md
   ...
EXIT=0
```

and contains these lines on the way:

```
   ok  Windows layer: python3.exe in the venv, LF line ends for Python and jq (...)
   ok  20 hook entries total (yours were kept)
   ok  scheduled task "brain-kit index sweep" created (every 2 min; ...)
   ok  brain.db built (BM25 + BGE-M3)
```

If `EXIT` is not 0, the reason is on the line that starts with `FAILED:`. Fix it and run the same command
again; the installer is safe to repeat and does not download anything twice.

| `FAILED:` line says | Cause | Fix |
|---|---|---|
| `Python >= 3.10 not found` | Python is missing, or only the Store placeholders exist | Step 1.2, then a new shell |
| `jq not found` | jq is missing | Step 1.3, then a new shell |
| `torch is installed but does not load` | The Visual C++ runtime is missing | Step 1.4, then run the installer again |
| `pip install failed` | No network, a proxy, or a full disk | Check the network and free disk, run again; or use `--no-embed` |
| `index build failed` | Usually memory: the model did not fit | Close other programs and run again; or use `--no-embed` |
| nothing, the command "is not recognized" | You ran it in PowerShell or CMD without Git Bash | Use the command exactly as written above |

## 4. Verify the install

One command runs five checks:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc "bash ~/brain/scripts/install-check.sh; echo EXIT=`$?"
```

(In CMD or at a Git Bash prompt, write `$?` without the backtick.)

Healthy output:

```
PASS 1 hooks wired: 20 entries in /c/Users/<name>/.claude/settings.json
PASS 2 hooks' Python: 3.12 (/c/Users/<name>/brain/.venv/Scripts/python3)
PASS 3 hygiene check: the linkless test note was reported as an orphan
PASS 4 index update: brain.db: 3 files (1 changed, 0 removed)
PASS 5 recall: the test note was found by its words
     index: files 2 - chunks 9 - embedded 9
ALL CHECKS PASSED - restart the agent session so the hooks load
EXIT=0
```

The checks do not ask whether files are in place. They write a test note without links into the vault, hand the
write hooks a payload that spells its path the way Claude Code does on Windows (`C:\Users\...`), and look at
what comes back: the hygiene hook has to report the note as an orphan, the index hook has to count one more
file, and recall has to find the note by its words. The test note is removed again at the end. This matters on
Windows because a broken write side prints no error; before the kit supported Windows, every hook exited 0
while new notes never reached the index.

With `--minimal`, check 1 counts 16 and check 3 says the hygiene check is not part of the install. With
`--no-embed`, the `index:` line shows `embedded 0`; that is correct. On a slow machine `embedded` can be lower
than `chunks` for a few minutes after a write: the vectors are filled in the background.

**If any line starts with `FAIL`, the install is not done.** The line says what was expected; the table in
"When a check fails" below maps it to a fix. Do not report success with a failing check.

## 5. First session

Tell the user to close every open Claude Code window and start `claude` again: hooks are read when a session
starts. In the new session the first prompt carries a few extra lines at the top. The user (or you, if you are
the model in that session) should see:

- a clock line that starts with `NOW` and today's date;
- a focus block that starts with `FOCUS`;
- for a prompt of four words or more, an `AUTO-RECALL` block.

Then ask the session to write a short decision note into the vault (`C:\Users\<name>\brain\vault\decision\`).
A healthy write is followed by a line that contains `brain index: brain.db:` with a file count one higher than
before. If the note has no `[[links]]`, the session is told `Orphan note`; that is the hygiene check working.

The rest of the kit (what the lines mean, how notes are written, consolidation) is the same on every system:
continue with `INTRO_PROMPT.md`, at A3 for a fresh project or at B1 for notes the user already keeps. Its install
and verify steps (A1, A2) are what you have just done. The installer's options described in the README work the
same on Windows, except `--self-compact`.

## 6. What is different on Windows

- **Paths.** Give the kit Windows paths with forward slashes when you set one by hand (`C:/Users/me/notes`), or
  the Git Bash form (`/c/Users/me/notes`). Both work in `brain-kit.env`. `BRAIN_ISOLATE_DIRS` and
  `BRAIN_FOCUS_DIRS` are compared as text against the Git Bash form: write those as `/c/Users/me/project`.
- **The Python the kit uses** is `C:\Users\<name>\brain\.venv\Scripts\python.exe`. Where a document says
  `python3 ~/brain/scripts/...` or `~/brain/.venv/bin/python`, use that file instead.
- **The Windows layer.** `setup.sh` adds three small things that exist only on Windows: a `python3.exe` beside
  the kit's interpreter, a `sitecustomize.py` in that environment that makes Python end lines with LF, and
  `brain\winbin\jq`, a wrapper that makes jq do the same. `hooks/_platform.sh` puts them in front of the hooks'
  PATH and converts `C:\...` paths to the form Git Bash compares. It also drops `MSYS_NO_PATHCONV` for the hooks'
  own children, so a shell that sets that switch does not stop the hooks from finding the vault. Nothing outside
  the kit's folders changes; the user's own Python, jq and shell settings behave as before.
- **Vectors for notes written outside the agent** come from a Task Scheduler entry named
  `brain-kit index sweep` (every 2 minutes, no window). Notes the agent writes are indexed by the write hook
  at once. `./setup.sh --no-timers` leaves the task out.
- **Not available on Windows:** self-compact (it needs tmux), and the session-bound instance identity that
  lets two named instances share one folder (it reads the process list in a way Git Bash cannot). A
  single-user install does not need either: the instance is `main`, or what `BRAIN_INSTANCE` or a
  `.brain-instance` file says.
- **The dense recall daemon** (`docs/DENSE_RECALL.md`) is described there as a systemd service. On Windows it
  has not been set up as a service; recall works without it (keyword recall on every prompt, vectors in the
  index for `brain_search.py`).

## 7. When a check fails

| Symptom | Cause | Fix |
|---|---|---|
| `FAIL 1 hooks wired` | `settings.json` was not written, or is not valid JSON | Run the installer again; if `settings.json` was broken before, restore the `settings.json.bak.<number>` next to it |
| `FAIL 2 hooks' Python` | The Windows layer is missing | `ls ~/brain/.venv/Scripts/python3.exe ~/brain/winbin/jq` must list both files; if not, run the installer again |
| `FAIL 3 hygiene check` or `FAIL 4 index update` with `output: none` | The hooks are from a kit older than Windows support, or the Windows layer is missing | `grep -c _platform.sh ~/brain/hooks/postwrite-check.sh` must print `1`; if it prints `0`: `git -C ~/brain-kit pull`, then run the installer again |
| `FAIL 3`, `FAIL 4` and `FAIL 5` together, on an install that worked before | Private mode is on, or the home folder is listed in `BRAIN_ISOLATE_DIRS` | `ls ~/.claude/brain-write.off ~/.claude/brain-recall.off`; delete the file if the user did not mean it |
| `FAIL 5 recall` alone | The index could not be read | `cd ~/brain && .venv/Scripts/python.exe scripts/brain_index.py build`, then run the check again |
| A hook error names `$'\r'` | The kit files have Windows line endings (a ZIP repacked by another tool, or a clone older than this page) | Delete `~/brain-kit`, clone again (step 2), run the installer again |
| Every prompt in Claude Code waits a long time | A hook cannot find its interpreter | Run the install check; then `bash -x ~/brain/hooks/time-inject.sh < /dev/null` in Git Bash and read the first error |
| The installer says it could not create the scheduled task | A policy on the machine forbids scheduled tasks | Nothing to fix: the write hook still indexes what the agent writes |
| `index:` shows fewer `embedded` than `chunks` an hour later | The sweeper is not running | `tail -3 ~/.claude/brain-kit-state/index_sweep.log`; run `bash ~/brain/scripts/brain_index_sweep.sh` once by hand and read what it prints |

To see what one hook does, run it by hand in Git Bash with a payload on standard input and `bash -x` in front of
the hook path. `scripts/install-check.sh` shows how such a payload is built.

## 8. Remove the kit

```powershell
schtasks /Delete /TN "brain-kit index sweep" /F
```

Then, in Git Bash: restore the newest `~/.claude/settings.json.bak.<number>` that predates the install over
`~/.claude/settings.json` (or remove the entries whose command contains `/brain/hooks/`), delete the block
between the `brain-kit-operating-rules` markers in `~/.claude/CLAUDE.md`, and delete `~/.claude/brain-kit.env`,
`~/.claude/brain-kit-state` and `~/brain`. **The vault with the user's notes is inside `~/brain/vault`: move it
somewhere else first unless the user says the notes can go.** The embedding model is in
`~/.cache/huggingface` (4.3 GB) and can be deleted separately.

## 9. What to report

When the five checks pass, report in five lines: the kit version (`cat ~/brain/VERSION`), full or `--no-embed`,
the hook count from check 1, the `index:` line of the install check, and that the user has to restart Claude
Code. If a check failed and you could not fix it, say which one and paste its line; do not call the install done.
