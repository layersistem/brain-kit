#!/usr/bin/env python3
"""desk_ledger - export the issues and pull requests of your repos into the vault, so recall knows closed work.

Writes one note per repo, `<vault>/knowledge/desk-ledger-<owner>-<repo>.md`, listing every issue and PR
(number, kind, state with date, author, title, branch or labels, and the kebab-case identifiers the body and
comments mention), plus `<vault>/moc/MOC-desk-ledger.md` linking them. Run it from a timer (hourly:
scripts/systemd/brain-desk-ledger.*, or a cron line); setup.sh installs the timer when `gh` is present and
you list repos.

Why (23 Sep 2026): an agent answered "I would need the device" about five rules whose issues, PRs, reviews and
merges it had done itself the month before. Closed work lived only on GitHub, so a search of the vault by the
rule's name could not find it. This ledger is that gap closed: titles and branch names are written exactly as
GitHub has them (no shortening), and the "mentions" column carries identifiers pulled from bodies and comments
(the rule names in that case appeared in comments, never in a title), so `brain-search "<name>"` returns the
work you finished.

Rules:
- Standard library plus the `gh` CLI, called as-is: whatever `gh auth` holds is what it reads with. Read-only
  on the GitHub side.
- The vault gets only `knowledge/desk-ledger-*.md` and `moc/MOC-desk-ledger.md`. Body and comment TEXT is never
  written - only identifiers that pass the filter below (lower-case, hyphenated, two or more hyphens, 8-60
  characters, at least three consecutive letters, not a UUID or a sha), so a secret pasted into an issue cannot
  reach the vault through this path.
- A note is rewritten only when its content changed (the date line is ignored), so an hourly run does not
  re-embed unchanged notes.
- Sections are packed to about 3500 characters under `## ` headings, because the index splits on those and takes
  the first 4000 characters of each: a single 30 KB table would leave most rows unindexed.

Repos: --repo owner/name (repeatable), else BRAIN_DESK_REPOS (space or comma separated), else
<BRAIN_ROOT>/desk-ledger.repos (one owner/name per line, # comments). Authors: --author (repeatable) or
BRAIN_DESK_AUTHORS restrict the ledger to those logins (a bot's `app/` prefix and `[bot]` suffix are ignored);
empty = every author.

Usage: desk_ledger.py [--repo owner/name ...] [--author login ...] [--no-comments] [--dry-run]
Env:   BRAIN_ROOT (~/brain) . BRAIN_DIR (<root>/vault) . BRAIN_INSTANCE (main) . BRAIN_DESK_REPOS . BRAIN_DESK_AUTHORS .
       CLAUDE_CONFIG_DIR (~/.claude) - state and log live under its brain-kit-state/
       Since 1.2.0 the same variables are also read from <CLAUDE_CONFIG_DIR>/brain-kit.env, as the hooks do.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys


def _expand(v):
    """Shell-style value inside double quotes: a backslash before a backslash, a double quote, a dollar sign or a
    backtick is dropped, and $NAME / ${NAME} are taken from the environment."""
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v) and v[i + 1] in '\\"$`':
            out.append(v[i + 1]); i += 2; continue
        if c == "$":
            m = re.match(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))", v[i:])
            if m:
                out.append(os.environ.get(m.group(1) or m.group(2), "")); i += m.end(); continue
        out.append(c); i += 1
    return "".join(out)


def _read_env_file():
    """1.2.0: the settings in <config>/brain-kit.env (BRAIN_ROOT, BRAIN_DIR, and whatever you added). The hooks source
    that file; this script runs from a timer with no shell to do it, so a custom root or vault was invisible here and
    the ledger was written to ~/brain/vault. Lines of the form NAME=value, NAME="value" and NAME="${NAME:-value}" are
    read, with an optional `export` in front; anything else in the file is skipped, never executed. A variable that is
    already in the environment wins, as it does for the hooks."""
    path = os.path.join(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")), "brain-kit.env")
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return
    for ln in lines:
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", ln)
        if not m or m.group(1) in os.environ:
            continue
        name, v = m.group(1), m.group(2).strip()
        quote = v[0] if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'" else ""
        if quote:
            v = v[1:-1]
        d = re.fullmatch(r"\$\{" + name + r":?-(.*)\}", v, re.S)
        if d:
            v = d.group(1)
        os.environ[name] = v if quote == "'" else _expand(v)


_read_env_file()
BRAIN_ROOT = os.path.expanduser(os.environ.get("BRAIN_ROOT", "~/brain"))
VAULT = os.path.abspath(os.path.expanduser(os.environ.get("BRAIN_DIR") or os.path.join(BRAIN_ROOT, "vault")))
CFG = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
OUT_DIR = os.path.join(VAULT, "knowledge")
MOC_PATH = os.path.join(VAULT, "moc", "MOC-desk-ledger.md")
STATE_DIR = os.path.join(CFG, "brain-kit-state", "desk-ledger")
LOG_PATH = os.path.join(CFG, "brain-kit-state", "desk-ledger.log")
REPOS_FILE = os.path.join(BRAIN_ROOT, "desk-ledger.repos")
INSTANCE = os.environ.get("BRAIN_INSTANCE") or "main"
PREFIX = "desk-ledger-"
MOC_BEGIN = "<!-- desk-ledger:begin (written by scripts/desk_ledger.py) -->"
MOC_END = "<!-- desk-ledger:end -->"

ID_RE = re.compile(r"(?<![A-Za-z0-9_-])[a-z][a-z0-9]*(?:-[a-z0-9]+){2,}(?![A-Za-z0-9_-])")
ID_MAX = 30  # identifiers kept per issue or PR (note size)
ID_NOISE = {"co-authored-by", "https-github-com", "x-github-event", "content-type"}
SECTION_BUDGET = 3500


def id_ok(t):
    if not (8 <= len(t) <= 60) or t in ID_NOISE:
        return False
    if not re.search(r"[a-z]{3}", t.replace("-", "")):
        return False  # 2026-09-22, v1-2-3
    if re.fullmatch(r"[0-9a-f][0-9a-f-]{19,}", t):
        return False  # UUID / sha shaped
    return True


def ids_in(*texts):
    found = []
    for m in texts:
        if not m:
            continue
        for t in ID_RE.findall(str(m).lower()):
            if t in found or not id_ok(t):
                continue
            found.append(t)
            if len(found) >= ID_MAX:
                return found
    return found


def merge_ids(*lists):
    out = []
    for l in lists:
        for t in (l or []):
            if t not in out and id_ok(t):
                out.append(t)
                if len(out) >= ID_MAX:
                    return out
    return out


def norm_login(login):
    l = (login or "").lower()
    if l.startswith("app/"):
        l = l[4:]
    if l.endswith("[bot]"):
        l = l[:-5]
    return l


def gh(args, timeout=120):
    try:
        p = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr.strip()
    except FileNotFoundError:
        return 127, "", "gh not found on PATH"
    except subprocess.TimeoutExpired:
        return 124, "", "gh timed out"


def gh_json(args, timeout=120):
    rc, out, err = gh(args, timeout)
    if rc != 0:
        return None, err or f"rc={rc}"
    try:
        return json.loads(out or "[]"), None
    except json.JSONDecodeError as e:
        return None, f"bad JSON from gh: {e}"


def cell(s):
    return str(s if s is not None else "").replace("|", "\\|").replace("\r", " ").replace("\n", " ").strip()


def day(iso):
    return iso[:10] if iso else ""


def pr_state(it):
    st = (it.get("state") or "").lower()
    if st == "merged":
        return f"merged {day(it.get('mergedAt'))}"
    if st == "closed":
        return f"closed {day(it.get('closedAt'))}"
    return "open"


def issue_state(it):
    st = (it.get("state") or "").lower()
    return f"closed {day(it.get('closedAt'))}" if st == "closed" else "open"


def slug(repo):
    return repo.replace("/", "-")


def state_path(repo):
    return os.path.join(STATE_DIR, slug(repo) + ".json")


def state_read(repo):
    try:
        with open(state_path(repo), encoding="utf-8") as f:
            d = json.load(f)
        return d.get("since"), {int(k): v for k, v in (d.get("ids") or {}).items()}
    except (OSError, ValueError):
        return None, {}


def state_write(repo, since, ids):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = state_path(repo) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"since": since, "ids": {str(k): v for k, v in ids.items()}}, f)
    os.replace(tmp, state_path(repo))


def comment_ids(repo):
    """Identifiers mentioned in issue and PR-review comments, by number. Incremental: only comments updated
    since the last run are fetched (the first run reads them all). Comment text goes nowhere; only ids."""
    since, acc = state_read(repo)
    newest = since
    error = None
    for path in (f"repos/{repo}/issues/comments", f"repos/{repo}/pulls/comments"):
        q = f"{path}?per_page=100&sort=updated&direction=asc"
        if since:
            q += f"&since={since}"
        rc, out, err = gh(["api", "--paginate", q], timeout=600)
        if rc != 0:
            if "Issues are disabled" not in (err or "") and "Not Found" not in (err or ""):
                error = (err or f"rc={rc}")[:120]
            continue
        try:
            text = out.strip()
            data = json.loads(text) if text.startswith("[") and text.endswith("]") else []
            if not data and text:  # --paginate may emit consecutive arrays
                data = [x for part in re.split(r"\]\s*\[", text) for x in json.loads("[" + part.strip("[]") + "]")]
        except ValueError as e:
            error = f"comment JSON: {e}"
            continue
        for c in data:
            ref = c.get("issue_url") or c.get("pull_request_url") or ""
            m = re.search(r"/(\d+)$", ref)
            if not m:
                continue
            no = int(m.group(1))
            new = ids_in(c.get("body"))
            if new:
                rec = acc.setdefault(no, [])
                for t in new:
                    if t not in rec and len(rec) < ID_MAX:
                        rec.append(t)
            u = c.get("updated_at") or c.get("created_at")
            if u and (newest is None or u > newest):
                newest = u
    return acc, newest, error


def collect(repo, authors, cids):
    """rows = (number, kind, state, author, title, branch_or_labels, url, created, ids); plus counts and errors."""
    errors, rows = [], []
    n_i = n_p = 0
    issues, err = gh_json(["issue", "list", "--repo", repo, "--state", "all", "--limit", "500", "--json",
                           "number,title,state,author,createdAt,closedAt,labels,url,body"])
    if err:
        if "disabled issues" not in err:  # a repo setting, not a failure
            errors.append(f"issues: {err}")
        issues = []
    for it in issues:
        login = norm_login((it.get("author") or {}).get("login", ""))
        if authors and login not in authors:
            continue
        n_i += 1
        labels = " ".join(sorted(l.get("name", "") for l in (it.get("labels") or [])))
        rows.append((it["number"], "issue", issue_state(it), login, it.get("title", ""), labels, it.get("url", ""),
                     it.get("createdAt", ""), merge_ids(ids_in(it.get("title"), it.get("body")), cids.get(it["number"]))))
    prs, err = gh_json(["pr", "list", "--repo", repo, "--state", "all", "--limit", "500", "--json",
                        "number,title,state,author,createdAt,mergedAt,closedAt,url,headRefName,body"])
    if err:
        errors.append(f"prs: {err}")
        prs = []
    for it in prs:
        login = norm_login((it.get("author") or {}).get("login", ""))
        if authors and login not in authors:
            continue
        n_p += 1
        rows.append((it["number"], "PR", pr_state(it), login, it.get("title", ""), it.get("headRefName", ""),
                     it.get("url", ""), it.get("createdAt", ""),
                     merge_ids(ids_in(it.get("title"), it.get("headRefName"), it.get("body")), cids.get(it["number"]))))
    rows.sort(key=lambda r: r[0], reverse=True)
    return rows, n_i, n_p, errors


def note_text(repo, rows, n_i, n_p, today, authors):
    who = ", ".join(sorted(authors)) if authors else "every author"
    out = [
        "---",
        f"instance: {INSTANCE}",
        f"date: {today}",
        f'topic: "{repo} issue and PR ledger (generated by scripts/desk_ledger.py)"',
        "status: active",
        "weight: routine",
        "---",
        "",
        f"# {repo} - issue and PR ledger",
        "",
        f"> **When to look:** before saying \"no record\", \"not done\", \"I would need\" or \"waiting for\" about",
        "> anything with a name that could have been an issue or a PR in this repo. Search the name first",
        "> (`brain-search \"<name>\"`); this note is what makes closed work findable by that name.",
        ">",
        f"> Generated by `scripts/desk_ledger.py` from `gh` ({who}); {n_i} issues, {n_p} PRs. Titles and branch",
        "> names are exactly as on GitHub. The mentions column holds identifiers found in the body and the",
        "> comments; the text itself is never copied here.",
        "",
    ]
    head = ["| # | kind | state | author | title | branch / labels | mentions |",
            "|---|------|-------|--------|-------|-----------------|----------|"]
    box, size, sections = [], 0, []
    for num, kind, state, login, title, branch, url, _, ids in rows:
        s = (f"| [#{num}]({url}) | {kind} | {cell(state)} | {cell(login)} | {cell(title)} | {cell(branch)} | "
             f"{cell(' '.join(ids))} |")
        if box and size + len(s) > SECTION_BUDGET:
            sections.append(box)
            box, size = [], 0
        box.append(s)
        size += len(s) + 1
    if box:
        sections.append(box)
    for grp in sections:
        first = re.search(r"#(\d+)", grp[0]).group(1)
        last = re.search(r"#(\d+)", grp[-1]).group(1)
        out += [f"## {repo} #{first} to #{last}", ""] + head + grp + [""]
    out += ["", "## Related", "- [[MOC-desk-ledger]] - every repo ledger this script maintains.", ""]
    return "\n".join(out)


def body_of(text):
    return "\n".join(l for l in text.splitlines() if not l.startswith("date: "))


def moc_update(names, today, dry):
    block = (MOC_BEGIN + "\n\n## Desk ledger (issues and PRs, generated)\n"
             "- One note per repo, every issue and PR with its exact title, branch and the identifiers it mentions,"
             " so closed work is found by name: " + " . ".join(f"[[{a}]]" for a in names) + "\n\n" + MOC_END)
    if os.path.isfile(MOC_PATH):
        old = open(MOC_PATH, encoding="utf-8").read()
    else:
        old = ("---\n"
               f"instance: {INSTANCE}\n"
               f"date: {today}\n"
               'topic: "map of the generated desk ledgers"\n'
               "status: active\n"
               "weight: routine\n"
               "---\n\n# MOC-desk-ledger\n\n"
               "> **When to look:** to see which repos have a ledger note. The ledgers themselves answer\n"
               "> \"was there ever an issue or a PR about <name>\".\n")
    if MOC_BEGIN in old and MOC_END in old:
        new = re.sub(re.escape(MOC_BEGIN) + r".*?" + re.escape(MOC_END), lambda _m: block, old, flags=re.S)
    else:
        new = old.rstrip("\n") + "\n\n" + block + "\n"
    if new == old:
        return "MOC unchanged"
    if dry:
        return "MOC would change"
    os.makedirs(os.path.dirname(MOC_PATH), exist_ok=True)
    with open(MOC_PATH, "w", encoding="utf-8") as f:
        f.write(new)
    return "MOC updated"


def repo_list(args):
    if args.repo:
        return args.repo
    env = os.environ.get("BRAIN_DESK_REPOS", "")
    if env.strip():
        return [r for r in re.split(r"[,\s]+", env.strip()) if r]
    try:
        with open(REPOS_FILE, encoding="utf-8") as f:
            return [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    except OSError:
        return []


def log(msg):
    print(msg)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description="export issues and PRs into the vault as desk-ledger notes")
    ap.add_argument("--repo", action="append", help="owner/name (repeatable)")
    ap.add_argument("--author", action="append", help="only this login (repeatable); default: every author")
    ap.add_argument("--no-comments", action="store_true", help="skip the comment scan (faster)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    today = dt.date.today().isoformat()
    ts = dt.datetime.now().strftime("%F %T")
    repos = repo_list(a)
    bad = [r for r in repos if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", r)]
    if bad:
        log(f"{ts} ERROR repo must be owner/name: {' '.join(bad)}")
        return 2
    if not repos:
        log(f"{ts} nothing to do: no repos (--repo, BRAIN_DESK_REPOS or {REPOS_FILE})")
        return 0
    authors = {norm_login(x) for x in (a.author or re.split(r"[,\s]+", os.environ.get("BRAIN_DESK_AUTHORS", "").strip())) if x}
    os.makedirs(OUT_DIR, exist_ok=True)
    written = unchanged = empty = 0
    top_i = top_p = 0
    names, problems = [], []
    for repo in repos:
        cids, newest, c_err = ({}, None, None) if a.no_comments else comment_ids(repo)
        if c_err:
            problems.append(f"{repo}: comments: {c_err}")
        rows, n_i, n_p, errors = collect(repo, authors, cids)
        problems += [f"{repo}: {e}" for e in errors]
        if cids and not a.dry_run and not a.no_comments:
            state_write(repo, newest, cids)
        top_i += n_i
        top_p += n_p
        if not rows:
            empty += 1
            continue
        name = PREFIX + slug(repo)
        names.append(name)
        text = note_text(repo, rows, n_i, n_p, today, authors)
        path = os.path.join(OUT_DIR, name + ".md")
        old = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
        if old and body_of(old) == body_of(text):
            unchanged += 1
            continue
        written += 1
        if not a.dry_run:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
    # The MOC list is built from disk, not from this run's repo list, so a single --repo run does not drop
    # the links of the other ledgers.
    on_disk = sorted(f[:-3] for f in os.listdir(OUT_DIR) if f.startswith(PREFIX) and f.endswith(".md"))
    moc = moc_update(sorted(set(on_disk) | set(names)), today, a.dry_run) if (on_disk or names) else "MOC skipped (no ledgers)"
    summary = (f"{ts} repos {len(repos)} . issues {top_i} . PRs {top_p} . notes written {written} . unchanged {unchanged}"
               f" . empty {empty} . {moc}" + (f" . ERRORS {len(problems)}: " + "; ".join(problems[:5]) if problems else "")
               + (" (dry run)" if a.dry_run else ""))
    log(summary)
    return 1 if problems and not (written or unchanged) else 0


if __name__ == "__main__":
    sys.exit(main())
