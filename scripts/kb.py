#!/usr/bin/env python3
"""kb: the command-line half of the knowledge-base plugin.

Hooks call `kb.py hook <event>` with the hook's JSON on stdin. Skills and people call the other
subcommands. Standard library only, and every hook path exits 0 so the plugin can never block a
session. The file format is described in docs/format.md.
"""
from __future__ import annotations

import argparse
import datetime as dt
import difflib
import functools
import hashlib
import html as html_lib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

SECTIONS = ("decisions", "meetings", "facts", "architecture", "followups", "backlog", "discussions", "ideas", "research",
            "references", "notes", "inbox")
DATED_SECTIONS = ("decisions", "meetings", "followups", "backlog", "discussions", "ideas", "research", "references",
                  "notes")
APPROVABLE = ("decisions", "facts", "architecture", "followups", "backlog", "ideas", "references", "notes")
# `updates` and `question` mark a pending change to an existing fact (kb fact challenge).
INBOX_ONLY_FIELDS = ("proposed_section", "proposed_by", "reason", "updates", "question")
KIND_TO_SECTION = {"decision": "decisions", "meeting": "meetings", "fact": "facts",
                   "architecture": "architecture", "followup": "followups", "backlog": "backlog",
                   "discussion": "discussions", "idea": "ideas", "research": "research", "reference": "references",
                   "note": "notes"}
CONFIG_PATH = Path("~/.config/kb/config.json").expanduser()
DEFAULT_ROOT = "~/projects/knowledge"

# Index budget for the session-start context. Past these, Claude is told how many more exist.
MAX_DECISIONS = 40
MAX_FACTS = 40
MAX_MEETINGS = 5
MAX_RELATED_DECISIONS = 15
MAX_RELATED_FACTS = 15
MAX_FOLLOWUPS = 10


# ---------------------------------------------------------------- config & registry


def load_config() -> dict:
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, ValueError):
        return {}


def kb_root() -> Path:
    env = os.environ.get("KB_ROOT") or os.environ.get("CLAUDE_PLUGIN_OPTION_KB_ROOT")
    root = (env or "").strip() or load_config().get("root") or DEFAULT_ROOT
    return Path(os.path.expanduser(root)).resolve()


SCOPE_ADDED_KEYS = ("project", "project_title")

# ---------------------------------------------------------------- layout
#
# Two layouts. The split one (`shared/kb.json` exists):
#   <root>/shared/            kb.json, people.json, sources.json, email.json, daily/, reminders/, goals/
#   <root>/<scope>/           the scope's private entries and settings.json
#   <repo>/knowledgebase/     the team's entries of a scope with a repo, committed with the code
# The legacy one: everything in <root>, entries in <root>/projects/<scope>/.

TEAM_SECTIONS = ("decisions", "facts", "architecture", "followups", "backlog", "overview")
TEAM_FOLDER = "knowledgebase"
WINDOWS = os.name == "nt"
# Written into a new team folder so Git keeps shared entries in LF on every platform.
TEAM_GITATTRIBUTES = "* text=auto eol=lf\n"


def app_data_dir() -> Path:
    """Mindmill's own data, outside the KB: `%APPDATA%\\Mindmill` on Windows, `~/Library/Application Support/KB` on a Mac."""
    if WINDOWS:
        base = os.environ.get("APPDATA") or str(Path("~/AppData/Roaming").expanduser())
        return Path(base) / "Mindmill"
    return Path("~/Library/Application Support/KB").expanduser()


def lock_exclusive(f) -> None:
    """Blocks until this process holds the lock on the open file `f`, until it is closed or the process ends."""
    if WINDOWS:
        import msvcrt
        f.seek(0)
        while True:
            try:
                msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)
                return
            except OSError:
                time.sleep(0.1)
    import fcntl
    fcntl.flock(f, fcntl.LOCK_EX)


def git_bash() -> str | None:
    """Git for Windows' bash, which Claude Code on Windows uses too (`CLAUDE_CODE_GIT_BASH_PATH`)."""
    import shutil
    candidates = [os.environ.get("CLAUDE_CODE_GIT_BASH_PATH", "")]
    for var in ("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"):
        if os.environ.get(var):
            candidates.append(os.path.join(os.environ[var], "Git", "bin", "bash.exe"))
    found = shutil.which("bash")
    if found and "\\system32\\" not in found.lower():
        candidates.append(found)
    return next((c for c in candidates if c and os.path.isfile(c)), None)


def run_shell(template: str, value: str, cwd: str | None, timeout: int) -> subprocess.CompletedProcess:
    """Runs a user's command line with `{query}` replaced by `value`, quoted for the shell that runs it: sh on a Mac,
    Git Bash on Windows (so the same POSIX command lines work), cmd.exe only when there is no Git Bash."""
    import shlex
    if not WINDOWS:
        return subprocess.run(template.replace("{query}", shlex.quote(value)), shell=True, capture_output=True,
                              text=True, timeout=timeout, cwd=cwd)
    bash = git_bash()
    if bash:
        return subprocess.run([bash, "-c", template.replace("{query}", shlex.quote(value))], capture_output=True,
                              text=True, timeout=timeout, cwd=cwd)
    return subprocess.run(template.replace("{query}", subprocess.list2cmdline([value])), shell=True,
                          capture_output=True, text=True, timeout=timeout, cwd=cwd)


# Names Windows refuses for files or folders. Entries are shared with Windows users through the repositories' Git.
WINDOWS_RESERVED = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {f"lpt{i}" for i in range(1, 10)}


def windows_name_problem(name: str) -> str | None:
    """Why Windows can't have a file or folder called `name`, or None when it can."""
    bad = sorted({c for c in name if c in '<>:"/\\|?*' or ord(c) < 32})
    if bad:
        return "has " + " ".join(repr(c) for c in bad) + ", which Windows doesn't allow in names"
    if name.endswith((".", " ")):
        return "ends with a dot or a space, which Windows drops"
    if name.split(".")[0].strip().lower() in WINDOWS_RESERVED:
        return f"uses {name.split('.')[0].strip().upper()}, a name Windows reserves"
    if len(name.encode("utf-8")) > 255:
        return "is longer than 255 bytes"
    return None


def case_clashes(names: list[str]) -> list[list[str]]:
    """Names in one folder that differ only by case: one file on Windows and on a default Mac volume."""
    groups: dict[str, list[str]] = {}
    for n in names:
        groups.setdefault(n.casefold(), []).append(n)
    return [sorted(g) for g in groups.values() if len(g) > 1]


def portability_problems(base: Path, label: str) -> list[str]:
    """File and folder names under `base` that Windows rejects or folds together, as `kb lint` lines."""
    out: list[str] = []
    if not base.is_dir():
        return out
    for folder, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d != ".git"]
        here = Path(folder)
        rel = here.relative_to(base).as_posix()
        prefix = label if rel == "." else f"{label}/{rel}"
        for name in dirs + files:
            why = windows_name_problem(name)
            if why:
                out.append(f"{prefix}/{name}: {why}")
        for group in case_clashes(dirs + files):
            out.append(f"{prefix}: {', '.join(group)} differ only by case; Windows keeps one of them")
    return out


def team_folder_of(path: Path) -> Path | None:
    """The `knowledgebase/` folder of a repository that `path` is in, if it is in one."""
    for parent in path.parents:
        if parent.name == TEAM_FOLDER and (parent.parent / ".git").exists():
            return parent
    return None


def prepare_team_folder(path: Path) -> None:
    """Before writing `path`: a team folder being made for it gets a `.gitattributes` that keeps line endings LF."""
    team = team_folder_of(path)
    if team is None or team.exists():
        return
    team.mkdir(parents=True, exist_ok=True)
    (team / ".gitattributes").write_bytes(TEAM_GITATTRIBUTES.encode("utf-8"))


def is_split(root: Path) -> bool:
    return (root / "shared" / "kb.json").is_file()


def home(root: Path) -> Path:
    """Where the files that span every project live: kb.json, daily plans, reminders, goals, people."""
    return root / "shared" if is_split(root) else root


def private_dir(root: Path, sid: str) -> Path:
    return root / sid if is_split(root) else root / "projects" / sid


@functools.lru_cache(maxsize=64)
def _git_toplevel(cwd: str) -> tuple[str, str]:
    """The checkout `cwd` is in, and the git dir its repository shares with its other worktrees."""
    try:
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel", "--git-common-dir"],
                             capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return "", ""
    if out.returncode != 0:
        return "", ""
    lines = out.stdout.strip().split("\n")
    if len(lines) < 2:
        return "", ""
    common = Path(lines[1]) if Path(lines[1]).is_absolute() else Path(cwd) / lines[1]
    return lines[0], str(common.resolve())


def scope_checkout(sc: dict) -> Path | None:
    """The checkout whose `knowledgebase/` holds the scope's team entries: the worktree a session runs in when it
    is one of the scope's repository, otherwise the scope's main checkout. None for a scope without a repo on this
    Mac, such as the Overview, which is always private."""
    paths = [Path(os.path.expanduser(x)).resolve() for x in sc.get("paths") or []]
    main = next((x for x in paths if x.is_dir()), None)
    if main is None:
        return None
    here, here_common = _git_toplevel(os.getcwd())
    if here and Path(here).resolve() != main:
        _, main_common = _git_toplevel(str(main))
        if main_common and main_common == here_common:
            return Path(here)
    return main


def team_dir(root: Path, sid: str) -> Path | None:
    if not is_split(root):
        return None
    sc = scope_map(root).get(sid)
    checkout = scope_checkout(sc) if sc else None
    return checkout / TEAM_FOLDER if checkout else None


def scope_dirs(root: Path, sid: str) -> list[Path]:
    """Where a scope's entries are: the private folder first (it holds every entry), then the team folder, whose
    entries not copied in yet (a teammate's, just pulled) are read from there."""
    team = team_dir(root, sid)
    return [private_dir(root, sid)] + ([team] if team else [])


def entry_dir(root: Path, sid: str, section: str) -> Path:
    """Where a new entry goes: always the private folder. A shared one is copied to the team folder as well."""
    return private_dir(root, sid)


def is_team_path(root: Path, path: Path) -> bool:
    return any(path.resolve().is_relative_to(d.resolve()) for sc in load_registry(root)
               if (d := team_dir(root, sc["id"])))


def read_registry_file(root: Path) -> dict:
    try:
        data = json.loads((home(root) / "kb.json").read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def is_nested(data: dict) -> bool:
    return data.get("version") == 2 or any("scopes" in p for p in data.get("projects", []) if isinstance(p, dict))


def load_registry(root: Path) -> list[dict]:
    """Every scope, flat, with its `project`, `project_title` and `wide`. A scope is a folder `projects/<id>/`.

    kb.json v2 nests scopes in projects; in v1 each project is a scope that is its own project."""
    data = read_registry_file(root)
    out: list[dict] = []
    for p in data.get("projects", []):
        if not isinstance(p, dict) or not p.get("id"):
            continue
        if "scopes" in p:
            for sc in p.get("scopes") or []:
                if isinstance(sc, dict) and sc.get("id"):
                    out.append({**sc, "project": p["id"], "project_title": p.get("title") or p["id"],
                                "wide": bool(sc.get("wide"))})
        else:
            out.append({**p, "project": p["id"], "project_title": p.get("title") or p["id"], "wide": True})
    return out


def load_projects(root: Path) -> list[dict]:
    """Projects in registry order: {"id", "title", "scopes": [scope ids]}."""
    groups: dict[str, dict] = {}
    for sc in load_registry(root):
        g = groups.setdefault(sc["project"], {"id": sc["project"], "title": sc["project_title"], "scopes": []})
        g["scopes"].append(sc["id"])
    return list(groups.values())


def save_registry(root: Path, projects: list[dict]) -> None:
    """Writes the flat scope list back: nested (v2) when the file is v2, flat (v1) otherwise."""
    path = home(root) / "kb.json"
    data = read_registry_file(root) or {"version": 1}
    if is_nested(data):
        meta = {p["id"]: {k: v for k, v in p.items() if k != "scopes"} for p in data.get("projects", []) if p.get("id")}
        nested: dict[str, list[dict]] = {}
        for sc in projects:
            pid = sc.get("project") or sc["id"]
            meta.setdefault(pid, {"id": pid, "title": sc.get("project_title") or pid})
            clean = {k: v for k, v in sc.items() if k not in SCOPE_ADDED_KEYS}
            if not clean.get("wide"):
                clean.pop("wide", None)
            nested.setdefault(pid, []).append(clean)
        data["version"] = 2
        data["projects"] = [{**m, "scopes": nested[pid]} for pid, m in meta.items() if pid in nested]
    else:
        data["projects"] = [{k: v for k, v in sc.items() if k not in (*SCOPE_ADDED_KEYS, "wide")} for sc in projects]
    write_atomic(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def scope_map(root: Path) -> dict[str, dict]:
    return {sc["id"]: sc for sc in load_registry(root)}


def scope_members(root: Path, sid: str) -> list[str]:
    """The scopes `sid` shows: itself and what it includes. The Overview (the wide scope) shows every scope in
    the app; in the legacy layout a project-wide scope shows its own project."""
    known = scope_map(root)
    sc = known.get(sid)
    if not sc:
        return [sid]
    if sc.get("wide"):
        return [x["id"] for x in known.values() if is_split(root) or x["project"] == sc["project"]]
    out, queue = [sid], list(sc.get("includes") or [])
    while queue:
        nxt = queue.pop()
        if nxt in known and nxt not in out:
            out.append(nxt)
            queue += known[nxt].get("includes") or []
    return out


def entry_scopes(e: "Entry") -> list[str]:
    """The entry's folder scope first, then the other scopes it is tagged with."""
    tagged = e.get("scopes") or []
    tagged = tagged if isinstance(tagged, list) else [x.strip() for x in str(tagged).split(",")]
    return list(dict.fromkeys([e.project, *[str(x) for x in tagged if x]]))


def check_scopes(root: Path, folder: str, scopes: list[str]) -> list[str]:
    """Validated scopes for an entry in `folder`: folder first, all in its project. Exits on a bad id."""
    known = scope_map(root)
    if folder not in known:
        sys.exit(f"kb: unknown scope {folder}")
    out = list(dict.fromkeys([folder, *[x.strip() for x in scopes if x.strip()]]))
    for sid in out:
        if sid not in known:
            sys.exit(f"kb: unknown scope {sid} (see `kb scope list`)")
        if known[sid]["project"] != known[folder]["project"]:
            sys.exit(f"kb: scope {sid} belongs to project {known[sid]['project']}, not {known[folder]['project']}")
    return out


def scopes_field(scopes: list[str]) -> list[tuple[str, object]]:
    """The `scopes` frontmatter field: only when the entry is in more than its folder scope."""
    return [("scopes", scopes)] if len(scopes) > 1 else []


def scope_entries(root: Path, sid: str) -> list["Entry"]:
    """Entries in scope `sid`: its own folder, and entries in other scopes of the project tagged with it."""
    own = project_entries(root, sid)
    sc = scope_map(root).get(sid)
    if not sc:
        return own
    for other in load_registry(root):
        if other["project"] == sc["project"] and other["id"] != sid:
            own += [e for e in project_entries(root, other["id"]) if sid in entry_scopes(e)[1:]]
    return own


def git_origin(cwd: Path) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(cwd), "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=3,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def resolve_project(projects: list[dict], cwd: Path) -> dict | None:
    """The scope a session works in: `KB_SCOPE` when the Mindmill app set it (a scope over several repositories), else
    the scope whose code folder holds `cwd`, else the one whose remote matches."""
    pinned = os.environ.get("KB_SCOPE", "").strip()
    if pinned:
        hit = next((p for p in projects if p["id"] == pinned), None)
        if hit:
            return hit
    cwd = cwd.resolve()
    best, best_len = None, -1
    for p in projects:
        for raw in p.get("paths", []):
            base = Path(os.path.expanduser(raw)).resolve()
            if cwd == base or base in cwd.parents:
                if len(str(base)) > best_len:
                    best, best_len = p, len(str(base))
    if best:
        return best
    origin = git_origin(cwd)
    if origin:
        for p in projects:
            if any(r and r in origin for r in p.get("remotes", [])):
                return p
    return None


# ---------------------------------------------------------------- entries


FM_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$")


def parse_value(raw: str):
    raw = raw.strip()
    if raw.startswith("[") and raw.endswith("]"):
        inner = raw[1:-1].strip()
        return [unquote(x) for x in split_list(inner)] if inner else []
    return unquote(raw)


def split_list(inner: str) -> list[str]:
    items, cur, quote = [], "", None
    for ch in inner:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            cur += ch
        elif ch == ",":
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def format_value(v) -> str:
    if isinstance(v, list):
        return "[" + ", ".join(quote_if_needed(str(x)) for x in v) + "]"
    return quote_if_needed(str(v))


def quote_if_needed(s: str) -> str:
    if s == "" or re.search(r"[:#\[\],]|^[\s\"'>|*&!%@`-]|\s$", s):
        return json.dumps(s, ensure_ascii=False)
    return s


def split_frontmatter(text: str) -> tuple[list[tuple[str, object]], str]:
    if not text.startswith("---"):
        return [], text
    lines = text.split("\n")
    if lines[0].strip() != "---":
        return [], text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fields = []
            for ln in lines[1:i]:
                m = FM_LINE.match(ln)
                if m:
                    fields.append((m.group(1), parse_value(m.group(2))))
            body = "\n".join(lines[i + 1:])
            return fields, body.lstrip("\n")
    return [], text


def render_entry(fields: list[tuple[str, object]], body: str) -> str:
    fm = "\n".join(f"{k}: {format_value(v)}" for k, v in fields if v not in (None, "", []))
    return f"---\n{fm}\n---\n\n{body.rstrip()}\n"


@dataclass
class Entry:
    id: str
    project: str
    section: str
    path: Path
    fields: list[tuple[str, object]] = field(default_factory=list)
    body: str = ""

    def get(self, key: str, default=""):
        for k, v in self.fields:
            if k == key:
                return v
        return default

    def set(self, key: str, value) -> None:
        for i, (k, _) in enumerate(self.fields):
            if k == key:
                self.fields[i] = (key, value)
                return
        self.fields.append((key, value))

    @property
    def title(self) -> str:
        return str(self.get("title") or self.path.stem)

    @property
    def date(self) -> str:
        return str(self.get("date") or "")

    @property
    def status(self) -> str:
        default = {"decisions": "active", "followups": "open", "backlog": "proposed",
                   "meetings": "filed", "discussions": "open", "ideas": "new", "research": "open"}.get(self.section, "")
        return str(self.get("status") or default)

    @property
    def summary(self) -> str:
        return str(self.get("summary") or "")

    def save(self) -> None:
        write_atomic(self.path, render_entry(self.fields, self.body))


def read_entry(root: Path, path: Path) -> Entry | None:
    """The entry at `path`, in any scope's team or private folder."""
    path = Path(path)
    if not is_split(root):
        try:
            rel = path.relative_to(root / "projects")
        except ValueError:
            return None
        return load_entry_file(path, rel.parts[0], Path(*rel.parts[1:])) if len(rel.parts) > 1 else None
    for sc in load_registry(root):
        for base in scope_dirs(root, sc["id"]):
            try:
                rel = path.resolve().relative_to(base.resolve())
            except ValueError:
                continue
            return load_entry_file(path, sc["id"], rel)
    return None


def load_entry_file(path: Path, project: str, rel: Path) -> Entry | None:
    """`rel` is the path inside the scope's folder: `overview.md` or `<section>/<stem>.md`."""
    parts = rel.parts
    if len(parts) == 1 and parts[0] == "overview.md":
        section = "overview"
    elif len(parts) == 2 and parts[0] in SECTIONS and parts[1].endswith(".md"):
        section = parts[0]
    else:
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    fields, body = split_frontmatter(text)
    stem = path.stem
    eid = f"{project}/overview" if section == "overview" else f"{project}/{section}/{stem}"
    return Entry(eid, project, section, path, fields, body)


def is_draft(e: Entry) -> bool:
    """Added by hand in the app and not saved yet: invisible to Claude and the CLI until saved."""
    return str(e.get("draft") or "").lower() == "true"


def project_entries(root: Path, project_id: str, drafts: bool = False) -> list[Entry]:
    """A scope's entries from its team folder and its private one. An id in both is read from the team folder."""
    out: list[Entry] = []
    seen: set[str] = set()
    for base in scope_dirs(root, project_id):
        files = [base / "overview.md"] + [p for section in SECTIONS if (base / section).is_dir()
                                          for p in sorted((base / section).glob("*.md"))]
        for p in files:
            if not p.exists():
                continue
            e = load_entry_file(p, project_id, p.relative_to(base))
            if e and e.id not in seen and (drafts or not is_draft(e)):
                seen.add(e.id)
                out.append(e)
    return out


def all_entries(root: Path) -> list[Entry]:
    out: list[Entry] = []
    if is_split(root):
        for sc in load_registry(root):
            out.extend(project_entries(root, sc["id"]))
        return out
    base = root / "projects"
    if base.is_dir():
        for d in sorted(base.iterdir()):
            if d.is_dir():
                out.extend(project_entries(root, d.name))
    return out


def entry_paths(root: Path, eid: str) -> list[Path]:
    """Where the entry with this id can be, team folder first."""
    eid = eid.strip().removesuffix(".md")
    parts = eid.split("/")
    if len(parts) == 2 and parts[1] == "overview":
        rel = Path("overview.md")
    elif len(parts) == 3:
        rel = Path(parts[1]) / f"{parts[2]}.md"
    else:
        return []
    return [d / rel for d in scope_dirs(root, parts[0])]


def find_entry(root: Path, eid: str) -> Entry | None:
    path = next((p for p in entry_paths(root, eid) if p.exists()), None)
    if path is None:
        return None
    parts = eid.strip().removesuffix(".md").split("/")
    base = path.parent if parts[-1] == "overview" else path.parent.parent
    return load_entry_file(path, parts[0], path.relative_to(base))


def by_date_desc(entries: list[Entry]) -> list[Entry]:
    return sorted(entries, key=lambda e: (e.date, e.title), reverse=True)


def write_atomic(path: Path, text: str) -> None:
    new = not path.exists()
    prepare_team_folder(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(text.encode("utf-8"))
    os.replace(tmp, path)
    note_entry_write(path, new)


def slugify(title: str) -> str:
    s = title.lower()
    for a, b in (("æ", "ae"), ("ø", "oe"), ("å", "aa"), ("ä", "ae"), ("ö", "oe"), ("ü", "ue")):
        s = s.replace(a, b)
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    if len(s) > 50:
        cut = s[:51].rfind("-")
        s = s[:cut] if cut > 20 else s[:50]
    return s.rstrip("-") or "untitled"


# ---------------------------------------------------------------- sharing
#
# Every entry lives in the scope's private folder, so the KB always has all of it. A shared entry also has a copy
# in the scope's repository (`<repo>/knowledgebase/`), committed and pushed with the code so the team sees it.
# `<private>/sharing.json` lists the shared ones by path inside the folder, with the content hash of the last sync.

SHARING_FILE = "sharing.json"
_touched_scopes: dict[str, set[str]] = {}
_sync_registered = False


def sharing_path(root: Path, sid: str) -> Path:
    return private_dir(root, sid) / SHARING_FILE


def load_sharing_file(root: Path, sid: str) -> dict:
    """{"shared": {path inside the folder: {"seen": {checkout: hash}}}, "branches": {checkout: branch}}."""
    try:
        data = json.loads(sharing_path(root, sid).read_text())
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    shared = data.get("shared") if isinstance(data.get("shared"), dict) else {}
    branches = data.get("branches") if isinstance(data.get("branches"), dict) else {}
    return {"shared": {k: v for k, v in shared.items() if isinstance(v, dict)}, "branches": branches}


def save_sharing_file(root: Path, sid: str, data: dict) -> None:
    path = sharing_path(root, sid)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    out = {"shared": dict(sorted(data["shared"].items())), "branches": data.get("branches") or {}}
    tmp.write_bytes((json.dumps(out, indent=2) + "\n").encode("utf-8"))
    os.replace(tmp, path)


def load_sharing(root: Path, sid: str) -> dict[str, dict]:
    return load_sharing_file(root, sid)["shared"]


def save_sharing(root: Path, sid: str, shared: dict[str, dict]) -> None:
    data = load_sharing_file(root, sid)
    data["shared"] = shared
    save_sharing_file(root, sid, data)


def entry_files(base: Path) -> dict[str, Path]:
    """The entry files in a scope folder, by path inside it: `overview.md` and `<section>/<stem>.md`."""
    out: dict[str, Path] = {}
    if (base / "overview.md").is_file():
        out["overview.md"] = base / "overview.md"
    for section in SECTIONS:
        d = base / section
        if d.is_dir():
            for p in d.glob("*.md"):
                if not p.name.startswith("."):
                    out[f"{section}/{p.name}"] = p
    return out


def file_hash(path: Path) -> str:
    try:
        return hashlib.sha1(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def scope_of_private_path(root: Path, path: Path) -> tuple[str, str] | None:
    """(scope, path inside its folder) for a file in a scope's private folder."""
    if not is_split(root):
        return None
    try:
        rel = path.resolve().relative_to(root.resolve())
    except ValueError:
        return None
    if len(rel.parts) < 2 or rel.parts[0] == "shared":
        return None
    inner = Path(*rel.parts[1:]).as_posix()
    if inner != "overview.md" and not (len(rel.parts) == 3 and rel.parts[1] in SECTIONS and inner.endswith(".md")):
        return None
    return rel.parts[0], inner


def note_entry_write(path: Path, new: bool) -> None:
    """After `kb` writes an entry: a new team-kind entry in a scope with a repository is shared, as it always was,
    and the scope's shared copies are brought in line when the command ends."""
    global _sync_registered
    try:
        root = kb_root()
    except SystemExit:
        return
    hit = scope_of_private_path(root, path)
    if not hit:
        return
    sid, rel = hit
    if sid not in scope_map(root):
        return
    section = "overview" if rel == "overview.md" else rel.split("/")[0]
    if new and shared_by_default(root, sid, section) and team_dir(root, sid):
        shared = load_sharing(root, sid)
        if rel not in shared:
            shared[rel] = {}
            save_sharing(root, sid, shared)
    _touched_scopes.setdefault(sid, set()).add(rel)
    if not _sync_registered:
        import atexit
        atexit.register(lambda: [share_sync(root, x, push=rels) for x, rels in sorted(_touched_scopes.items())])
        _sync_registered = True


def sharing_defaults(root: Path, sid: str) -> dict[str, str]:
    """Each kind of entry's visibility when it is made: the scope's choice (settings.json `sharing`), else the team's
    knowledge shared and the rest private."""
    chosen = load_settings(root, sid).get("sharing")
    chosen = chosen if isinstance(chosen, dict) else {}
    out = {}
    for section in ("overview", *SECTIONS):
        if section == "inbox":
            continue
        v = chosen.get(section)
        out[section] = v if v in ("private", "shared") else ("shared" if section in TEAM_SECTIONS else "private")
    return out


def shared_by_default(root: Path, sid: str, section: str) -> bool:
    return sharing_defaults(root, sid).get(section) == "shared"


def is_draft_file(path: Path) -> bool:
    try:
        fields, _ = split_frontmatter(path.read_text(encoding="utf-8"))
    except OSError:
        return False
    return any(k == "draft" and str(v).lower() == "true" for k, v in fields)


def copy_entry(src: Path, dst: Path) -> None:
    import shutil
    prepare_team_folder(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.name}.tmp")
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def checkout_branch(checkout: Path) -> str | None:
    if not (checkout / ".git").exists():
        return None
    code, branch = git_out(checkout, "rev-parse", "--abbrev-ref", "HEAD")
    return branch if code == 0 else None


def share_sync(root: Path, sid: str, push: set[str] | None = None) -> list[str]:
    """Brings a scope's private folder and the shared copies in the checkout `kb` works in (a session's worktree,
    else the main checkout) in line. What it remembers per checkout (the hash it last saw there) decides direction:
    - a repository copy that changed since (a pull, a teammate, an edit there) updates the private one;
    - a private change goes to this checkout only when it was made for it (`push`: written by `kb` or saved in the
      app here), so a session's edit in its worktree never lands as a stray change in the main checkout;
    - a teammate's new entry is copied in; a shared entry deleted here is deleted from the repository;
    - after a branch switch the private copies stay as they are, and a shared entry the branch doesn't have stays
      in the KB without being put back into that branch."""
    team = team_dir(root, sid)
    if not team:
        return []
    key = str(team.parent)
    priv = private_dir(root, sid)
    data = load_sharing_file(root, sid)
    shared, branches = data["shared"], data["branches"]
    before = json.dumps(data, sort_keys=True)
    push = push or set()
    branch = checkout_branch(team.parent)
    switched = key in branches and branches[key] != branch
    branches[key] = branch
    done: list[str] = []
    theirs = entry_files(team)
    for rel, t in theirs.items():
        p = priv / rel
        ht = file_hash(t)
        info = shared.get(rel)
        if not p.exists():
            if info is not None and info.get("seen"):
                t.unlink(missing_ok=True)
                shared.pop(rel, None)
                done.append(f"{sid}/{rel}: deleted here, so removed from the repository")
            else:
                copy_entry(t, p)
                shared[rel] = {"seen": {key: ht}}
                done.append(f"{sid}/{rel}: copied in from the repository")
            continue
        info = shared.setdefault(rel, {})
        seen = info.setdefault("seen", {})
        hp = file_hash(p)
        last = seen.get(key)
        if hp == ht:
            seen[key] = hp
        elif rel in push and not is_draft_file(p):
            copy_entry(p, t)
            seen[key] = hp
            done.append(f"{sid}/{rel}: copied to the repository")
        elif switched:
            seen[key] = ht
        elif last is not None and last != ht:
            copy_entry(t, p)
            seen[key] = ht
            done.append(f"{sid}/{rel}: updated from the repository")
    for rel, info in list(shared.items()):
        if rel in theirs:
            continue
        p = priv / rel
        if not p.exists():
            shared.pop(rel)
            continue
        seen = info.setdefault("seen", {})
        if (not seen or rel in push) and not is_draft_file(p):
            copy_entry(p, team / rel)
            seen[key] = file_hash(p)
            done.append(f"{sid}/{rel}: shared, copied to the repository")
    if json.dumps(data, sort_keys=True) != before:
        save_sharing_file(root, sid, data)
    return done


def entry_rel(e: "Entry") -> str:
    return "overview.md" if e.section == "overview" else f"{e.section}/{e.path.name}"


def set_shared(root: Path, e: "Entry", share: bool) -> str:
    """Shares an entry with the team (a copy goes in the repository) or makes it private again (the repository's
    copy is deleted; the deletion goes out with the next commit and push there)."""
    sid, rel = e.project, entry_rel(e)
    team = team_dir(root, sid)
    priv = private_dir(root, sid) / rel
    if not priv.exists() and e.path.exists():
        copy_entry(e.path, priv)
    shared = load_sharing(root, sid)
    if share:
        if not team:
            sys.exit(f"kb: {sid} has no repository on this Mac, so its entries can't be shared")
        shared[rel] = {"seen": {}}
        save_sharing(root, sid, shared)
        share_sync(root, sid, push={rel})
        return f"{e.id}: shared, copied to {team / rel}"
    shared.pop(rel, None)
    save_sharing(root, sid, shared)
    if team and (team / rel).exists():
        (team / rel).unlink()
        return f"{e.id}: private, removed from {team}"
    return f"{e.id}: private"


def git_out(cwd: Path, *args: str, timeout: int = 10) -> tuple[int, str]:
    try:
        r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as err:
        return 1, str(err)
    return r.returncode, (r.stdout if r.returncode == 0 else (r.stderr or r.stdout)).strip()


def share_status(root: Path, sid: str) -> dict:
    """Where each shared entry of a scope stands in its repository: uncommitted, committed but not pushed, pushed,
    or missing from the checked-out branch. Entries not listed are private."""
    team = team_dir(root, sid)
    out = {"repo": str(team.parent) if team else None, "branch": None, "upstream": None, "entries": {}}
    if not team:
        return out
    checkout = team.parent
    is_git = (checkout / ".git").exists()
    out["git"] = is_git
    if not is_git:
        for rel in load_sharing(root, sid):
            eid = f"{sid}/overview" if rel == "overview.md" else f"{sid}/{rel.removesuffix('.md')}"
            out["entries"][eid] = "local" if (team / rel).exists() else "missing"
        return out
    bc, branch = git_out(checkout, "rev-parse", "--abbrev-ref", "HEAD")
    code, upstream = git_out(checkout, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    out["branch"] = branch if bc == 0 else None
    out["upstream"] = upstream if code == 0 else None
    _, porcelain = git_out(checkout, "status", "--porcelain", "--untracked-files=all", "--", TEAM_FOLDER)
    dirty = set()
    for line in porcelain.splitlines():
        path = line[3:].split(" -> ")[-1].strip().strip('"')
        if path.startswith(TEAM_FOLDER + "/"):
            dirty.add(path[len(TEAM_FOLDER) + 1:])
    unpushed: set[str] | None = None
    if code == 0:
        _, names = git_out(checkout, "diff", "--name-only", "@{u}...HEAD", "--", TEAM_FOLDER)
        unpushed = {n[len(TEAM_FOLDER) + 1:] for n in names.splitlines() if n.startswith(TEAM_FOLDER + "/")}
    for rel in load_sharing(root, sid):
        eid = f"{sid}/overview" if rel == "overview.md" else f"{sid}/{rel.removesuffix('.md')}"
        if not (team / rel).exists():
            state = "missing"
        elif rel in dirty:
            state = "uncommitted"
        elif unpushed is None or rel in unpushed:
            state = "unpushed"
        else:
            state = "pushed"
        out["entries"][eid] = state
    return out


def cmd_share(a) -> int:
    root = kb_root()
    if a.action == "defaults":
        sid = current_scope(root, a.scope)
        out = {"scope": sid, "repo": str(team_dir(root, sid).parent) if team_dir(root, sid) else None,
               "defaults": sharing_defaults(root, sid)}
        if a.json:
            print(json.dumps(out, indent=2))
        else:
            for k, v in out["defaults"].items():
                print(f"{k}\t{v}")
        return 0
    if a.action == "default":
        sid = current_scope(root, a.scope)
        if a.section == "inbox" or a.section not in ("overview", *SECTIONS):
            sys.exit(f"kb: {a.section} has no sharing default")
        data = load_settings(root, sid)
        chosen = data.get("sharing") if isinstance(data.get("sharing"), dict) else {}
        chosen[a.section] = a.visibility
        data["sharing"] = chosen
        write_atomic(settings_path(root, sid), json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        changed = 0
        if a.apply:
            share = a.visibility == "shared"
            if share and not team_dir(root, sid):
                sys.exit(f"kb: {sid} has no repository on this Mac, so its entries can't be shared")
            shared = load_sharing(root, sid)
            for e in scope_entries(root, sid):
                if e.project != sid or e.section != a.section or (entry_rel(e) in shared) == share:
                    continue
                set_shared(root, e, share)
                changed += 1
        print(json.dumps({"changed": changed}) if a.json else f"{sid}: new {a.section} are {a.visibility}"
              + (f"; changed {changed} existing" if a.apply else ""))
        return 0
    if a.action == "set":
        e = find_entry(root, a.id)
        if not e:
            sys.exit(f"kb: no entry {a.id}")
        print(set_shared(root, e, a.visibility == "shared"))
        return 0
    sids = [a.scope] if getattr(a, "scope", None) else [sc["id"] for sc in load_registry(root)]
    if a.action == "sync" or getattr(a, "sync", False):
        pushes: dict[str, set[str]] = {}
        for eid in getattr(a, "push", None) or []:
            e = find_entry(root, eid)
            if e:
                pushes.setdefault(e.project, set()).add(entry_rel(e))
        lines = [line for sid in sids for line in share_sync(root, sid, push=pushes.get(sid))]
        if a.action == "sync":
            print("\n".join(lines) if lines else "in sync")
            return 0
    status = {sid: share_status(root, sid) for sid in sids}
    if a.json:
        print(json.dumps({"scopes": status}, indent=2))
        return 0
    for sid, st in status.items():
        if not st["repo"]:
            print(f"{sid}: no repository, everything private")
            continue
        print(f"{sid}: {st['repo']} on {st['branch']}")
        for eid, state in sorted(st["entries"].items()):
            print(f"  {state:12} {eid}")
    return 0


# ---------------------------------------------------------------- repositories


def scope_repos(root: Path, sid: str) -> list[dict]:
    """The repositories a scope works with: its own and those of the scopes it works on alongside it, then the
    reference ones it only takes knowledge from (read only). The Overview works on every repository of its project."""
    known = scope_map(root)
    sc = known.get(sid)
    if not sc:
        return []
    work = [x for x in scope_members(root, sid)]
    reference = [x for x in sc.get("related") or [] if x in known and x not in work]
    out, seen = [], set()
    for role, ids in (("work", work), ("reference", reference)):
        for x in ids:
            paths = known[x].get("paths") or []
            checkout = next((Path(os.path.expanduser(p)).resolve() for p in paths
                             if Path(os.path.expanduser(p)).is_dir()), None)
            if not paths:
                continue
            key = str(checkout) if checkout else f"missing:{x}"
            if key in seen:
                continue
            seen.add(key)
            out.append({"scope": x, "title": known[x].get("title") or x, "role": role,
                        "path": str(checkout) if checkout else None, "configured": paths[0]})
    return out


def repo_state(path: Path, fetch: bool = False) -> dict:
    if not (path / ".git").exists():
        return {"git": False}
    if fetch:
        git_out(path, "fetch", "--quiet", timeout=60)
    bc, branch = git_out(path, "rev-parse", "--abbrev-ref", "HEAD")
    branch = branch if bc == 0 else None
    code, upstream = git_out(path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    ahead = behind = 0
    if code == 0:
        c, counts = git_out(path, "rev-list", "--left-right", "--count", "HEAD...@{u}")
        if c == 0 and len(counts.split()) == 2:
            ahead, behind = (int(x) for x in counts.split())
    _, porcelain = git_out(path, "status", "--porcelain")
    changed = len([x for x in porcelain.splitlines() if x.strip()])
    return {"git": True, "branch": branch, "upstream": upstream if code == 0 else None,
            "ahead": ahead, "behind": behind, "changed": changed}


def pull_repo(path: Path) -> tuple[bool, str]:
    """Fast-forwards the checkout to its upstream. Refuses rather than merging or overwriting anything."""
    if not (path / ".git").exists():
        return False, "not a git repository"
    code, upstream = git_out(path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if code != 0:
        _, branch = git_out(path, "rev-parse", "--abbrev-ref", "HEAD")
        return False, f"{branch} has no remote branch to pull from"
    code, msg = git_out(path, "pull", "--ff-only", "--quiet", timeout=120)
    if code != 0:
        first = next((x for x in msg.splitlines() if x.strip()), msg)
        return False, first.removeprefix("fatal: ").removeprefix("error: ")
    st = repo_state(path)
    return True, f"up to date with {upstream}" + (f", {st['ahead']} local commit(s) not pushed" if st.get("ahead") else "")


def current_scope(root: Path, given: str | None) -> str:
    if given:
        if given not in scope_map(root):
            sys.exit(f"kb: unknown scope {given} (see `kb scope list`)")
        return given
    here = resolve_project(load_registry(root), Path(os.getcwd()))
    if not here:
        sys.exit("kb: no scope here; pass --scope <id>")
    return here["id"]


def cmd_repos(a) -> int:
    root = kb_root()
    sid = current_scope(root, a.scope)
    repos = scope_repos(root, sid)
    if a.repo:
        repos = [r for r in repos if a.repo in (r["scope"], r["title"], Path(r["path"] or "").name)]
        if not repos:
            sys.exit(f"kb: {a.repo} is not one of {sid}'s repositories")
    if a.action == "pull":
        ok = True
        for r in repos:
            if not r["path"]:
                print(f"{r['title']}: not on this Mac ({r['configured']})")
                continue
            done, msg = pull_repo(Path(r["path"]))
            ok &= done
            print(f"{r['title']}: {'pulled, ' if done else 'not pulled: '}{msg}")
            if done:
                for line in share_sync(root, r["scope"]):
                    print(f"  {line}")
        return 0 if ok else 1
    for r in repos:
        if r["path"]:
            r.update(repo_state(Path(r["path"]), fetch=a.fetch))
    if a.json:
        print(json.dumps({"scope": sid, "repos": repos}, indent=2))
        return 0
    for r in repos:
        role = "works on" if r["role"] == "work" else "knowledge only"
        if not r["path"]:
            print(f"{r['title']} ({role}): not on this Mac")
        elif not r.get("git"):
            print(f"{r['title']} ({role}): {r['path']}, not a git repository")
        else:
            bits = [r["branch"] or "?"]
            if r["behind"]:
                bits.append(f"{r['behind']} behind")
            if r["ahead"]:
                bits.append(f"{r['ahead']} ahead")
            if r["changed"]:
                bits.append(f"{r['changed']} changed file(s)")
            print(f"{r['title']} ({role}): {r['path']} · " + ", ".join(bits))
    return 0


# ---------------------------------------------------------------- context


def line_for(e: Entry, with_summary: bool = True) -> str:
    bits = [f"`{e.id}`"]
    if e.date:
        bits.append(e.date)
    head = " ".join(bits)
    tag = " [proposed]" if e.status == "proposed" else ""
    s = f" — {e.summary}" if with_summary and e.summary else ""
    return f"- {head} **{e.title}**{tag}{s}"


def followup_line(e: Entry) -> str:
    bits = [e.get("kind") or "question"]
    if e.get("owner"):
        bits.append(f"owner {e.get('owner')}")
    if e.get("due"):
        bits.append(f"due {e.get('due')}")
    return f"- `{e.id}` {e.date} **{e.title}** ({', '.join(bits)})"


def capped(lines: list[str], limit: int, what: str, project: str, section: str) -> list[str]:
    if len(lines) <= limit:
        return lines
    more = len(lines) - limit
    return lines[:limit] + [
        f"- …and {more} older {what}: `kb list --project {project} --section {section}`"
    ]


def build_context(root: Path, cwd: Path) -> str:
    projects = load_registry(root)
    kb = "kb"
    if not projects:
        return (
            f"# Knowledge base (kb plugin)\nNo knowledge base found at `{root}` (missing kb.json). "
            "Ask the user whether to set one up before relying on it."
        )
    project = resolve_project(projects, cwd)
    by_id = {p["id"]: p for p in projects}
    out: list[str] = ["# Knowledge base (kb plugin)", ""]
    plugin = Path(__file__).resolve().parent.parent
    out.append(f"Root: `{root}` · CLI: `kb` (or `{plugin / 'bin' / 'kb'}`) · format: "
               f"`{plugin / 'docs' / 'format.md'}`")
    if not project:
        names = ", ".join(f"`{p['id']}`" for p in projects)
        out += [
            "",
            f"This directory (`{cwd}`) is not registered with any project. Known projects: {names}.",
            "If the user starts real work here, offer once to register it "
            "(`kb register --id <id> --title <title> --path <dir>`). Otherwise stay quiet about the KB.",
        ]
        return "\n".join(out)

    pid = project["id"]
    entries = scope_entries(root, pid)
    siblings = [sc for sc in projects if sc["project"] == project["project"]]
    if len(siblings) > 1:
        out += ["", f"## Project: {project['project_title']} · scope {project.get('title', pid)} (`{pid}`)"]
        listed = [f"`{sc['id']}` ({sc.get('title', sc['id'])}{(', the Overview: everything' if is_split(root) else ', project-wide') if sc.get('wide') else ''})"
                  + (" ← this session" if sc["id"] == pid else "") for sc in siblings]
        out.append(f"Scopes of {project['project_title']}: " + ", ".join(listed) + ".")
    else:
        out += ["", f"## Project: {project.get('title', pid)} (`{pid}`)"]

    team = team_dir(root, pid)
    if team:
        out += ["", f"Every entry lives in the KB root. Shared ones (new decisions, facts, architecture, follow-ups and "
                    f"backlog items are shared by default; `kb share defaults` shows this scope's choice per kind) also have a copy in `{team}`, part of this repository, that "
                    "`kb` keeps in sync: write and edit entries with `kb` or in the KB root, and the shared copies' "
                    "changes belong in the commits and pull request of the work they come from. `kb share set <id> "
                    "private|shared` changes it when the user asks. Meetings, discussions, the inbox and notes stay "
                    "private unless the user shares them. Don't link a shared entry to a private one."]

    repos = scope_repos(root, pid)
    if len(repos) > 1 or any(r["role"] == "reference" for r in repos):
        work = [r for r in repos if r["role"] == "work"]
        ref = [r for r in repos if r["role"] == "reference"]
        out += ["", "### Repositories"]
        if work:
            out.append("Works on: " + "; ".join(f"{r['title']} `{r['path'] or r['configured'] + ' (not on this Mac)'}`"
                                                 for r in work) + ".")
        if ref:
            out.append("Knowledge only, read but never change: " + "; ".join(
                f"{r['title']} `{r['path'] or r['configured'] + ' (not on this Mac)'}`" for r in ref)
                + ". The user doesn't contribute to these: never edit, branch, commit, push or open pull requests "
                  "there; read their code and KB to learn how they work.")
        out.append("`kb repos --fetch` shows how far behind each is; `kb repos pull [--repo <scope>]` fast-forwards "
                   "them when the latest matters.")

    overview = next((e for e in entries if e.section == "overview"), None)
    if overview and overview.summary:
        out.append(overview.summary)

    decisions = by_date_desc([e for e in entries if e.section == "decisions"
                              and e.status in ("active", "proposed")])
    superseded = sum(1 for e in entries if e.section == "decisions" and e.status == "superseded")
    out += ["", f"### Decisions in force ({len(decisions)}; {superseded} superseded not listed)"]
    out += capped([line_for(e) for e in decisions], MAX_DECISIONS, "decisions", pid, "decisions") or ["- none yet"]

    facts = sorted([e for e in entries if e.section == "facts"], key=lambda e: e.title.lower())
    pending = {str(e.get("updates")): e.id for e in entries if e.section == "inbox" and e.get("updates")}
    out += ["", f"### Facts ({len(facts)})"]
    out += capped([line_for(e) + (f" — ⚠ may have changed (`{pending[e.id]}`)" if e.id in pending else "")
                   for e in facts], MAX_FACTS, "facts", pid, "facts") or ["- none yet"]

    arch = sorted([e for e in entries if e.section == "architecture"], key=lambda e: e.title.lower())
    if arch:
        out += ["", "### Architecture notes"] + [line_for(e) for e in arch]
    docs = project_docs(root, pid) if project.get("paths") else []
    if docs:
        out += ["", "### Project documentation (files in the repository; read them when the task touches them)"]
        out += [f"- `{d['path']}` {d['title']}" + (" (edited in the Mindmill app, not in the repository yet)" if d["draft"] else "")
                for d in docs[:MAX_FACTS]]

    today = dt.date.today().isoformat()
    meetings = by_date_desc([e for e in entries if e.section == "meetings"
                             and e.status not in ("scheduled", "cancelled")])
    if meetings:
        out += ["", f"### Recent meetings ({len(meetings)})"]
        out += [line_for(e) + (f" [{e.status}]" if e.status != "filed" else "")
                for e in meetings[:MAX_MEETINGS]]
    upcoming = sorted([e for e in entries if e.section == "meetings" and e.date >= today
                       and e.status in ("scheduled", "prepared")], key=lambda e: (e.date, str(e.get("start"))))
    if upcoming:
        out += ["", "### Upcoming meetings"]
        out += [f"- `{e.id}` {e.date} {e.get('start')} {e.title} [{e.status}]".replace("  ", " ")
                for e in upcoming[:MAX_MEETINGS]]

    followups = by_date_desc([e for e in entries if e.section == "followups" and e.status == "open"])
    if followups:
        out += ["", f"### Open follow-ups ({len(followups)})"]
        out += capped([followup_line(e) for e in followups], MAX_FOLLOWUPS, "follow-ups", pid, "followups")

    discussions = sorted([e for e in entries if e.section == "discussions" and e.status == "open"],
                         key=lambda e: str(e.get("updated") or e.date), reverse=True)
    if discussions:
        out += ["", f"### Open discussions ({len(discussions)}), not settled: don't treat them as decisions"]
        out += [f"- `{e.id}` **{e.title}**" + (f" — waiting on {e.get('waiting_on')}" if e.get("waiting_on") else "")
                + (f" — {e.summary}" if e.summary else "") for e in discussions[:MAX_FOLLOWUPS]]

    refs = by_date_desc([e for e in entries if e.section == "references"])
    if refs:
        out += ["", f"### Saved references ({len(refs)}): copies of artifacts, emails, pages and documents; "
                    "read one with `kb show <id>` when it bears on the task"]
        out += capped([f"- `{e.id}` {e.get('kind') or 'web'}: **{e.title}**" + (f" — {e.summary}" if e.summary else "")
                       for e in refs], MAX_FOLLOWUPS, "references", pid, "references")

    research = sorted([e for e in entries if e.section == "research" and e.status in ("open", "review", "done")],
                      key=lambda e: str(e.get("updated") or e.date), reverse=True)
    if research:
        out += ["", f"### Research ({len(research)}): what was already looked into; read its summary and takeaways "
                    "(`kb show <id>`) before looking into the same thing again"]
        out += capped([f"- `{e.id}` [{e.status}] **{e.title}**" + (f" — {e.summary}" if e.summary else "")
                       for e in research], MAX_FOLLOWUPS, "research", pid, "research")
    ideas = sorted([e for e in entries if e.section == "ideas" and (e.status or "new") in ("new", "exploring")],
                   key=lambda e: str(e.get("updated") or e.date), reverse=True)
    if ideas:
        out += ["", f"### Open ideas ({len(ideas)}), not decided"]
        out += capped([f"- `{e.id}` **{e.title}**" + (f" — {e.summary}" if e.summary else "") for e in ideas],
                      MAX_FOLLOWUPS, "ideas", pid, "ideas")
    notes = sorted([e for e in entries if e.section == "notes" and (e.status or "open") == "open"],
                   key=lambda e: str(e.get("updated") or e.date), reverse=True)
    if notes:
        out += ["", f"### The user's notes ({len(notes)}), their own thoughts not filed anywhere yet; read one when it "
                    "bears on the task"]
        out += capped([f"- `{e.id}` **{e.title}**" + (f" — {e.summary}" if e.summary else "") for e in notes],
                      MAX_FOLLOWUPS, "notes", pid, "notes")

    proposed = [e for e in entries if e.section == "backlog" and e.status == "proposed"]
    inbox = [e for e in entries if e.section == "inbox"]
    if proposed or inbox:
        out += ["", f"Waiting for the user: {len(inbox)} inbox proposals, {len(proposed)} proposed backlog "
                    "items (`kb inbox list`, `kb list --section backlog`). These are not in force."]

    shown = {e.id for e in entries}
    related = [sc["id"] for sc in siblings if sc["id"] != pid] + list(project.get("related", []))
    for rid in dict.fromkeys(related):
        rp = by_id.get(rid)
        if not rp or rid == pid:
            continue
        rentries = [e for e in scope_entries(root, rid) if e.id not in shown]
        shown |= {e.id for e in rentries}
        rdec = by_date_desc([e for e in rentries if e.section == "decisions"
                             and e.status in ("active", "proposed")])
        rfacts = sorted([e for e in rentries if e.section == "facts"], key=lambda e: e.title.lower())
        if not rdec and not rfacts:
            continue
        out += ["", f"### Related, reference only: {rp.get('title', rid)} (`{rid}`)"]
        out += capped([line_for(e) for e in rdec], MAX_RELATED_DECISIONS, "decisions", rid, "decisions")
        out += capped([line_for(e, with_summary=False) for e in rfacts], MAX_RELATED_FACTS, "facts", rid, "facts")

    goals = [g for g in all_goals(root) if g.status == "active"]
    if goals:
        out += ["", "### Side goals (personal, background only; see rule 9)"]
        out += [f"- `{g.id}` {g.title}" + (f" ({g.get('horizon')})" if g.get("horizon") else "") for g in goals]

    out += ["", BEHAVIOUR.format(kb=kb, pid=pid)]
    if goals:
        out.append(GOALS_RULE)
    return "\n".join(out)


BEHAVIOUR = """### How to use the knowledge base in this session
The index above is a title list. Read a full entry (`{kb} show <id>`, or Read the file) before you rely on it.

1. **When the user starts a task**, check the index for entries that bear on it: decisions, facts, the
   architecture notes of the part you touch, references, research already done, open ideas, the user's notes and
   the project documentation. If any do, read them and open your first reply with a short **From the KB** block: at
   most five one-line bullets citing entry ids, and suggestions only where an entry changes how the task should be
   done. Say nothing when nothing is relevant. Keep them in mind while you work, not only at the start.
2. **The user overrides the KB.** If they decide against an entry in force, do it their way, then record it
   with the `mindmill:decide` skill: a new decision that supersedes the old one. Tell them in one line which entry
   you superseded. Never edit an old decision's body.
3. **New durable knowledge** the user tells you (something is done or dropped, a decision, a constraint, a fact
   about another team or system, a new action) goes in the KB, not in Claude's auto-memory or only in meeting
   notes. If the user asked for it, write it (`mindmill:decide`, `kb new fact`, `kb new followup`). If they only
   mentioned it ("that's done already"), check whether the KB has it, then ask once (AskUserQuestion, or a
   `choices` block in the Mindmill app) what to record and where, for example "Follow-up in <scope>, marked done",
   and write it on yes. Pick the scope by what the item is about (rule 6). What you noticed yourself, without
   the user saying it, is proposed where it belongs, for the user to add or dismiss with one click:
   `kb inbox add --section <facts|decisions|ideas|followups|references|architecture|notes|backlog>
   --proposed-by session:<session id> --title … --summary … --reason "<what showed it>"` (in the Mindmill app
   `$KB_SESSION_ID` is the session id). Propose as you go when something durable comes up (a fact about the
   code or a system, a decision taken in passing, an idea for later, a loose end, a page worth keeping), at most a
   few per task, after checking with `kb search` that it isn't there already, and say so in one line.
4. **Meetings** run through `mindmill:meeting` (and `mindmill:prep`); work items through `mindmill:work-item`; questions
   that need more than the index through `mindmill:ask`; "start my day" through `mindmill:today`.
5. Entries can be edited by the user at any time in the Mindmill app. The prompt hook reports files that changed
   since your last turn; reread those before using them.
6. **Scopes.** Everything you write goes under this session's scope `{pid}` unless it belongs elsewhere. A
   project is split into scopes (listed at the top). Write each entry in the scope it mainly belongs to
   (`kb new … --project <scope>`, plus `--cross-project` when that isn't `{pid}`) and tag it with every
   other scope of the project it holds specific details for, e.g. `--scopes product,android`. A
   project-wide entry with Android-specific details gets both; an Android-only detail stays Android; never
   copy an entry into several scopes. Retag existing entries with `{kb} scopes <id> --add <scope>`. Scopes
   of other projects and related ones are for reference only.
7. Do not commit in the KB repo unless the user asked for it. **The KB is private to this machine:** never
   put KB entry ids, KB file paths or `kb://` links in anything others read (work items, pull requests, commit
   messages, review comments, chat or email). Say where something comes from in words ("decided in sprint
   planning, 2026-11-09").
8. **Facts that may have changed.** When something in this session (a decision, a meeting, the code, the
   user) shows a fact in the index may no longer hold, don't edit the fact. Run
   `{kb} fact challenge <fact id> --by <what showed it> --question '<what may have changed>'`, with the
   corrected text on stdin and `--body-stdin` when you know it, and say so in one line. The user decides in
   the Mindmill app."""

GOALS_RULE = """9. **Side goals** are the user's personal long-term goals, a quiet background agenda. When what
   the user did in this session moves one of them forward, propose it as a line for the goal's log:
   `kb goal propose <goal id> "<what was done, in one line, in words>"`; the user adds it or dismisses it.
   When a task naturally gives a chance to move toward one, add at most one short line at the end of your
   brief or summary ("Side goal: …"). Never change a task's scope or priority for a goal, never raise one
   during a live meeting, and stay silent when nothing fits."""


# ---------------------------------------------------------------- session state


def state_dir() -> Path:
    base = os.environ.get("CLAUDE_PLUGIN_DATA") or str(Path("~/.local/state/kb").expanduser())
    d = Path(base) / "sessions"
    d.mkdir(parents=True, exist_ok=True)
    return d


def scope_snapshot(root: Path, project_ids: list[str]) -> dict[str, float]:
    snap: dict[str, float] = {}
    for pid in project_ids:
        for base in scope_dirs(root, pid):
            if not base.is_dir():
                continue
            for p in base.rglob("*.md"):
                try:
                    snap[str(p)] = p.stat().st_mtime
                except OSError:
                    pass
    return snap


def scope_ids(root: Path, cwd: Path) -> list[str]:
    projects = load_registry(root)
    project = resolve_project(projects, cwd)
    if not project:
        return []
    return [project["id"], *project.get("related", [])]


def safe_session_id(sid: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "", sid)[:80] or "unknown"


def load_state(sid: str) -> dict:
    try:
        return json.loads((state_dir() / f"{safe_session_id(sid)}.json").read_text())
    except (OSError, ValueError):
        return {}


def save_state(sid: str, state: dict) -> None:
    write_atomic(state_dir() / f"{safe_session_id(sid)}.json", json.dumps(state))


# ---------------------------------------------------------------- hooks


def hook_session_start(payload: dict) -> None:
    root = kb_root()
    cwd = Path(payload.get("cwd") or os.getcwd())
    ctx = build_context(root, cwd)
    sid = payload.get("session_id", "")
    if sid and "How to use the knowledge base" in ctx:
        ctx += f"\n\nThis session's id (for `--proposed-by session:<id>`): `{sid}`"
    if sid:
        ids = scope_ids(root, cwd)
        save_state(sid, {"root": str(root), "scope": ids, "snapshot": scope_snapshot(root, ids)})
    emit("SessionStart", ctx)


def hook_prompt(payload: dict) -> None:
    sid = payload.get("session_id", "")
    if not sid:
        return
    state = load_state(sid)
    if not state:
        return
    root = Path(state.get("root") or kb_root())
    ids = state.get("scope", [])
    old: dict = state.get("snapshot", {})
    new = scope_snapshot(root, ids)
    changed = [p for p, m in new.items() if old.get(p) != m]
    removed = [p for p in old if p not in new]
    if not changed and not removed:
        return
    state["snapshot"] = new
    save_state(sid, state)
    lines = ["KB entries changed outside this session since your last turn (reread before relying on them):"]
    for p in sorted(changed)[:15]:
        e = read_entry(root, Path(p))
        if e:
            lines.append(f"- {'new' if p not in old else 'edited'}: `{e.id}` {e.title}"
                         + (f" [{e.status}]" if e.section == "decisions" else ""))
    for p in sorted(removed)[:5]:
        lines.append(f"- deleted: {Path(p).name}")
    if len(changed) > 15:
        lines.append(f"- …and {len(changed) - 15} more")
    emit("UserPromptSubmit", "\n".join(lines))


def sync_after_edit(path: str) -> None:
    """Claude edited an entry file with Edit or Write: a shared entry's private copy goes to this checkout's
    repository, and an edit to a repository copy comes back into the KB."""
    if not path.endswith(".md"):
        return
    try:
        root = kb_root()
    except SystemExit:
        return
    p = Path(path)
    hit = scope_of_private_path(root, p)
    if hit and hit[0] in scope_map(root):
        if hit[1] in load_sharing(root, hit[0]):
            share_sync(root, hit[0], push={hit[1]})
        return
    for sc in load_registry(root):
        team = team_dir(root, sc["id"])
        if team and p.resolve().is_relative_to(team.resolve()):
            share_sync(root, sc["id"])
            return


def hook_post_tool(payload: dict) -> None:
    """Claude's own writes to the KB are not news to Claude: fold them into the snapshot."""
    sid = payload.get("session_id", "")
    tool_input = payload.get("tool_input") or {}
    path = tool_input.get("file_path") or ""
    if path and payload.get("tool_name") in ("Edit", "Write", "MultiEdit"):
        sync_after_edit(path)
    if not sid:
        return
    state = load_state(sid)
    if not state:
        return
    if payload.get("tool_name") == "Bash":
        if re.search(r"(^|[\s/;&|(])kb(\.py)?\s", str(tool_input.get("command", ""))):
            state["snapshot"] = scope_snapshot(Path(state.get("root") or kb_root()), state.get("scope", []))
            save_state(sid, state)
        return
    if not path:
        return
    p = Path(path).resolve()
    root = Path(state.get("root") or kb_root())
    if root not in p.parents:
        return
    try:
        state.setdefault("snapshot", {})[str(p)] = p.stat().st_mtime
    except OSError:
        state.get("snapshot", {}).pop(str(p), None)
    save_state(sid, state)


def emit(event: str, text: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}))


def run_hook(event: str) -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        {"session-start": hook_session_start, "prompt": hook_prompt, "post-tool": hook_post_tool}[event](payload)
    except Exception as exc:  # a hook must never break the session
        print(f"kb hook {event} failed: {exc}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------- commands


IDEA_TEMPLATE = "## The idea\n{body}\n\n## Brainstorm\n\n## Open questions\n\n## Next steps\n\n## Turned into\n"
RESEARCH_TEMPLATE = ("## Question\n{body}\n\n## Findings\n\n## Open questions\n\n## Sources\n\n## Summary\n\n"
                     "## Takeaways\n")
RESEARCH_NOTE = {"finding": ("Findings", "- "), "question": ("Open questions", "- [ ] "), "source": ("Sources", "- "),
                 "takeaway": ("Takeaways", "- ")}
NOTE_TEMPLATE = "## Notes\n{body}\n\n## Summary\n\n## Filed\n"
IDEA_NOTE = {"thought": ("Brainstorm", "- "), "question": ("Open questions", "- [ ] "), "step": ("Next steps", "- [ ] "),
             "turned": ("Turned into", "- ")}

TEMPLATES = {
    "decisions": "## Decision\n{body}\n\n## Why\n\n",
    "meetings": "## Questions\n\n## Raw notes\n\n",
    "facts": "{body}\n",
    "architecture": "{body}\n",
    "followups": "{body}\n",
    "backlog": "## Description\n{body}\n\n## Acceptance criteria\n- \n",
    "discussions": "## Summary\n{body}\n\n## Points raised\n\n## Open questions\n\n## Findings\n\n## Outcome\n",
    "references": "## Why it matters\n{body}\n\n## Content\n",
    "ideas": IDEA_TEMPLATE,
    "research": RESEARCH_TEMPLATE,
    "notes": NOTE_TEMPLATE,
}

STATUSES = {
    "decisions": ("active", "proposed", "superseded"),
    "followups": ("open", "done", "dropped"),
    "backlog": ("proposed", "created", "rejected"),
    "meetings": ("scheduled", "prepared", "live", "review", "filed", "cancelled"),
    "discussions": ("open", "parked", "concluded"),
    "ideas": ("new", "exploring", "shelved", "done"),
    "research": ("open", "review", "done", "parked"),
    "notes": ("open", "filed"),
}
WAITING_ON = ("me", "others", "nobody")


def cmd_context(a) -> int:
    print(build_context(kb_root(), Path(a.cwd or os.getcwd())))
    return 0


def cmd_resolve(a) -> int:
    root = kb_root()
    p = resolve_project(load_registry(root), Path(a.cwd or os.getcwd()))
    if not p:
        print("unregistered", file=sys.stderr)
        return 1
    print(p["id"])
    return 0


def entry_row(e: Entry) -> str:
    hidden = {"decisions": "active", "followups": "open", "backlog": "proposed", "meetings": "filed", "discussions": "open",
              "ideas": "new", "research": "open"}
    st = f" [{e.status}]" if e.status and e.status != hidden.get(e.section, "") else ""
    return f"{e.id}\t{e.date}\t{e.title}{st}\t{e.summary}"


def cmd_list(a) -> int:
    root = kb_root()
    pid = a.project or current_project_id(root)
    entries = all_entries(root) if a.all_projects else scope_entries(root, pid)
    if a.section:
        entries = [e for e in entries if e.section == a.section]
    else:
        entries = [e for e in entries if e.section != "inbox"]
    if not a.include_superseded:
        entries = [e for e in entries if e.status not in ("superseded", "rejected", "dropped")]
    for e in by_date_desc(entries):
        print(entry_row(e))
    return 0


def cmd_search(a) -> int:
    root = kb_root()
    terms = [t.lower() for t in a.query]
    entries = scope_entries(root, a.project) if a.project else all_entries(root)
    hits = []
    for e in entries:
        hay = " ".join([e.title, e.summary, " ".join(map(str, e.get("tags") or [])), e.body]).lower()
        if all(t in hay for t in terms):
            score = sum(hay.count(t) for t in terms) + (5 if all(t in e.title.lower() for t in terms) else 0)
            hits.append((score, e))
    for _, e in sorted(hits, key=lambda x: (-x[0], x[1].id)):
        print(entry_row(e))
    return 0 if hits else 1


def cmd_show(a) -> int:
    e = find_entry(kb_root(), a.id)
    if not e:
        print(f"no entry {a.id}", file=sys.stderr)
        return 1
    print(f"# {e.id}  ({e.path})")
    print(e.path.read_text(encoding="utf-8"))
    return 0


def current_project_id(root: Path) -> str:
    p = resolve_project(load_registry(root), Path(os.getcwd()))
    if not p:
        sys.exit("kb: this directory is not registered; pass --project")
    return p["id"]


def target_project(root: Path, requested: str | None, cross_project: bool) -> str:
    """The project to write into. Writing outside the session's own project needs an explicit flag."""
    here = resolve_project(load_registry(root), Path(os.getcwd()))
    pid = requested or current_project_id(root)
    if pid not in {p["id"] for p in load_registry(root)}:
        sys.exit(f"kb: unknown project {pid}")
    if here and pid != here["id"] and not cross_project:
        sys.exit(f"kb: this session belongs to {here['id']}, refusing to write into {pid}. "
                 "Confirm with the user that it belongs there, then pass --cross-project.")
    return pid


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    for i in range(2, 100):
        p = path.with_name(f"{path.stem}-{i}{path.suffix}")
        if not p.exists():
            return p
    sys.exit(f"kb: too many entries named {path.stem}")


def entry_path(root: Path, pid: str, section: str, title: str, date: str, slug: str | None = None) -> Path:
    base = slugify(slug or title)
    if section == "inbox":
        stem = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + base
    elif section in DATED_SECTIONS:
        stem = f"{date}-{base}"
    else:
        stem = base
    return unique_path(entry_dir(root, pid, section) / section / f"{stem}.md")


def parse_field_args(pairs: list[str] | None) -> list[tuple[str, object]]:
    out = []
    for raw in pairs or []:
        if "=" not in raw:
            sys.exit(f"kb: --field needs key=value, got {raw!r}")
        k, v = raw.split("=", 1)
        out.append((k.strip(), parse_value(v)))
    return out


def one_line(s: str) -> str:
    """Titles and summaries are one line: a line break, real or written as \\n, becomes a space."""
    return " ".join(str(s or "").replace("\\n", " ").split())


def fields_from_args(a, section: str, date: str) -> list[tuple[str, object]]:
    a.title = one_line(a.title)
    if getattr(a, "summary", None):
        a.summary = one_line(a.summary)
    fields: list[tuple[str, object]] = [("title", a.title), ("date", date)]
    if getattr(a, "kind_value", None):
        fields.append(("kind", a.kind_value))
    if section in STATUSES and section != "meetings":
        fields.append(("status", a.status or STATUSES[section][0]))
    elif section == "meetings" and a.status:
        fields.append(("status", a.status))
    if a.summary:
        fields.append(("summary", a.summary))
    if a.supersedes:
        fields.append(("supersedes", a.supersedes))
    if a.source:
        fields.append(("source", a.source if section != "backlog" else [s.strip() for s in a.source.split(",")]))
    if a.tags:
        fields.append(("tags", normalize_tags(a.tags.split(","))))
    if a.attendees:
        fields.append(("attendees", [t.strip() for t in a.attendees.split(",") if t.strip()]))
    # --field wins over the defaults above (status, kind), but not over title and date.
    extra = {k: v for k, v in parse_field_args(a.field) if k not in ("title", "date")}
    fields = [(k, extra.pop(k)) if k in extra else (k, v) for k, v in fields]
    fields += list(extra.items())
    if section == "followups" and "kind" not in dict(fields):
        fields.insert(2, ("kind", "action"))
    return fields


def read_body(a, section: str) -> str:
    if a.body_stdin:
        return sys.stdin.read()
    return TEMPLATES.get(section, "{body}\n").format(body=a.body or "")


def check_status(section: str, fields: list[tuple[str, object]]) -> None:
    status = dict(fields).get("status")
    if section in STATUSES and status and status not in STATUSES[section]:
        sys.exit(f"kb: status {status!r} is not one of {', '.join(STATUSES[section])} for {section}")


def cmd_new(a) -> int:
    root = kb_root()
    pid = target_project(root, a.project, a.cross_project)
    section = KIND_TO_SECTION[a.kind]
    date = a.date or dt.date.today().isoformat()
    if section == "followups":
        refuse_backlog_followup(a.title)
    fields = fields_from_args(a, section, date)
    check_status(section, fields)
    fields = [(k, v) for k, v in fields if k != "scopes"]
    fields += scopes_field(check_scopes(root, pid, (a.scopes or "").split(",")))
    path = entry_path(root, pid, section, a.title, date, a.slug)
    write_atomic(path, render_entry(fields, read_body(a, section)))
    new_id = f"{pid}/{section}/{path.stem}"
    if section == "decisions":
        for old in a.supersedes or []:
            mark_superseded(root, old, new_id)
    print(new_id)
    print(path)
    return 0


def mark_superseded(root: Path, old_id: str, new_id: str) -> None:
    old = find_entry(root, old_id)
    if not old:
        print(f"kb: warning: superseded entry {old_id} not found", file=sys.stderr)
        return
    old.set("status", "superseded")
    old.set("superseded_by", new_id)
    old.save()


def cmd_supersede(a) -> int:
    root = kb_root()
    new = find_entry(root, a.new)
    if not new:
        sys.exit(f"kb: no entry {a.new}")
    mark_superseded(root, a.old, new.id)
    sup = list(new.get("supersedes") or [])
    if a.old not in sup:
        new.set("supersedes", sup + [a.old])
        new.save()
    print(f"{a.old} superseded by {new.id}")
    return 0


# ---------------------------------------------------------------- inbox


def cmd_inbox(a) -> int:
    return {"add": inbox_add, "list": inbox_list, "approve": inbox_approve, "reject": inbox_reject}[a.action](a)


def inbox_add(a) -> int:
    root = kb_root()
    pid = target_project(root, a.project, a.cross_project)
    if a.section not in APPROVABLE:
        sys.exit(f"kb: --section must be one of {', '.join(APPROVABLE)}")
    if a.section == "followups":
        refuse_backlog_followup(a.title)
    date = a.date or dt.date.today().isoformat()
    fields = fields_from_args(a, a.section, date)
    check_status(a.section, fields)
    fields = [(k, v) for k, v in fields if k != "scopes"]
    fields += scopes_field(check_scopes(root, pid, (a.scopes or "").split(",")))
    fields += [("proposed_section", a.section), ("proposed_by", a.proposed_by), ("reason", a.reason or "")]
    path = entry_path(root, pid, "inbox", a.title, date, a.slug)
    write_atomic(path, render_entry(fields, read_body(a, a.section)))
    print(f"{pid}/inbox/{path.stem}")
    print(path)
    return 0


def inbox_entries(root: Path, project: str | None) -> list[Entry]:
    entries = project_entries(root, project) if project else all_entries(root)
    return sorted([e for e in entries if e.section == "inbox"], key=lambda e: e.id)


def inbox_list(a) -> int:
    for e in inbox_entries(kb_root(), a.project):
        if a.proposed_by and e.get("proposed_by") != a.proposed_by:
            continue
        line = f"{e.id}\t{e.get('proposed_section')}\t{e.title}\t{e.get('reason')}"
        print(line + (f"\t{e.get('updates')}" if e.get("updates") else ""))
    return 0


def inbox_approve(a) -> int:
    root = kb_root()
    e = find_entry(root, a.id)
    if not e or e.section != "inbox":
        sys.exit(f"kb: no inbox entry {a.id}")
    section = str(e.get("proposed_section"))
    if section not in APPROVABLE:
        sys.exit(f"kb: {a.id} has no valid proposed_section ({section!r})")
    fact = find_entry(root, str(e.get("updates"))) if e.get("updates") else None
    if fact and fact.section == "facts":
        apply_fact_change(root, e, fact)
        print(fact.id)
        print(fact.path)
        return 0
    fields = [(k, v) for k, v in e.fields if k not in INBOX_ONLY_FIELDS]
    date = str(dict(fields).get("date") or dt.date.today().isoformat())
    path = entry_path(root, e.project, section, e.title, date)
    write_atomic(path, render_entry(fields, e.body))
    new_id = f"{e.project}/{section}/{path.stem}"
    if section == "decisions":
        for old in dict(fields).get("supersedes") or []:
            mark_superseded(root, old, new_id)
    e.path.unlink()
    print(new_id)
    print(path)
    return 0


def inbox_reject(a) -> int:
    root = kb_root()
    e = find_entry(root, a.id)
    if not e or e.section != "inbox":
        sys.exit(f"kb: no inbox entry {a.id}")
    e.path.unlink()
    print(f"rejected {a.id}")
    return 0


# ---------------------------------------------------------------- fact changes


def pending_fact_changes(root: Path, project: str | None = None, fact: str | None = None) -> list[Entry]:
    out = [e for e in inbox_entries(root, project) if e.get("updates")]
    return [e for e in out if e.get("updates") == fact] if fact else out


def apply_fact_change(root: Path, change: Entry, fact: Entry) -> None:
    """Rewrites the fact in place (same file) with the proposed text, verified today."""
    updated = Entry(fact.id, fact.project, "facts", fact.path,
                    [(k, v) for k, v in change.fields if k not in INBOX_ONLY_FIELDS], change.body)
    updated.set("date", dt.date.today().isoformat())
    by = str(change.get("proposed_by") or "")
    if by and find_entry(root, by):
        updated.set("source", by)
    updated.save()
    change.path.unlink(missing_ok=True)


def cmd_fact(a) -> int:
    root = kb_root()
    if a.action == "link":
        fact, other = find_entry(root, a.id), find_entry(root, a.other)
        for x, raw in ((fact, a.id), (other, a.other)):
            if not x or x.section != "facts":
                sys.exit(f"kb: no fact {raw}")
        if fact.id == other.id:
            sys.exit("kb: a fact can't link to itself")
        if a.remove:
            # A link is stored on one side and read both ways: take it off both.
            for x, y in ((fact, other), (other, fact)):
                rel = as_list(x.get("related"))
                if y.id in rel:
                    x.set("related", [r for r in rel if r != y.id])
                    x.save()
            print(f"unlinked {fact.id} and {other.id}")
            return 0
        if fact.id not in as_list(other.get("related")):
            rel = as_list(fact.get("related"))
            if other.id not in rel:
                fact.set("related", rel + [other.id])
                fact.save()
        print(f"linked {fact.id} and {other.id}")
        return 0
    if a.action == "challenge":
        fact = find_entry(root, a.id)
        if not fact or fact.section != "facts":
            sys.exit(f"kb: no fact {a.id}")
        today = dt.date.today().isoformat()
        change = Entry("", fact.project, "inbox", fact.path, [(k, v) for k, v in fact.fields
                                                              if k not in INBOX_ONLY_FIELDS], fact.body)
        change.set("date", today)
        change.fields += [("proposed_section", "facts"), ("proposed_by", a.by),
                          ("reason", a.reason or a.question), ("updates", fact.id), ("question", a.question)]
        body = sys.stdin.read() if a.body_stdin else fact.body
        same = next((e for e in pending_fact_changes(root, fact.project, fact.id)
                     if e.get("proposed_by") == a.by), None)
        path = same.path if same else entry_path(root, fact.project, "inbox", fact.title, today)
        write_atomic(path, render_entry(change.fields, body))
        print(f"{fact.project}/inbox/{path.stem}")
        print(path)
        return 0
    if a.action == "changes":
        for e in pending_fact_changes(root, a.project, a.fact):
            print(f"{e.id}\t{e.get('updates')}\t{e.get('question')}\t{e.get('proposed_by')}")
        return 0
    change = find_entry(root, a.id)
    if not change or change.section != "inbox" or not change.get("updates"):
        sys.exit(f"kb: no pending fact change {a.id}")
    fact = find_entry(root, str(change.get("updates")))
    if not fact or fact.section != "facts":
        change.path.unlink()
        sys.exit(f"kb: the fact {change.get('updates')} no longer exists; dropped {change.id}")
    if a.update:
        apply_fact_change(root, change, fact)
        print(f"updated {fact.id}")
    elif a.keep:
        fact.set("date", dt.date.today().isoformat())
        fact.save()
        change.path.unlink()
        print(f"kept {fact.id} (verified today)")
    else:
        for e in pending_fact_changes(root, fact.project, fact.id):
            e.path.unlink(missing_ok=True)
        lines = delete_entry(root, find_entry(root, fact.id) or fact)
        print(f"removed {fact.id}")
        for line in lines:
            print(f"  {line}")
    return 0


# ---------------------------------------------------------------- crew (Build mode)


CREW_STALE_SECONDS = 120


def crew_dir() -> Path:
    env = os.environ.get("KB_CREW_DIR", "").strip()
    return Path(os.path.expanduser(env)) if env else app_data_dir() / "crew"


def crew_state() -> dict:
    try:
        data = json.loads((crew_dir() / "state.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def crew_is_stale(state: dict) -> bool:
    raw = str(state.get("updated") or "")
    try:
        t = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return True
    if t.tzinfo is None:
        t = t.astimezone()
    return (dt.datetime.now(dt.timezone.utc) - t).total_seconds() > CREW_STALE_SECONDS


STALE_WARNING = "kb: the Mindmill app doesn't seem to be running (no fresh crew state); orders wait until it is."


def crew_session(state: dict, ref: str) -> dict:
    """A session by full id, id prefix (4+), me, lead, overseer, or a title that matches exactly one."""
    sessions = [s for s in state.get("sessions") or [] if isinstance(s, dict) and s.get("id")]
    me = os.environ.get("KB_SESSION_ID", "").strip()
    by_id = {s["id"]: s for s in sessions}

    def listing(cands):
        return "\n".join(f"  {s['id'][:8]}  {s.get('title', '')} ({s.get('role', '')})" for s in cands)

    r = ref.strip()
    low = r.lower()
    if low in ("me", "lead"):
        if not me:
            sys.exit("kb: KB_SESSION_ID is not set; only sessions the Mindmill app runs know who they are")
        mine = by_id.get(me)
        if not mine:
            sys.exit(f"kb: this session ({me[:8]}) is not in the Mindmill app's crew state")
        if low == "me":
            return mine
        lead = by_id.get(str(mine.get("lead") or ""))
        if lead:
            return lead
        low = "overseer"  # a session with no lead reports to the overview session
    if low == "overseer":
        o = next((s for s in sessions if s.get("role") == "overseer"), None)
        if not o:
            sys.exit("kb: there is no overview session; start one in the Mindmill app's Build mode")
        return o
    if r in by_id:
        return by_id[r]
    if len(r) >= 4:
        hits = [s for s in sessions if s["id"].lower().startswith(low)]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            sys.exit(f"kb: {ref!r} matches several sessions:\n{listing(hits)}")
    exact = [s for s in sessions if str(s.get("title", "")).lower() == low]
    hits = exact or [s for s in sessions if low and low in str(s.get("title", "")).lower()]
    if len(hits) == 1:
        return hits[0]
    if hits:
        sys.exit(f"kb: {ref!r} matches several sessions; use an id:\n{listing(hits)}")
    sys.exit(f"kb: no session {ref!r}. Sessions:\n{listing(sessions) or '  (none)'}")


def queue_order(order: dict) -> Path:
    d = crew_dir() / "orders"
    d.mkdir(parents=True, exist_ok=True)
    name = f"{int(time.time() * 1000)}-{os.urandom(3).hex()}"
    tmp = d / f".{name}.tmp"
    tmp.write_text(json.dumps(order, ensure_ascii=False, indent=1), encoding="utf-8")
    final = d / f"{name}.json"
    os.replace(tmp, final)
    return final


SYNC_KINDS = ("calendar", "email", "tracker", "prs")
SYNC_OFFLINE = {
    "calendar": "the Mindmill app isn't running, so it can't sync the calendar. Run the mindmill:calendar skill yourself for "
                "{span}; it mirrors Outlook into the meeting files the same way.",
    "email": "the Mindmill app isn't running, so it can't scan email. Run the mindmill:email skill yourself.",
    "tracker": "nothing to sync without the Mindmill app: `kb tracker` reads Azure DevOps live.",
    "prs": "nothing to sync without the Mindmill app: `kb pr list` and `kb pr show` read Azure DevOps live.",
}


def sync_kinds(raw: list[str]) -> list[str]:
    kinds = []
    for w in raw or ["all"]:
        w = w.lower().strip()
        if w == "all":
            kinds += [k for k in SYNC_KINDS if k != "email"]
        elif w in ("pr", "prs", "pull-requests"):
            kinds.append("prs")
        elif w in ("mail", "email"):
            kinds.append("email")
        elif w in ("meetings", "calendar"):
            kinds.append("calendar")
        elif w in ("backlog", "work", "tracker"):
            kinds.append("tracker")
        else:
            sys.exit(f"kb: can't sync {w!r}; use calendar, email, tracker, prs or all")
    return list(dict.fromkeys(kinds))


def cmd_sync(a) -> int:
    """Has the Mindmill app sync now and waits for it, so a session can refresh what it reads instead of asking the user."""
    kinds = sync_kinds(a.what)
    for d in (a.date_from, a.date_to):
        if d and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
            sys.exit(f"kb: {d!r} isn't a date (YYYY-MM-DD)")
    span = f"{a.date_from} to {a.date_to}" if a.date_from and a.date_to else "today through the next two weeks"
    if crew_is_stale(crew_state()):
        for k in kinds:
            print(f"{k}: {SYNC_OFFLINE[k].format(span=span)}")
        return 1 if any(k in ("calendar", "email") for k in kinds) else 0
    rid = os.urandom(6).hex()
    out = crew_dir() / "sync" / f"{rid}.json"
    order = {"kind": "sync", "id": rid, "what": kinds, "from": os.environ.get("KB_SESSION_ID", "").strip() or "cli",
             "at": iso_now()}
    if a.date_from and a.date_to:
        order["range_from"], order["range_to"] = a.date_from, a.date_to
    queue_order(order)
    if a.no_wait:
        print(f"queued: sync {', '.join(kinds)}. The Mindmill app runs it within a few seconds.")
        return 0
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        try:
            result = json.loads(out.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            time.sleep(1)
            continue
        out.unlink(missing_ok=True)
        ok = True
        for r in result.get("results") or []:
            ok &= bool(r.get("ok"))
            line = r.get("line") or ("done" if r.get("ok") else "failed")
            print(line if line.startswith(f"{r.get('what')}:") else f"{r.get('what')}: {line}")
        return 0 if ok else 1
    print(f"sync: still running after {a.timeout}s; the Mindmill app finishes it. Read again in a minute.")
    return 2


def crew_line(s: dict, me: str, extra: tuple[str, ...]) -> str:
    bits = [f"{s.get('title') or 'Untitled'} [{str(s.get('id'))[:8]}]"]
    bits += [str(s.get(k)) for k in extra if s.get(k)]
    return " · ".join(bits) + (" (you)" if s.get("id") == me else "")


def cmd_crew(a) -> int:
    state = crew_state()
    stale = crew_is_stale(state)
    me = os.environ.get("KB_SESSION_ID", "").strip()
    sender = me or "cli"
    if a.action == "status":
        if a.json:
            print(json.dumps(state, ensure_ascii=False, indent=1))
            return 0
        if stale:
            print("⚠ The Mindmill app doesn't seem to be running: this state may be old.")
        sessions = [s for s in state.get("sessions") or [] if isinstance(s, dict) and s.get("id")]
        ids = {s["id"] for s in sessions}
        overseer = next((s for s in sessions if s.get("role") == "overseer"), None)
        print("Overview: " + (crew_line(overseer, me, ("state", "activity")) if overseer
                              else "none (start one in the Mindmill app's Build mode)"))
        parents = {str(s.get("lead")) for s in sessions if s.get("lead") in ids}
        leads = [s for s in sessions if s is not overseer and (s.get("role") == "lead" or s["id"] in parents)]
        shown = {s["id"] for s in leads} | ({overseer["id"]} if overseer else set())
        for lead in leads:
            print("★ " + crew_line(lead, me, ("project", "state", "activity", "strategy")))
            for m in sessions:
                if m.get("lead") == lead["id"]:
                    print("    ● " + crew_line(m, me, ("state", "activity", "model")))
                    shown.add(m["id"])
        rest = [s for s in sessions if s["id"] not in shown]
        if rest:
            print("Other sessions")
            for s in rest:
                print("  ○ " + crew_line(s, me, ("project", "state", "activity")))
        if not sessions:
            print("No sessions.")
        return 0
    if stale:
        print(STALE_WARNING, file=sys.stderr)

    def message(words: list[str], required: bool) -> str:
        if words == ["-"] or (not words and required):
            if required and sys.stdin.isatty():
                sys.exit("kb: give the message as words, or on stdin")
            return sys.stdin.read().strip()
        return " ".join(words).strip()

    if a.action == "send":
        target = crew_session(state, a.ref)
        text = message(a.message, True)
        if not text:
            sys.exit("kb: the message is empty")
        queue_order({"kind": "send", "to": target["id"], "text": text, "from": sender, "at": iso_now()})
        label = target.get("title") or target["id"][:8]
    elif a.action in ("stop", "archive"):
        target = crew_session(state, a.ref)
        queue_order({"kind": a.action, "to": target["id"], "from": sender, "at": iso_now()})
        label = target.get("title") or target["id"][:8]
    else:
        if a.lead and a.under:
            sys.exit("kb: --lead and --under exclude each other")
        parent = crew_session(state, a.under) if a.under else None
        queue_order({"kind": "start", "title": a.title, "parent": parent["id"] if parent else None,
                     "lead": bool(a.lead), "project": a.project, "model": a.model, "strategy": a.strategy,
                     "about": a.about, "text": message(a.message, False), "from": sender, "at": iso_now()})
        label = a.title + (f" (under {parent.get('title') or parent['id'][:8]})" if parent else "")
    print(f"queued: {a.action} → {label}")
    print("The Mindmill app delivers it within a few seconds.")
    return 0


def cmd_factory(a) -> int:
    me = os.environ.get("KB_SESSION_ID", "").strip()
    if a.action == "status":
        try:
            data = json.loads((crew_dir() / "factory.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            print("No software factory has run yet.")
            return 0
        for f in data.get("factories") or []:
            run = f.get("run") or {}
            print(f"{f.get('name')}: {run.get('status', 'not started')}"
                  + (f", ends {run['endsAt']}" if run.get("endsAt") else ""))
            for t in run.get("tasks") or []:
                state = "done" if t.get("finished") else "working"
                print(f"  #{t.get('workItem')} {t.get('title')} [{state}]" + (f" {t['outcome']}" if t.get("outcome") else ""))
            for q in run.get("questions") or []:
                if not q.get("answer"):
                    print(f"  ? #{q.get('workItem') or '-'} {q.get('text')}")
        return 0
    if not me:
        sys.exit("kb: KB_SESSION_ID is not set; only sessions the Mindmill app's factory starts can ask or log")
    if a.action == "ask":
        text = a.question.strip()
        if not text:
            sys.exit("kb: the question is empty")
        options = [o.strip() for o in a.option if o.strip()]
        queue_order({"kind": "factory_ask", "from": me, "text": text, "options": options,
                     "checkpoint": (a.checkpoint or "").strip(), "at": iso_now()})
        print("queued: the question shows in the Factory view. Carry on with what doesn't depend on the answer.")
        return 0
    text = " ".join(a.text).strip()
    if not text:
        sys.exit("kb: say what happened")
    queue_order({"kind": "factory_log", "from": me, "text": text, "at": iso_now()})
    print("logged")
    return 0


def cmd_test(a) -> int:
    """`kb test suggest`: a session proposes a change to the Mindmill app's test set-up; the user accepts or dismisses it."""
    text = (a.text or "").strip()
    if not text:
        sys.exit("kb: say what to change and why with --text")
    scope = (a.scope or os.environ.get("KB_SCOPE", "")).strip()
    if not scope:
        sys.exit("kb: which project? Pass --scope")
    changes: dict[str, str] = {}
    for item in a.set:
        key, sep, value = item.partition("=")
        if not sep or not key.strip():
            sys.exit(f"kb: --set takes key=value, got {item!r}")
        changes[key.strip()] = value.strip()
    order = {"kind": "test_suggest", "scope": scope, "text": text, "set": changes,
             "from": os.environ.get("KB_SESSION_ID", "").strip() or "cli", "at": iso_now()}
    if a.target:
        order["target"] = a.target.strip()
    queue_order(order)
    print("queued: the suggestion shows under Test in the Mindmill app for the user to accept or dismiss.")
    return 0


# ---------------------------------------------------------------- project scans
#
# A scan is a headless session the Mindmill app starts in a scope's repository. It reads the repo and records what it
# finds with `kb scan found`; nothing reaches the KB until the user ticks findings in the app, which runs
# `kb scan apply`. Each run is one JSON-lines file of events in the scans folder.

SCAN_KINDS = ("overview", "decisions", "facts", "architecture", "followups", "backlog", "docs")
SCAN_SOURCES = ("docs", "code", "history", "work", "knowledge")
SCAN_RUN_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z0-9-]+$")


def scans_dir() -> Path:
    env = os.environ.get("KB_SCANS_DIR", "").strip()
    return Path(os.path.expanduser(env)) if env else app_data_dir() / "scans"


def scan_file(run: str) -> Path:
    if not SCAN_RUN_RE.match(run or ""):
        sys.exit(f"kb: {run!r} is not a scan run id")
    path = scans_dir() / f"{run}.jsonl"
    if not path.is_file():
        sys.exit(f"kb: no scan {run}")
    return path


def scan_events(path: Path) -> list[dict]:
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict):
            out.append(ev)
    return out


def scan_append(path: Path, event: dict) -> None:
    event.setdefault("at", iso_now())
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def scan_state(path: Path) -> dict:
    """The run folded from its events: start, findings (each with a status), progress, done."""
    state = {"start": {}, "findings": {}, "progress": [], "done": None}
    for ev in scan_events(path):
        t = ev.get("type")
        if t == "start":
            state["start"] = ev
        elif t == "finding":
            state["findings"][ev["id"]] = dict(ev, status="pending")
        elif t == "progress":
            state["progress"].append(ev.get("text", ""))
        elif t == "done":
            state["done"] = ev
        elif t in ("applied", "dismissed") and ev.get("finding") in state["findings"]:
            f = state["findings"][ev["finding"]]
            f["status"] = t
            if ev.get("entry"):
                f["entry"] = ev["entry"]
    return state


def scan_relative_source(root: Path, sid: str, source: str) -> str:
    """Sources are kept repository-relative: a local absolute path never lands in a team entry."""
    src = one_line(source)
    sc = scope_map(root).get(sid)
    bases = [str(scope_checkout(sc) or "")] + [os.path.expanduser(x) for x in (sc or {}).get("paths") or []] if sc else []
    for base in bases:
        for b in {base.rstrip("/"), os.path.realpath(base) if base else ""}:
            if b and src.startswith(b + "/"):
                return src[len(b) + 1:]
    home_dir = str(Path.home())
    return src.replace(home_dir + "/", "~/") if src.startswith(home_dir) else src


def scan_new(a) -> int:
    root = kb_root()
    known = scope_map(root)
    if a.scope not in known:
        sys.exit(f"kb: unknown scope {a.scope}")
    kinds = [k.strip() for k in (a.kinds or ",".join(SCAN_KINDS)).split(",") if k.strip()]
    sources = [x.strip() for x in (a.sources or ",".join(SCAN_SOURCES)).split(",") if x.strip()]
    bad = [k for k in kinds if k not in SCAN_KINDS] + [x for x in sources if x not in SCAN_SOURCES]
    if bad:
        sys.exit(f"kb: unknown {', '.join(bad)} (kinds: {', '.join(SCAN_KINDS)}; sources: {', '.join(SCAN_SOURCES)})")
    scans_dir().mkdir(parents=True, exist_ok=True)
    run = f"{dt.datetime.now():%Y%m%d-%H%M%S}-{a.scope}"
    path = scans_dir() / f"{run}.jsonl"
    if path.exists():
        sys.exit(f"kb: scan {run} exists; try again in a second")
    scan_append(path, {"type": "start", "scope": a.scope, "kinds": kinds, "sources": sources,
                       "focus": one_line(a.focus or "")})
    print(run)
    return 0


def scan_found(a) -> int:
    root = kb_root()
    path = scan_file(a.run)
    state = scan_state(path)
    start = state["start"]
    if state["done"]:
        sys.exit("kb: this scan is finished")
    kind = a.kind
    if kind not in start.get("kinds", SCAN_KINDS):
        sys.exit(f"kb: this scan looks for {', '.join(start.get('kinds', []))}, not {kind}")
    target = a.scope or start.get("scope")
    known = scope_map(root)
    if target not in known or known[target]["project"] != known.get(start.get("scope"), {}).get("project"):
        sys.exit(f"kb: {target} is not a scope of the project being scanned")
    title = one_line(a.title or "")
    doc_path = None
    if kind == "docs":
        doc_path = doc_rel(a.path or "")
        title = title or doc_path
    if not title:
        sys.exit("kb: give a --title")
    if kind == "overview":
        title = title or known[target]["title"]
    updates = (a.updates or "").strip() or None
    if updates:
        old = find_entry(root, updates)
        if not old:
            sys.exit(f"kb: no entry {updates} to update")
        if kind not in ("overview", "docs") and old.section != kind:
            sys.exit(f"kb: {updates} is in {old.section}, not {kind}")
    for f in state["findings"].values():
        if f.get("kind") == kind and (f.get("title", "").lower() == title.lower() or (doc_path and f.get("path") == doc_path)):
            sys.exit(f"kb: already found as {f['id']}")
    if kind in APPROVABLE and not updates:
        same = next((e for e in scope_entries(root, target) if e.section == kind and e.title.lower() == title.lower()), None)
        if same:
            sys.exit(f"kb: already in the KB as {same.id}; pass --updates {same.id} if what it says changed")
    if kind == "docs":
        state_docs = load_docs_state(root, target)
        if doc_path in state_docs["docs"]:
            sys.exit(f"kb: {doc_path} is already in Project Docs")
    body = sys.stdin.read() if a.body_stdin else (a.body or "")
    if a.status and kind in STATUSES and a.status not in STATUSES[kind]:
        sys.exit(f"kb: status {a.status!r} is not one of {', '.join(STATUSES[kind])} for {kind}")
    fid = f"f{len(state['findings']) + 1}"
    finding = {"type": "finding", "id": fid, "kind": kind, "scope": target, "title": title,
               "summary": one_line(a.summary or ""), "body": body.strip(),
               "source": scan_relative_source(root, target, a.source or ""),
               "scopes": [x.strip() for x in (a.scopes or "").split(",") if x.strip()],
               "date": a.date or "", "status": a.status or "", "followup_kind": a.followup_kind or "",
               "updates": updates or "", "path": doc_path or "", "confidence": a.confidence or "medium"}
    scan_append(path, finding)
    print(fid)
    return 0


def scan_apply_one(root: Path, f: dict) -> str:
    """Writes one finding into the KB and returns the entry id (or the doc path for Project Docs)."""
    kind, sid = f["kind"], f["scope"]
    today = dt.date.today().isoformat()
    if kind == "docs":
        checkout = docs_checkout(root, sid)
        if not (checkout / f["path"]).is_file():
            sys.exit(f"kb: {f['path']} is no longer in {checkout.name}")
        state = load_docs_state(root, sid)
        state["docs"].append(f["path"])
        save_docs_state(root, sid, state)
        return f"{sid}/docs/{f['path']}"
    if kind == "overview":
        path = next((p for p in entry_paths(root, f"{sid}/overview") if p.exists()), None) \
            or entry_dir(root, sid, "overview") / "overview.md"
        old = split_frontmatter(path.read_text(encoding="utf-8")) if path.exists() else None
        fields = list(old[0]) if old else [("title", f["title"])]
        e = Entry(f"{sid}/overview", sid, "overview", path, fields, f["body"] + "\n")
        e.set("date", today)
        if f.get("summary"):
            e.set("summary", f["summary"])
        path.parent.mkdir(parents=True, exist_ok=True)
        e.save()
        return e.id
    old = find_entry(root, f["updates"]) if f.get("updates") else None
    scopes = check_scopes(root, old.project if old else sid, f.get("scopes") or [])
    if old and kind in ("facts", "architecture", "followups", "backlog"):
        e = Entry(old.id, old.project, old.section, old.path, list(old.fields), (f["body"] or old.body).rstrip() + "\n")
        e.set("title", f["title"])
        e.set("date", today)
        if f.get("summary"):
            e.set("summary", f["summary"])
        if f.get("source"):
            e.set("source", f["source"] if kind != "backlog" else [f["source"]])
        e.save()
        return e.id
    date = f.get("date") or today
    fields: list[tuple[str, object]] = [("title", f["title"]), ("date", date)]
    if kind == "followups":
        fields.append(("kind", f.get("followup_kind") or "action"))
    if kind in STATUSES:
        fields.append(("status", f.get("status") or STATUSES[kind][0]))
    if f.get("summary"):
        fields.append(("summary", f["summary"]))
    if old and kind == "decisions":
        fields.append(("supersedes", [old.id]))
    if f.get("source"):
        fields.append(("source", f["source"] if kind != "backlog" else [f["source"]]))
    fields += scopes_field(scopes)
    body = f["body"] + "\n" if f["body"] else TEMPLATES.get(kind, "{body}\n").format(body="")
    path = entry_path(root, sid, kind, f["title"], date)
    write_atomic(path, render_entry(fields, body))
    new_id = f"{sid}/{kind}/{path.stem}"
    if old and kind == "decisions":
        mark_superseded(root, old.id, new_id)
    return new_id


def scan_apply(a) -> int:
    root = kb_root()
    path = scan_file(a.run)
    state = scan_state(path)
    for fid in a.ids:
        f = state["findings"].get(fid)
        if not f:
            print(f"kb: no finding {fid}", file=sys.stderr)
            continue
        if f["status"] == "applied":
            print(f"{fid}\t{f.get('entry', '')}")
            continue
        entry = scan_apply_one(root, f)
        scan_append(path, {"type": "applied", "finding": fid, "entry": entry})
        print(f"{fid}\t{entry}")
    return 0


def cmd_scan(a) -> int:
    if a.action == "new":
        return scan_new(a)
    if a.action == "found":
        return scan_found(a)
    if a.action == "apply":
        return scan_apply(a)
    if a.action == "list":
        runs = sorted(scans_dir().glob("*.jsonl"), reverse=True) if scans_dir().is_dir() else []
        for p in runs:
            st = scan_state(p)
            n = len(st["findings"])
            left = sum(1 for f in st["findings"].values() if f["status"] == "pending")
            print(f"{p.stem}\t{st['start'].get('scope', '')}\t{'done' if st['done'] else 'running'}\t{n} found, {left} to review")
        return 0
    path = scan_file(a.run)
    if a.action == "show":
        st = scan_state(path)
        if a.json:
            print(json.dumps(st, indent=1, ensure_ascii=False))
        else:
            for f in st["findings"].values():
                print(f"{f['id']}\t{f['kind']}\t{f['status']}\t{f['title']}")
        return 0
    if a.action == "progress":
        text = one_line(" ".join(a.text))
        if not text:
            sys.exit("kb: say what you are looking at")
        scan_append(path, {"type": "progress", "text": text})
        print("noted")
        return 0
    if a.action == "dismiss":
        st = scan_state(path)
        for fid in a.ids:
            if st["findings"].get(fid, {}).get("status") == "pending":
                scan_append(path, {"type": "dismissed", "finding": fid})
        print(f"{len(a.ids)} dismissed")
        return 0
    if a.action == "done":
        if scan_state(path)["done"]:
            print("already done")
            return 0
        scan_append(path, {"type": "done", "note": one_line(a.note or ""), "failed": bool(a.failed)})
        print("done")
        return 0
    return 1


# ---------------------------------------------------------------- strategies


PLUGIN_ROOT = Path(__file__).resolve().parent.parent
SPAWN_MODES = ("none", "auto")


def all_strategies(root: Path) -> dict[str, tuple[Entry, str]]:
    """slug → (strategy, origin): built-in, custom, or override (a custom file replacing a built-in)."""
    out: dict[str, tuple[Entry, str]] = {}
    for base, origin in ((PLUGIN_ROOT / "strategies", "built-in"), (root / "strategies", "custom")):
        for path in sorted(base.glob("*.md")) if base.is_dir() else []:
            try:
                fields, body = split_frontmatter(path.read_text(encoding="utf-8"))
            except OSError:
                continue
            if origin == "custom" and path.stem in out:
                origin_here = "override"
            else:
                origin_here = origin
            out[path.stem] = (Entry(f"strategies/{path.stem}", "", "strategies", path, fields, body), origin_here)
    return out


def cmd_strategy(a) -> int:
    root = kb_root()
    known = all_strategies(root)
    if a.action == "list":
        for slug, (s, origin) in sorted(known.items(), key=lambda kv: kv[1][0].title.lower()):
            print(f"{slug}\t{s.title}\t{s.get('spawn') or 'none'}\t{origin}\t{s.summary}")
        return 0
    if a.action == "new":
        slug = slugify(a.slug or a.title)
        path = root / "strategies" / f"{slug}.md"
        if path.exists() and not a.force:
            sys.exit(f"kb: strategy {slug} exists; pass --force to replace it")
        body = sys.stdin.read() if a.body_stdin else (a.body or "")
        if not body.strip():
            sys.exit("kb: a strategy needs instructions (--body or --body-stdin)")
        fields: list[tuple[str, object]] = [("title", a.title), ("summary", a.summary or ""), ("spawn", a.spawn)]
        if a.max_sessions is not None:
            fields.append(("max_sessions", str(a.max_sessions)))
        fields.append(("model", a.model or ""))
        write_atomic(path, render_entry(fields, body))
        print(slug)
        print(path)
        return 0
    slug = slugify(a.slug)
    if slug not in known:
        sys.exit(f"kb: no strategy {a.slug} (`kb strategy list`)")
    s, origin = known[slug]
    if a.action == "show":
        print(s.path.read_text(encoding="utf-8"), end="")
        return 0
    if origin == "built-in":
        sys.exit(f"kb: {slug} is built in; save a strategy with the same slug to replace it")
    s.path.unlink()
    print(f"deleted {slug}" + (" (the built-in one is back)" if origin == "override" else ""))
    return 0


# ---------------------------------------------------------------- follow-ups


def resolved_by_value(values: list[str]):
    """One or more links (`--resolved-by` repeated, or comma separated) become a list; prose stays one string."""
    parts = []
    for v in values:
        pieces = [p.strip() for p in re.split(r"[,\s]+", v) if p.strip()]
        if pieces and all(p.startswith(("http://", "https://")) or p.count("/") == 2 for p in pieces):
            parts += pieces
        else:
            parts.append(v.strip())
    parts = list(dict.fromkeys(p for p in parts if p))
    return parts[0] if len(parts) == 1 else parts


def as_list(v) -> list[str]:
    if isinstance(v, list):
        return [str(x) for x in v if str(x).strip()]
    return [str(v)] if v not in (None, "") else []


def one_or_list(items: list[str]):
    items = list(dict.fromkeys(items))
    return items[0] if len(items) == 1 else items


def followup_merges_path(root: Path) -> Path:
    return home(root) / "followup-merges.json"


def load_followup_merges(root: Path) -> dict:
    try:
        data = json.loads(followup_merges_path(root).read_text())
    except (OSError, ValueError):
        data = {}
    return {"proposals": data.get("proposals") or [], "dismissed": data.get("dismissed") or []}


def save_followup_merges(root: Path, data: dict) -> None:
    write_atomic(followup_merges_path(root), json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def merge_pair(a: str, b: str) -> list[str]:
    return sorted([a, b])


def merge_followups(root: Path, keep: Entry, others: list[Entry]) -> None:
    """Folds duplicates into `keep`: it gains every source, resolution, tag and update; the others are dropped and
    point to it with `merged_into`."""
    today = dt.date.today().isoformat()
    raised = as_list(keep.get("raised_in"))
    resolved = as_list(keep.get("resolved_by"))
    tags = entry_tags(keep)
    dues = [d for d in [str(keep.get("due") or "")] if d]
    parts = []
    for o in others:
        raised += as_list(o.get("raised_in"))
        resolved += as_list(o.get("resolved_by"))
        tags = normalize_tags(tags + entry_tags(o))
        if o.get("due"):
            dues.append(str(o.get("due")))
        if not keep.get("owner") and o.get("owner"):
            keep.set("owner", o.get("owner"))
        text = o.body.strip()
        parts.append(f"### {o.title}\n\n" + (f"{o.summary}\n\n" if o.summary else "") + (text + "\n" if text else ""))
        o.set("status", "dropped")
        o.set("merged_into", keep.id)
        o.set("resolved_by", keep.id)
        o.set("summary", f"Merged into {keep.title}")
        o.set("closed", today)
        o.save()
    if raised:
        keep.set("raised_in", one_or_list(raised))
    if resolved:
        keep.set("resolved_by", one_or_list(resolved))
    keep.set("tags", tags)
    if dues:
        keep.set("due", min(dues))
    if parts:
        body = keep.body.rstrip("\n")
        keep.body = body + ("\n\n" if body.strip() else "") + "## Merged\n\n" + "\n".join(parts)
    keep.save()
    gone = {o.id for o in others} | {keep.id}
    data = load_followup_merges(root)
    data["proposals"] = [p for p in data["proposals"] if not {p["keep"], p["other"]} <= gone]
    save_followup_merges(root, data)


BACKLOG_TASK_RE = re.compile(
    r"^\s*(?:create|opret|lav|add|write|raise|propose)\s+(?:(?:an?|the|new|some|two|both|en|et|nye?)\s+)*"
    r"(?:(?:[\w./&-]+\s+){0,3}?)"
    r"(?:pbi\(s\)|(?:pbis?|bugs?|backlog[- ]items?|work[- ]items?|user stor(?:y|ies)|tickets?)\b)"
    r"(?:\s*(?:for|to|about|on|covering|til|om|:|-|–)\s+(?P<rest>.*)|[\s.]*)$", re.I)


def backlog_task_title(title: str) -> str | None:
    """For a follow-up whose only point is to create a PBI or bug ("Create an Android PBI for X"): the work it names
    ("X"), or the title itself when it names nothing more. None for any other follow-up."""
    m = BACKLOG_TASK_RE.match(title or "")
    if not m:
        return None
    rest = (m.group("rest") or "").strip().rstrip(".")
    return (rest[:1].upper() + rest[1:]) if rest else title.strip()


def refuse_backlog_followup(title: str) -> None:
    if backlog_task_title(title) is not None:
        sys.exit(f"kb: “{title}” is work for the tracker, not a follow-up. Propose it as a backlog item instead "
                 "(`kb new backlog --status proposed --field kind=pbi|bug --source <where it came from> …`, the "
                 "mindmill:work-item skill); it waits under Backlog → Suggested backlog items and is checked against the "
                 "tracker for duplicates.")


def followup_to_backlog(root: Path, e: "Entry") -> str:
    """Turns a "create a PBI" follow-up into a suggested backlog item and closes the follow-up as done, pointing at
    it. A backlog entry already made from the same source with the same work is reused rather than made twice."""
    title = backlog_task_title(e.title) or e.title
    kind = "bug" if re.search(r"\bbugs?\b", e.title, re.I) else "pbi"
    source = str(e.get("source") or e.get("raised_in") or e.id)
    bare = bare_title(title).lower()
    existing = next((x for x in backlog_entries(root) if x.project == e.project and x.status in ("proposed", "created")
                     and (bare_title(x.title).lower() == bare or (str(x.get("source") or "") == source
                                                                    and dice(dup_words(bare_title(x.title)), dup_words(bare)) >= 0.5))),
                    None)
    if existing:
        new_id = existing.id
    else:
        date = dt.date.today().isoformat()
        fields = [("title", title), ("date", date), ("status", "proposed"), ("kind", kind),
                  ("summary", str(e.get("summary") or "")), ("source", source)]
        fields += scopes_field(as_list(e.get("scopes")))
        path = entry_path(root, e.project, "backlog", title, date)
        body = re.split(r"(?m)^## Updates\s*$", e.body)[0].strip()
        write_atomic(path, render_entry([(k, v) for k, v in fields if v not in ("", None, [])], body + "\n" if body else ""))
        new_id = f"{e.project}/backlog/{path.stem}"
    e.set("status", "done")
    e.set("resolved_by", resolved_by_value([new_id]))
    e.save()
    return new_id


def cmd_followup(a) -> int:
    root = kb_root()
    if a.action == "to-backlog":
        e = find_entry(root, a.id)
        if not e or e.section != "followups":
            sys.exit(f"kb: no follow-up {a.id}")
        print(followup_to_backlog(root, e))
        return 0
    if a.action == "merges":
        data = load_followup_merges(root)
        if a.dismiss:
            pair = merge_pair(*a.dismiss)
            data["proposals"] = [p for p in data["proposals"] if merge_pair(p["keep"], p["other"]) != pair]
            if pair not in data["dismissed"]:
                data["dismissed"].append(pair)
            save_followup_merges(root, data)
            print("dismissed")
            return 0
        def is_open(eid):
            f = find_entry(root, eid)
            return bool(f) and f.status == "open"
        live = [p for p in data["proposals"] if is_open(p["keep"]) and is_open(p["other"])]
        print(json.dumps(live, ensure_ascii=False) if a.json else
              "\n".join(f"{p['keep']} <- {p['other']}  {p.get('why', '')}" for p in live))
        return 0
    e = find_entry(root, a.id)
    if not e or e.section != "followups":
        sys.exit(f"kb: no follow-up {a.id}")
    if a.action == "propose-merge":
        other = find_entry(root, a.other)
        if not other or other.section != "followups" or other.id == e.id:
            sys.exit(f"kb: no other follow-up {a.other}")
        data = load_followup_merges(root)
        pair = merge_pair(e.id, other.id)
        if pair in data["dismissed"]:
            print("the user said these are not the same")
            return 0
        if not any(merge_pair(p["keep"], p["other"]) == pair for p in data["proposals"]):
            data["proposals"].append({"keep": e.id, "other": other.id, "why": " ".join((a.why or "").split()),
                                      "date": dt.date.today().isoformat()})
            save_followup_merges(root, data)
        print(f"proposed merging {other.id} into {e.id}")
        return 0
    if a.action == "merge":
        others = []
        for oid in a.others:
            o = find_entry(root, oid)
            if not o or o.section != "followups" or o.id == e.id:
                sys.exit(f"kb: no other follow-up {oid}")
            others.append(o)
        merge_followups(root, e, others)
        print(f"merged {', '.join(o.id for o in others)} into {e.id}")
        return 0
    if a.action == "note":
        text = " ".join(a.text.split())
        if not text:
            sys.exit("kb: the note is empty")
        line = f"- {dt.date.today().isoformat()}: {text}" + (f" ({a.by})" if a.by else "")
        body = e.body.rstrip("\n")
        if re.search(r"(?m)^## Updates\s*$", body):
            body += "\n" + line
        else:
            body += ("\n\n" if body.strip() else "") + "## Updates\n\n" + line
        e.body = body + "\n"
        e.save()
        print(f"{a.id} noted")
        return 0
    e.set("status", a.status)
    if a.resolved_by:
        e.set("resolved_by", resolved_by_value(a.resolved_by))
    if a.answer:
        e.set("summary", a.answer)
    # Who closed it: `kb` when the app found it handled by itself, so the user can tell and reopen it.
    e.fields = [(k, v) for k, v in e.fields if k not in ("closed_by", "closed")]
    if a.status != "open":
        e.set("closed", dt.date.today().isoformat())
        if a.auto:
            e.set("closed_by", "kb")
    e.save()
    print(f"{a.id} {a.status}")
    return 0


# ---------------------------------------------------------------- settings


def settings_path(root: Path, pid: str) -> Path:
    return private_dir(root, pid) / "settings.json"


def load_settings(root: Path, pid: str) -> dict:
    try:
        return json.loads(settings_path(root, pid).read_text())
    except (OSError, ValueError):
        return {}


def cmd_settings(a) -> int:
    root = kb_root()
    pid = a.project or current_project_id(root)
    data = load_settings(root, pid)
    if a.action == "show":
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0
    keys = a.key.split(".")
    if a.action == "get":
        cur = data
        for k in keys:
            if not isinstance(cur, dict) or k not in cur:
                return 1
            cur = cur[k]
        print(cur if isinstance(cur, str) else json.dumps(cur, ensure_ascii=False))
        return 0
    try:
        value = json.loads(a.value)
    except ValueError:
        value = a.value
    cur = data
    for k in keys[:-1]:
        cur = cur.setdefault(k, {})
    cur[keys[-1]] = value
    write_atomic(settings_path(root, pid), json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"{pid}: {a.key} = {json.dumps(value, ensure_ascii=False)}")
    return 0


# ---------------------------------------------------------------- backlog → tracker


def ado_pat() -> str:
    if os.environ.get("KB_ADO_PAT"):
        return os.environ["KB_ADO_PAT"]
    try:
        for line in Path("~/.git-credentials").expanduser().read_text().splitlines():
            m = re.match(r"https://[^:]*:([^@]+)@dev\.azure\.com", line.strip())
            if m:
                return urllib.parse.unquote(m.group(1))
    except OSError:
        pass
    sys.exit("kb: no Azure DevOps PAT found in ~/.git-credentials")


def ado_request(method: str, url: str, pat: str, body=None, content_type="application/json"):
    import base64
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f":{pat}".encode()).decode())
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode() or "{}")


def ado_error_detail(exc, limit: int = 500) -> str:
    """The server's message, without the HTML page Azure DevOps sends for a wrong URL."""
    if not hasattr(exc, "read"):
        return str(exc)
    body = exc.read().decode(errors="replace")
    try:
        message = json.loads(body).get("message")
        if message:
            return str(message)[:limit]
    except (ValueError, AttributeError):
        pass
    if body.lstrip().lower().startswith(("<!doctype", "<html")):
        code = getattr(exc, "code", "")
        reason = getattr(exc, "reason", "")
        return f"HTTP {code} {reason} for {getattr(exc, 'url', '') or 'the request'}".strip()
    return body[:limit]


def ado_identity(value) -> str:
    """Who to assign: the KB keeps names, Azure DevOps resolves an email reliably, so a name found in the
    people directory is sent as its email. Anything else goes as written."""
    v = str(value).strip()
    if "@" in v:
        return v
    low = v.lower()
    for p in people_directory():
        if str(p.get("name", "")).lower() == low and p.get("email"):
            return p["email"]
    return v


def ado_tracker_missing(tracker: dict) -> list[str]:
    """The settings an Azure DevOps tracker cannot work without."""
    return [k for k in ("organization", "project") if not str(tracker.get(k) or "").strip()]


def ado_sprint(tracker: dict, pat: str, which: str) -> str | None:
    if which == "none" or not tracker.get("iteration_root"):
        return None
    sprints = [x for x in ado_sprints(tracker, pat) if x["when"] != "past"]
    current = [x for x in sprints if x["when"] == "current"]
    future = [x for x in sprints if x["when"] == "future"]
    pick = (current[:1] if which == "current" else future[:1])
    if not pick:
        sys.exit(f"kb: no {which} sprint under tracker.iteration_root {tracker['iteration_root']}; "
                 "see `kb tracker sprints` and update the root with `kb settings set tracker.iteration_root`")
    return pick[0]["path"]


def ado_sprints(tracker: dict, pat: str) -> list[dict]:
    """Leaf iterations under iteration_root, oldest first, each with `when`: past, current or future."""
    org, project = tracker["organization"], tracker["project"]
    url = (f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis/wit/classificationnodes/"
           "Iterations?api-version=7.1&$depth=5")
    tree = ado_request("GET", url, pat)
    out: list[dict] = []

    def walk(node, path):
        here = f"{path}\\{node['name']}" if path else node["name"]
        kids = node.get("children") or []
        attrs = node.get("attributes") or {}
        if not kids and attrs.get("startDate"):
            out.append({"name": node["name"], "path": here, "start": attrs["startDate"][:10],
                        "finish": attrs["finishDate"][:10]})
        for k in kids:
            walk(k, here)

    walk(tree, "")
    root_prefix = (tracker.get("iteration_root") or "").rstrip("\\")
    if root_prefix:
        out = [s for s in out if s["path"].startswith(root_prefix + "\\")]
    today = dt.date.today().isoformat()
    for s in out:
        s["when"] = sprint_when(s, today, out)
    return sorted(out, key=lambda s: s["start"])


STAGE_BY_STATE = {"new": "not_started", "approved": "not_started", "to do": "not_started", "proposed": "not_started",
                  "committed": "in_progress", "in progress": "in_progress", "active": "in_progress", "doing": "in_progress",
                  "blocked": "in_progress", "resolved": "resolved"}


def my_work(root: Path) -> dict:
    """The user's open PBIs and bugs across every Azure DevOps tracker in the KB, their PRs, and PRs to review,
    plus the open PBIs and bugs of every scope that uses Mindmill's own tracker."""
    projects = load_registry(root)
    trackers: dict[tuple[str, str], list[tuple[dict, dict]]] = {}
    for p in projects:
        t = load_settings(root, p["id"]).get("tracker") or {}
        if t.get("kind") == "azure-devops" and t.get("organization") and t.get("project"):
            trackers.setdefault((t["organization"], t["project"]), []).append((p, t))
    pat = ado_pat() if trackers else ""
    out = {"fetched": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "me": "", "items": [], "reviews": [],
           "sprints": {}}
    for (org, proj), owners in trackers.items():
        api = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis"
        me = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
        my_id = me.get("id", "")
        out["me"] = me.get("providerDisplayName", out["me"])

        def owner_of(title: str) -> dict:
            best = max(owners, key=lambda o: len(o[1].get("title_prefix") or "") if title.startswith(o[1].get("title_prefix") or "\0") else -1)
            if best[1].get("title_prefix") and title.startswith(best[1]["title_prefix"]):
                return best[0]
            return next((o[0] for o in owners if o[0].get("paths")), owners[0][0])

        wiql = ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.AssignedTo] = @Me "
                "AND [System.WorkItemType] IN ('Product Backlog Item', 'Bug') "
                "AND [System.State] NOT IN ('Done', 'Removed', 'Closed') ORDER BY [System.ChangedDate] DESC")
        ids = [w["id"] for w in ado_request("POST", f"{api}/wit/wiql?api-version=7.1&$top=100", pat, {"query": wiql}).get("workItems", [])]
        items: dict[int, dict] = {}
        for chunk in range(0, len(ids), 100):
            batch = ids[chunk:chunk + 100]
            fields = "System.Title,System.State,System.WorkItemType,System.IterationPath,System.ChangedDate"
            for w in ado_request("GET", f"{api}/wit/workitems?ids={','.join(map(str, batch))}&fields={fields}&api-version=7.1", pat).get("value", []):
                f = w["fields"]
                owner = owner_of(f["System.Title"])
                prefix = (load_settings(root, owner["id"]).get("tracker") or {}).get("title_prefix") or ""
                title = f["System.Title"]
                items[w["id"]] = {
                    "id": w["id"], "type": "bug" if f["System.WorkItemType"] == "Bug" else "pbi",
                    "title": title[len(prefix):] if prefix and title.startswith(prefix) else title,
                    "state": f["System.State"], "sprint": f.get("System.IterationPath", ""),
                    "changed": f.get("System.ChangedDate", ""), "project": owner["id"],
                    "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_workitems/edit/{w['id']}",
                    "stage": STAGE_BY_STATE.get(f["System.State"].lower(), "in_progress"), "prs": [],
                }
        prs = ado_request("GET", f"{api}/git/pullrequests?searchCriteria.status=active&$top=300&api-version=7.1", pat).get("value", [])
        review_repos = {o[0]["id"]: [r.split("_git/")[-1] for r in o[0].get("remotes", [])] for o in owners}
        my_repos = {r for it in items.values() for r in review_repos.get(it["project"], [])}
        my_repos |= set((owners[0][1].get("review_repos") or []))
        for pr in prs:
            repo = pr["repository"]["name"]
            url = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_git/{urllib.parse.quote(repo)}/pullrequest/{pr['pullRequestId']}"
            brief = {"id": pr["pullRequestId"], "title": pr["title"], "repo": repo, "url": url, "draft": bool(pr.get("isDraft")),
                     "author": pr["createdBy"].get("displayName", "")}
            mine = pr["createdBy"].get("id") == my_id
            reviewer = next((r for r in pr.get("reviewers", []) if r.get("id") == my_id), None)
            if mine:
                linked = ado_request("GET", f"{api}/git/repositories/{pr['repository']['id']}/pullRequests/{pr['pullRequestId']}/workitems?api-version=7.1", pat).get("value", [])
                for ref in linked:
                    wid = int(ref["id"])
                    if wid in items:
                        items[wid]["prs"].append(brief)
                        if items[wid]["stage"] != "resolved":
                            items[wid]["stage"] = "in_pr"
            elif not pr.get("isDraft") and ((reviewer and reviewer.get("vote", 0) == 0) or (not reviewer and repo in my_repos)):
                proj_id = next((pid for pid, repos in review_repos.items() if repo in repos), owners[0][0]["id"])
                out["reviews"].append({**brief, "project": proj_id, "required": bool(reviewer and reviewer.get("isRequired")),
                                       "assigned": bool(reviewer)})
        out["items"] += list(items.values())
        for p, t in owners:
            if t.get("iteration_root"):
                try:
                    cur = next((x["path"] for x in ado_sprints(t, pat) if x["when"] == "current"), None)
                except Exception:
                    cur = None
                if cur:
                    out["sprints"][p["id"]] = cur
    for sc in local_tracker_scopes(root):
        data = load_work_or_warn(root, sc["id"])
        if data is None:
            continue
        out["items"] += local_my_work(data, sc["id"])
        cur = current_sprint(data["sprints"]) if data["use_sprints"] else None
        if cur:
            out["sprints"][sc["id"]] = cur["name"]
    return out


def scopes_of_item(title: str, tags: list[str], owners: list[tuple[dict, dict]], wide: str) -> list[str]:
    """The scopes a work item belongs to, best first: its title prefix ("Android: "), then scopes named in the
    title's lead ("iOS/Android: …") or in its tags. Nothing matching means project-wide."""
    out: list[str] = []
    for sc, t in sorted(owners, key=lambda o: -len(o[1].get("title_prefix") or "")):
        prefix = t.get("title_prefix") or ""
        if prefix and title.startswith(prefix):
            out.append(sc["id"])
    lead = title.split(":", 1)[0] if ":" in title[:40] else ""
    low_tags = {x.lower() for x in tags}
    for sc, t in owners:
        word = (t.get("title_prefix") or "").strip().rstrip(":").strip()
        named = bool(word) and re.search(rf"(?<![A-Za-z]){re.escape(word)}(?![A-Za-z])", lead, re.I)
        tagged = any(x.lower() in low_tags for x in t.get("tags") or [])
        if (named or tagged) and sc["id"] not in out:
            out.append(sc["id"])
    return out or [wide]


TASK_STATE_ORDER = {"in progress": 0, "to do": 1, "new": 1, "done": 2, "closed": 2}


def task_is_done(state: str) -> bool:
    return state.lower() in ("done", "closed")


def task_order(t: dict) -> tuple:
    return (TASK_STATE_ORDER.get(t["state"].lower(), 1), t["id"])


def wiql_text(s: str) -> str:
    return s.replace("'", "''")


def backlog_condition(done_days: int, sprint: str | None, search: str | None) -> str:
    """Which PBIs and bugs to read: open and lately done ones; everything in one sprint; or those a search finds."""
    if search:
        q = search.strip().lstrip("#")
        if q.isdigit():
            return f"[System.Id] = {int(q)}"
        words = [w.strip("#!") for w in search.split() if w.strip("#!")]
        return "[System.State] <> 'Removed' AND " + " AND ".join(f"[System.Title] CONTAINS '{wiql_text(w)}'" for w in words)
    if sprint:
        return f"[System.IterationPath] = '{wiql_text(sprint)}' AND [System.State] <> 'Removed'"
    since = (dt.date.today() - dt.timedelta(days=done_days)).isoformat()
    return f"([System.State] NOT IN ('Done', 'Removed', 'Closed') OR ([System.State] = 'Done' AND [System.ChangedDate] >= '{since}'))"


STATE_CATEGORY_ORDER = ("Proposed", "InProgress", "Resolved", "Completed", "Removed")


def workflow_order(states: list[dict]) -> list[dict]:
    """Azure DevOps lists a type's states by name; this puts them from New to Removed."""
    def rank(x):
        cat = x["category"]
        return (STATE_CATEGORY_ORDER.index(cat) if cat in STATE_CATEGORY_ORDER else 2, x["name"] != "New",
                x["name"] == "Blocked")
    return sorted(states, key=rank)


def tracker_backlog(root: Path, done_days: int = 14, sprint: str | None = None, search: str | None = None) -> dict:
    """Every open PBI and bug in the trackers' area paths, plus ones done lately, with assignee, sprint and task progress.
    With `sprint`, every item in that iteration whatever its state; with `search`, the items whose title has every word
    (or whose id it is). Sprints and states are only read for the plain backlog."""
    full = not sprint and not search
    scopes = load_registry(root)
    wide_of = {sc["project"]: sc["id"] for sc in scopes if sc.get("wide")}
    trackers: dict[tuple[str, str], list[tuple[dict, dict]]] = {}
    for sc in scopes:
        t = load_settings(root, sc["id"]).get("tracker") or {}
        if t.get("kind") == "azure-devops" and t.get("organization") and t.get("project"):
            trackers.setdefault((t["organization"], t["project"]), []).append((sc, t))
    pat = ado_pat() if trackers else ""
    out = {"fetched": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "me": "", "items": [], "sprints": {}}
    condition = backlog_condition(done_days, sprint, search)
    by_id = bool(search) and search.strip().lstrip("#").isdigit()
    for (org, proj), owners in trackers.items():
        api = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis"
        me = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
        my_id = me.get("id", "")
        out["me"] = me.get("providerDisplayName", out["me"])
        areas = sorted({t["area_path"] for _, t in owners if t.get("area_path")})
        where_area = (" AND (" + " OR ".join(f"[System.AreaPath] UNDER '{wiql_text(x)}'" for x in areas) + ")") if areas and not by_id else ""
        wiql = ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
                f"{where_area} AND [System.WorkItemType] IN ('Product Backlog Item', 'Bug') "
                f"AND {condition} ORDER BY [System.ChangedDate] DESC")
        top = 50 if search else 500
        ids = [w["id"] for w in ado_request("POST", f"{api}/wit/wiql?api-version=7.1&$top={top}", pat, {"query": wiql}).get("workItems", [])][:top]
        active_prs = {pr["pullRequestId"] for pr in ado_request(
            "GET", f"{api}/git/pullrequests?searchCriteria.status=active&$top=500&api-version=7.1", pat).get("value", [])}
        rows: list[dict] = []
        children: dict[int, list[int]] = {}
        for chunk in range(0, len(ids), 200):
            batch = ids[chunk:chunk + 200]
            for w in ado_request("GET", f"{api}/wit/workitems?ids={','.join(map(str, batch))}&$expand=relations&api-version=7.1", pat).get("value", []):
                f = w["fields"]
                title = f["System.Title"]
                tags = [x.strip() for x in (f.get("System.Tags") or "").split(";") if x.strip()]
                item_scopes = scopes_of_item(title, tags, owners, wide_of.get(owners[0][0]["project"], owners[0][0]["id"]))
                prefix = next((t.get("title_prefix") or "" for sc, t in owners if sc["id"] == item_scopes[0]), "")
                who = f.get("System.AssignedTo") or {}
                prs = []
                for rel in w.get("relations") or []:
                    if rel.get("rel") == "System.LinkTypes.Hierarchy-Forward":
                        children.setdefault(w["id"], []).append(int(rel["url"].rsplit("/", 1)[-1]))
                    elif rel.get("rel") == "ArtifactLink" and "PullRequestId" in rel.get("url", ""):
                        pr_id = urllib.parse.unquote(rel["url"]).rsplit("/", 1)[-1]
                        if pr_id.isdigit():
                            prs.append(int(pr_id))
                state = f["System.State"]
                stage = "done" if state.lower() in ("done", "closed") else STAGE_BY_STATE.get(state.lower(), "in_progress")
                if stage != "done" and any(x in active_prs for x in prs):
                    stage = "in_pr"
                rows.append({
                    "id": w["id"], "type": "bug" if f["System.WorkItemType"] == "Bug" else "pbi",
                    "title": title[len(prefix):] if prefix and title.startswith(prefix) else title,
                    "state": state, "stage": stage, "scope": item_scopes[0], "scopes": item_scopes, "tags": tags,
                    "assignee": who.get("displayName", ""), "mine": bool(who) and who.get("id") == my_id,
                    "sprint": f.get("System.IterationPath", ""), "changed": f.get("System.ChangedDate", ""),
                    "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_workitems/edit/{w['id']}",
                    "prs": [x for x in prs if x in active_prs], "tasks_done": 0, "tasks_total": 0,
                })
        task_ids = sorted({c for cs in children.values() for c in cs})
        tasks: dict[int, dict] = {}
        for chunk in range(0, len(task_ids), 200):
            batch = task_ids[chunk:chunk + 200]
            fields = "System.Title,System.State,System.WorkItemType,System.AssignedTo"
            for w in ado_request("GET", f"{api}/wit/workitems?ids={','.join(map(str, batch))}&fields={fields}&api-version=7.1", pat).get("value", []):
                f = w["fields"]
                if f.get("System.WorkItemType") == "Task" and f.get("System.State") != "Removed":
                    tasks[w["id"]] = {"id": w["id"], "title": f.get("System.Title", ""), "state": f.get("System.State", ""),
                                      "assignee": (f.get("System.AssignedTo") or {}).get("displayName", "")}
        for r in rows:
            mine = sorted((tasks[c] for c in children.get(r["id"], []) if c in tasks), key=task_order)
            r["tasks"] = mine
            r["tasks_total"] = len(mine)
            r["tasks_done"] = sum(1 for x in mine if task_is_done(x["state"]))
        out["items"] += rows
        if not full:
            continue
        states = out.setdefault("states", {})
        for kind, name in (("pbi", "Product Backlog Item"), ("bug", "Bug")):
            if kind in states:
                continue
            try:
                got = ado_request("GET", f"{api}/wit/workitemtypes/{urllib.parse.quote(name)}/states?api-version=7.1", pat)
                states[kind] = workflow_order([{"name": x["name"], "category": x.get("category", "")} for x in got.get("value", [])])
            except Exception:
                pass
        by_root: dict[str, list[dict]] = {}
        for sc, t in owners:
            root_path = t.get("iteration_root")
            if not root_path:
                continue
            if root_path not in by_root:
                try:
                    # The team's sprints: those under the root, and older ones named like them elsewhere
                    # (an earlier release's Sprint 22), but not dated milestones such as a launch.
                    prefix = root_path.rstrip("\\") + "\\"
                    by_root[root_path] = [x for x in ado_sprints({**t, "iteration_root": ""}, pat)
                                          if x["path"].startswith(prefix) or re.fullmatch(r"(?i)sprint \d+", x["name"])]
                except Exception:
                    by_root[root_path] = []
            cur = next((x["path"] for x in by_root[root_path]
                        if x["when"] == "current" and x["path"].startswith(root_path.rstrip("\\") + "\\")), None)
            if cur:
                out["sprints"][sc["id"]] = cur
        listed = {x["path"] for x in out.setdefault("sprint_list", [])}
        for sprints in by_root.values():
            out["sprint_list"] += [x for x in sprints if x["path"] not in listed]
            listed |= {x["path"] for x in sprints}
        out["sprint_list"].sort(key=lambda x: x["start"])
    for sc in local_tracker_scopes(root):
        data = load_work_or_warn(root, sc["id"])
        if data is None:
            continue
        out["items"] += local_backlog(data, sc["id"], done_days, sprint, search)
        if not full:
            continue
        for kind in ("pbi", "bug"):
            out.setdefault("states", {}).setdefault(kind, SCRUM_STATES)
        if not data["use_sprints"]:
            continue
        cur = current_sprint(data["sprints"])
        if cur:
            out["sprints"][sc["id"]] = cur["name"]
        listed = {x["path"] for x in out.setdefault("sprint_list", [])}
        out["sprint_list"] += [{"name": x["name"], "path": x["name"], "start": x["start"], "finish": x["finish"],
                                "when": sprint_when(x, sprints=data["sprints"])} for x in data["sprints"] if x["name"] not in listed]
        out["sprint_list"].sort(key=lambda x: x["start"])
    return out


def ado_trackers(root: Path) -> dict[tuple[str, str], list[tuple[dict, dict]]]:
    """Azure DevOps trackers by (organization, project), each with the scopes that use it."""
    out: dict[tuple[str, str], list[tuple[dict, dict]]] = {}
    for sc in load_registry(root):
        t = load_settings(root, sc["id"]).get("tracker") or {}
        if t.get("kind") == "azure-devops" and t.get("organization") and t.get("project"):
            out.setdefault((t["organization"], t["project"]), []).append((sc, t))
    return out


VOTE_NAMES = {10: "approved", 5: "approved with suggestions", 0: "no vote", -5: "waiting for author", -10: "rejected"}
VOTES = {"approve": 10, "approve-with-suggestions": 5, "reset": 0, "wait-for-author": -5, "reject": -10}
MERGE_STRATEGIES = [("squash", "allowSquash"), ("noFastForward", "allowNoFastForward"), ("rebase", "allowRebase"),
                    ("rebaseMerge", "allowRebaseMerge")]
KEEP_BRANCH_PREFIXES = ("release/", "test/", "staging/", "hotfix/")
OPEN_THREAD = ("active", "pending")


def pr_threads(raw: list[dict]) -> list[dict]:
    """People's and bots' comment threads, without the system ones (votes, policy status, pushes)."""
    out = []
    for t in raw:
        comments = [c for c in t.get("comments") or [] if not c.get("isDeleted")]
        if t.get("isDeleted") or not comments or comments[0].get("commentType") == "system":
            continue
        if ((t.get("properties") or {}).get("CodeReviewThreadType") or {}).get("$value"):
            continue
        ctx = t.get("threadContext") or {}
        out.append({
            "id": t["id"], "status": t.get("status") or "unknown", "file": ctx.get("filePath") or "",
            "line": ((ctx.get("rightFileStart") or ctx.get("leftFileStart") or {}).get("line")) or 0,
            "published": t.get("publishedDate", ""),
            "comments": [{"id": c["id"], "author": (c.get("author") or {}).get("displayName", ""),
                          "content": c.get("content", ""), "date": c.get("publishedDate", "")} for c in comments],
        })
    return out


def pr_allowed_strategies(evaluations: list[dict]) -> list[str]:
    for e in evaluations:
        settings = (e.get("configuration") or {}).get("settings") or {}
        if any(k in settings for _, k in MERGE_STRATEGIES):
            allowed = [name for name, key in MERGE_STRATEGIES if settings.get(key)]
            if allowed:
                return allowed
    return [name for name, _ in MERGE_STRATEGIES]


def pr_policies(evaluations: list[dict]) -> list[dict]:
    out = []
    for e in evaluations:
        conf = e.get("configuration") or {}
        name = ((conf.get("type") or {}).get("displayName")) or "Policy"
        settings = conf.get("settings") or {}
        if any(k in settings for _, k in MERGE_STRATEGIES):
            continue  # chosen when completing, so it reads "rejected" until then
        out.append({"name": settings.get("displayName") or name, "kind": name, "status": e.get("status", ""),
                    "blocking": bool(conf.get("isBlocking")), "expired": bool((e.get("context") or {}).get("isExpired"))})
    return out


def pr_blockers(pr: dict, policies: list[dict], open_threads: int) -> list[str]:
    """Why the pull request can't be completed now, in words. Empty means it can."""
    out = []
    if pr.get("isDraft"):
        out.append("It is a draft")
    if pr.get("mergeStatus") not in (None, "succeeded"):
        out.append({"conflicts": "It has merge conflicts", "queued": "The merge is still being checked"}.get(
            pr.get("mergeStatus"), f"Merge status: {pr.get('mergeStatus')}"))
    for p in policies:
        if not p["blocking"] or p["status"] in ("approved", "notApplicable"):
            continue
        kind = p["kind"]
        if kind == "Comment requirements":
            out.append(f"{open_threads} open comment{'s' if open_threads != 1 else ''}" if open_threads else "Open comments")
        elif kind in ("Minimum number of reviewers", "Required reviewers"):
            out.append("Waiting for approval" if p["status"] != "rejected" else "A reviewer rejected it")
        elif kind == "Build" and p.get("expired"):
            out.append("The build expired")
        elif kind == "Build":
            out.append({"running": "The build is running", "queued": "The build is queued", "rejected": "The build failed"}.get(
                p["status"], f"Build: {p['status']}"))
        elif kind == "Work item linking":
            out.append("No linked work item")
        else:
            out.append(f"{p['name']}: {p['status']}")
    return list(dict.fromkeys(out))


def pr_scope(owners: list[tuple[dict, dict]], repo: str) -> str:
    for sc, _ in owners:
        if any(r.split("_git/")[-1] == repo for r in sc.get("remotes", [])):
            return sc["id"]
    return next((sc["id"] for sc, _ in owners if sc.get("paths")), owners[0][0]["id"])


def pr_build_checks(org: str, proj: str, api: str, pat: str, pr: dict, log_lines: int = 0) -> list[dict]:
    """The pull request's build policies: status, whether the result expired, the build, and for a failed build
    the failing steps with the end of their logs (`log_lines` lines each)."""
    artifact = urllib.parse.quote(f"vstfs:///CodeReview/CodeReviewId/{pr['repository']['project']['id']}/{pr['pullRequestId']}")
    evaluations = ado_request("GET", f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis/policy/evaluations"
                              f"?artifactId={artifact}&api-version=7.1-preview.1", pat).get("value", [])
    out = []
    for e in evaluations:
        conf = e.get("configuration") or {}
        if ((conf.get("type") or {}).get("displayName")) != "Build":
            continue
        ctx = e.get("context") or {}
        check = {"evaluation": e.get("evaluationId"), "name": (conf.get("settings") or {}).get("displayName") or "Build",
                 "status": e.get("status", ""), "expired": bool(ctx.get("isExpired")), "build": ctx.get("buildId"),
                 "blocking": bool(conf.get("isBlocking")), "failures": []}
        if check["build"]:
            check["url"] = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_build/results?buildId={check['build']}"
        if log_lines and check["build"] and e.get("status") == "rejected":
            try:
                timeline = ado_request("GET", f"{api}/build/builds/{check['build']}/timeline?api-version=7.1", pat)
                for r in timeline.get("records") or []:
                    # Failed steps, and the jobs and stages above them when they say why (a timeout, a lost agent).
                    if r.get("result") != "failed" or (r.get("type") != "Task" and not r.get("issues")):
                        continue
                    failure = {"step": r.get("name", ""), "issues": [i.get("message", "") for i in r.get("issues") or []][:10]}
                    log = (r.get("log") or {}).get("url")
                    if log:
                        req = urllib.request.Request(log)
                        import base64
                        req.add_header("Authorization", "Basic " + base64.b64encode(f":{pat}".encode()).decode())
                        with urllib.request.urlopen(req, timeout=30) as resp:
                            lines = resp.read().decode(errors="replace").splitlines()
                        failure["log"] = [re.sub(r"^\S+Z ", "", x) for x in lines[-log_lines:]]
                    check["failures"].append(failure)
            except urllib.error.HTTPError as exc:
                check["failures"].append({"step": "(could not read the build)", "issues": [ado_error_detail(exc, 200)]})
        out.append(check)
    return out


def pr_summary(org: str, proj: str, owners, api: str, pat: str, pr: dict, with_threads: bool = False) -> dict:
    repo_id, pid = pr["repository"]["id"], pr["pullRequestId"]
    base = f"{api}/git/repositories/{repo_id}/pullRequests/{pid}"
    threads = pr_threads(ado_request("GET", f"{base}/threads?api-version=7.1", pat).get("value", []))
    artifact = urllib.parse.quote(f"vstfs:///CodeReview/CodeReviewId/{pr['repository']['project']['id']}/{pid}")
    try:
        evaluations = ado_request("GET", f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis/policy/evaluations"
                                  f"?artifactId={artifact}&api-version=7.1-preview.1", pat).get("value", [])
    except urllib.error.HTTPError:
        evaluations = []
    linked = ado_request("GET", f"{base}/workitems?api-version=7.1", pat).get("value", [])
    policies = pr_policies(evaluations)
    open_threads = sum(1 for t in threads if t["status"] in OPEN_THREAD)
    repo = pr["repository"]["name"]
    source = pr.get("sourceRefName", "").removeprefix("refs/heads/")
    out = {
        "id": pid, "title": pr["title"], "repo": repo, "repo_id": repo_id, "scope": pr_scope(owners, repo),
        "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_git/{urllib.parse.quote(repo)}/pullrequest/{pid}",
        "draft": bool(pr.get("isDraft")), "author": (pr.get("createdBy") or {}).get("displayName", ""),
        "source": source, "target": pr.get("targetRefName", "").removeprefix("refs/heads/"),
        "created": pr.get("creationDate", ""), "merge_status": pr.get("mergeStatus", ""),
        "auto_complete": bool(pr.get("autoCompleteSetBy")),
        "reviewers": [{"name": r.get("displayName", ""), "vote": r.get("vote", 0), "required": bool(r.get("isRequired")),
                       "vote_name": VOTE_NAMES.get(r.get("vote", 0), str(r.get("vote")))}
                      for r in pr.get("reviewers") or [] if not r.get("isContainer")],
        "work_items": [int(w["id"]) for w in linked],
        "open_threads": open_threads, "threads_total": len(threads),
        "policies": policies, "blockers": pr_blockers(pr, policies, open_threads),
        "strategies": pr_allowed_strategies(evaluations),
        "keep_branch": source.startswith(KEEP_BRANCH_PREFIXES),
    }
    if with_threads:
        out["description"] = pr.get("description", "")
        out["threads"] = threads
    return out


def my_pull_requests(root: Path) -> dict:
    out = {"fetched": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "prs": [], "closed": []}
    trackers = ado_trackers(root)
    if not trackers:
        return out
    pat = ado_pat()
    for (org, proj), owners in trackers.items():
        api = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis"
        me = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
        prs = ado_request("GET", f"{api}/git/pullrequests?searchCriteria.status=active&searchCriteria.creatorId={me.get('id', '')}"
                          "&$top=100&api-version=7.1", pat).get("value", [])
        out["prs"] += [pr_summary(org, proj, owners, api, pat, pr) for pr in prs]
        now = dt.datetime.now(dt.timezone.utc)
        for status in ("completed", "abandoned"):
            try:
                done = ado_request("GET", f"{api}/git/pullrequests?searchCriteria.status={status}"
                                   f"&searchCriteria.creatorId={me.get('id', '')}&$top=30&api-version=7.1", pat).get("value", [])
            except urllib.error.HTTPError:
                continue
            for pr in done:
                brief = closed_pr_brief(pr, now)
                if not brief:
                    continue
                try:
                    linked = ado_request("GET", f"{api}/git/repositories/{pr['repository']['id']}/pullRequests/"
                                         f"{pr['pullRequestId']}/workitems?api-version=7.1", pat).get("value", [])
                    brief["work_items"] = [int(w["id"]) for w in linked]
                except urllib.error.HTTPError:
                    pass
                out["closed"].append(brief)
    out["prs"].sort(key=lambda p: p["created"], reverse=True)
    out["closed"].sort(key=lambda p: p["closed"], reverse=True)
    return out


def closed_pr_brief(pr: dict, now: dt.datetime, days: int = 7) -> dict | None:
    """A pull request completed or abandoned in the last `days` days, so the app knows a session's PR is over before
    the work item changes."""
    closed = pr.get("closedDate") or ""
    try:
        when = dt.datetime.fromisoformat(closed.replace("Z", "+00:00"))
    except ValueError:
        return None
    if pr.get("status") not in ("completed", "abandoned") or (now - when).days >= days:
        return None
    return {"id": pr["pullRequestId"], "title": pr.get("title", ""), "status": pr["status"], "closed": closed,
            "repo": (pr.get("repository") or {}).get("name", ""), "work_items": []}


def scope_repo_path(owners, repo: str) -> Path | None:
    """The local checkout of an Azure DevOps repo: the first path of the scope whose remotes name it."""
    for sc, _ in owners:
        if any(r.split("_git/")[-1] == repo for r in sc.get("remotes", [])) and sc.get("paths"):
            return Path(os.path.expanduser(sc["paths"][0]))
    return None


def git_run(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def git_worktrees(repo: Path) -> list[dict]:
    out, cur = [], {}
    for line in git_run(repo, "worktree", "list", "--porcelain").stdout.splitlines() + [""]:
        if not line:
            if cur:
                out.append(cur)
            cur = {}
        elif line.startswith("worktree "):
            cur["path"] = line[9:]
        elif line.startswith("branch "):
            cur["branch"] = line[7:].removeprefix("refs/heads/")
        elif line.startswith("HEAD "):
            cur["head"] = line[5:]
    return out


def pr_leftovers(repo: Path, branch: str, merged: str | None) -> dict:
    """What a completed pull request left on this machine: worktrees on its branch (and whether they hold
    uncommitted work) and the local branch (and whether deleting it would lose commits the PR didn't take)."""
    wts = git_worktrees(repo)
    main = Path(wts[0]["path"]).resolve() if wts else repo.resolve()
    trees = []
    main_on_branch = False
    for w in wts:
        if w.get("branch") != branch:
            continue
        if Path(w["path"]).resolve() == main:
            main_on_branch = True
            continue
        dirty = bool(git_run(Path(w["path"]), "status", "--porcelain").stdout.strip())
        trees.append({"path": w["path"], "dirty": dirty})
    tip = git_run(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}").stdout.strip() or None
    safe = tip is None or (merged is not None and (tip == merged or git_run(repo, "merge-base", "--is-ancestor", tip, merged).returncode == 0))
    main_dirty = main_on_branch and bool(git_run(main, "status", "--porcelain").stdout.strip())
    return {"repo_path": str(repo), "branch": branch, "worktrees": trees, "local_branch": tip is not None,
            "local_branch_safe": safe, "checked_out_in_main": main_on_branch, "main_dirty": main_dirty}


def has_leftovers(left: dict, remote: bool = False) -> bool:
    return bool(left["worktrees"]) or left["local_branch"] or remote


def cleanup_local(left: dict, worktrees: bool, branch: bool, force: bool, target: str | None = None) -> tuple[list[str], list[str]]:
    """Removes the worktrees and the local branch of a completed pull request. Returns (done, refused).
    With `force`, a branch checked out in the main checkout is deleted after switching that checkout to `target`;
    git carries uncommitted changes over or refuses, so nothing there is lost."""
    repo, name = Path(left["repo_path"]), left["branch"]
    done, refused = [], []
    if worktrees:
        for w in left["worktrees"]:
            if w["dirty"] and not force:
                refused.append(f"worktree {w['path']} has uncommitted changes")
                continue
            r = git_run(repo, "worktree", "remove", *(["--force"] if force else []), w["path"])
            (done if r.returncode == 0 else refused).append(
                f"removed worktree {w['path']}" if r.returncode == 0 else f"worktree {w['path']}: {r.stderr.strip()}")
        git_run(repo, "worktree", "prune")
    if branch and left["local_branch"]:
        if left["checked_out_in_main"] and force and target:
            r = git_run(repo, "switch", target)
            if r.returncode != 0:
                refused.append(f"couldn't switch {repo} to {target} to free {name}: {r.stderr.strip()}")
                return done, refused
            done.append(f"switched {repo} to {target}")
            left = {**left, "checked_out_in_main": False}
        if left["checked_out_in_main"]:
            refused.append(f"branch {name} is checked out in {repo}; switch that checkout to another branch first")
        elif not left["local_branch_safe"] and not force:
            refused.append(f"branch {name} has commits the pull request didn't take")
        elif any(w["path"] for w in left["worktrees"]) and not worktrees:
            refused.append(f"branch {name} is still used by a worktree")
        else:
            r = git_run(repo, "branch", "-D", name)
            (done if r.returncode == 0 else refused).append(
                f"deleted branch {name}" if r.returncode == 0 else f"branch {name}: {r.stderr.strip()}")
    return done, refused


def remote_branch(api: str, pat: str, repo_id: str, branch: str) -> str | None:
    """The commit the branch points at on the server, or None when it is gone."""
    refs = ado_request("GET", f"{api}/git/repositories/{repo_id}/refs?filter={urllib.parse.quote('heads/' + branch)}"
                       "&api-version=7.1", pat).get("value", [])
    return next((r["objectId"] for r in refs if r.get("name") == f"refs/heads/{branch}"), None)


def completed_pull_requests(root: Path, days: int) -> dict:
    """Your pull requests completed in the last `days` days that still left a worktree or branch behind."""
    pat = ado_pat()
    since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    out = {"fetched": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "prs": []}
    for (org, proj), owners in ado_trackers(root).items():
        api = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis"
        me = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
        prs = ado_request("GET", f"{api}/git/pullrequests?searchCriteria.status=completed&searchCriteria.creatorId={me.get('id', '')}"
                          "&$top=60&api-version=7.1", pat).get("value", [])
        for pr in prs:
            closed = pr.get("closedDate", "")
            if closed[:19] < since.strftime("%Y-%m-%dT%H:%M:%S"):
                continue
            repo = pr["repository"]["name"]
            path = scope_repo_path(owners, repo)
            branch = pr.get("sourceRefName", "").removeprefix("refs/heads/")
            if not path or not branch or not (path / ".git").exists():
                continue
            merged = (pr.get("lastMergeSourceCommit") or {}).get("commitId")
            left = pr_leftovers(path, branch, merged)
            try:
                remote = remote_branch(api, pat, pr["repository"]["id"], branch) is not None
            except urllib.error.HTTPError:
                remote = False
            if not has_leftovers(left, remote):
                continue
            out["prs"].append({
                "id": pr["pullRequestId"], "title": pr["title"], "repo": repo, "repo_id": pr["repository"]["id"],
                "scope": pr_scope(owners, repo), "closed": closed[:19],
                "target": pr.get("targetRefName", "").removeprefix("refs/heads/"),
                "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_git/{urllib.parse.quote(repo)}/pullrequest/{pr['pullRequestId']}",
                "remote_branch": remote, **left})
    out["prs"].sort(key=lambda p: p["closed"], reverse=True)
    return out


def find_pr(root: Path, pr_id: int, pat: str):
    """(org, project, owners, api, the PR) for a pull request id in any of the trackers."""
    for (org, proj), owners in ado_trackers(root).items():
        api = f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis"
        try:
            return org, proj, owners, api, ado_request("GET", f"{api}/git/pullrequests/{pr_id}?api-version=7.1", pat)
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    sys.exit(f"kb: no pull request {pr_id} in the Azure DevOps trackers")


def cmd_pr(a) -> int:
    root = kb_root()
    try:
        if a.action == "done":
            data = completed_pull_requests(root, a.days)
            if a.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
                return 0
            for p in data["prs"]:
                bits = [f"{len(p['worktrees'])} worktree(s)"] if p["worktrees"] else []
                if p["local_branch"]:
                    bits.append("local branch")
                if p["remote_branch"]:
                    bits.append("remote branch")
                print(f"!{p['id']}\t{p['repo']}\t{p['branch']}\t{', '.join(bits)}")
            return 0
        if a.action == "list":
            data = my_pull_requests(root)
            if a.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
                return 0
            for p in data["prs"]:
                state = "ready" if not p["blockers"] else "; ".join(p["blockers"])
                print(f"!{p['id']}\t{p['repo']}\t{p['title']}\t{p['open_threads']} open comments\t{state}")
            return 0
        pat = ado_pat()
        org, proj, owners, api, pr = find_pr(root, a.id, pat)
        base = f"{api}/git/repositories/{pr['repository']['id']}/pullRequests/{a.id}"
        if a.action == "cleanup":
            if pr.get("status") != "completed":
                sys.exit(f"kb: !{a.id} is {pr.get('status')}, not completed; clean up after it is merged")
            path = scope_repo_path(owners, pr["repository"]["name"])
            branch = pr.get("sourceRefName", "").removeprefix("refs/heads/")
            if not path:
                sys.exit(f"kb: no scope has a local checkout of {pr['repository']['name']}")
            left = pr_leftovers(path, branch, (pr.get("lastMergeSourceCommit") or {}).get("commitId"))
            done, refused = cleanup_local(left, a.worktree, a.branch, a.force,
                                          pr.get("targetRefName", "").removeprefix("refs/heads/") or None)
            if a.remote:
                head = remote_branch(api, pat, pr["repository"]["id"], branch)
                if head:
                    ado_request("POST", f"{api}/git/repositories/{pr['repository']['id']}/refs?api-version=7.1", pat,
                                [{"name": f"refs/heads/{branch}", "oldObjectId": head, "newObjectId": "0" * 40}])
                    done.append(f"deleted remote branch {branch}")
            for line in done:
                print(line)
            for line in refused:
                print(f"kb: {line}", file=sys.stderr)
            return 1 if refused else 0
        if a.action == "checks":
            checks = pr_build_checks(org, proj, api, pat, pr, log_lines=a.log_lines)
            requeued = []
            if a.requeue or a.requeue_expired:
                for c in checks:
                    stuck = c["status"] == "rejected" or (c["status"] == "queued" and not c["build"])
                    if c["evaluation"] and (c["expired"] or (stuck and not a.requeue_expired)):
                        ado_request("PATCH", f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis/policy/evaluations/"
                                             f"{c['evaluation']}?api-version=7.1-preview.1", pat)
                        requeued.append(c["name"])
            if a.json:
                print(json.dumps({"checks": checks, "requeued": requeued}, indent=2, ensure_ascii=False))
                return 0
            if not checks:
                print(f"!{a.id} has no build policies")
            for c in checks:
                state = c["status"] + (" (expired)" if c["expired"] else "")
                print(f"{c['name']}: {state}" + (f"  build {c['build']} {c.get('url', '')}" if c["build"] else ""))
                for f in c["failures"]:
                    print(f"  failed step: {f['step']}")
                    for i in f["issues"]:
                        print(f"    ! {i}")
                    for line in f.get("log", []):
                        print(f"    | {line}")
            for name in requeued:
                print(f"requeued {name}")
            return 0
        if a.action == "show":
            data = pr_summary(org, proj, owners, api, pat, pr, with_threads=True)
            if a.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
                return 0
            print(f"!{data['id']} {data['title']}\n{data['source']} -> {data['target']}  ({data['repo']})\n{data['url']}")
            print("Reviewers: " + (", ".join(f"{r['name']} ({r['vote_name']})" for r in data["reviewers"]) or "none"))
            print("Can complete: " + ("yes" if not data["blockers"] else "no, " + "; ".join(data["blockers"])))
            for t in data["threads"]:
                if a.all or t["status"] in OPEN_THREAD:
                    where = f"{t['file']}:{t['line']}" if t["file"] else "general"
                    print(f"\n--- thread {t['id']} [{t['status']}] {where}")
                    for c in t["comments"]:
                        print(f"{c['author']}: {c['content']}")
            return 0
        if a.action == "vote":
            me = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
            if not me.get("id"):
                sys.exit("kb: Azure DevOps didn't say who you are")
            value = VOTES[a.vote]
            ado_request("PUT", f"{base}/reviewers/{me['id']}?api-version=7.1", pat, {"vote": value})
            print(f"!{a.id}: voted {VOTE_NAMES[value]}")
            return 0
        if a.action == "reply":
            text = a.text if a.text is not None else sys.stdin.read()
            if not text.strip():
                sys.exit("kb: nothing to post; pass --text or the reply on stdin")
            ado_request("POST", f"{base}/threads/{a.thread}/comments?api-version=7.1", pat,
                        {"content": text.strip(), "parentCommentId": 1, "commentType": 1})
            if a.status:
                ado_request("PATCH", f"{base}/threads/{a.thread}?api-version=7.1", pat, {"status": a.status})
            print(f"replied on thread {a.thread}" + (f", now {a.status}" if a.status else ""))
            return 0
        if a.action == "comment":
            text = a.text if a.text is not None else sys.stdin.read()
            if not text.strip():
                sys.exit("kb: nothing to post; pass --text or the comment on stdin")
            made = ado_request("POST", f"{base}/threads?api-version=7.1", pat,
                               {"comments": [{"parentCommentId": 0, "content": text.strip(), "commentType": 1}], "status": "active"})
            print(f"commented on !{a.id}" + (f" (thread {made['id']})" if isinstance(made, dict) and made.get("id") else ""))
            return 0
        if a.action == "thread":
            ado_request("PATCH", f"{base}/threads/{a.thread}?api-version=7.1", pat, {"status": a.status})
            print(f"thread {a.thread} is now {a.status}")
            return 0
        if a.action == "complete":
            summary = pr_summary(org, proj, owners, api, pat, pr)
            strategy = a.strategy or summary["strategies"][0]
            if strategy not in summary["strategies"]:
                sys.exit(f"kb: the branch policy allows only {', '.join(summary['strategies'])}")
            delete = (not summary["keep_branch"]) if a.delete_branch is None else a.delete_branch
            options = {"mergeStrategy": strategy, "deleteSourceBranch": delete,
                       "transitionWorkItems": bool(a.complete_work_items),
                       "mergeCommitMessage": a.message or f"Merged PR {a.id}: {pr['title']}"}
            if a.cancel_auto:
                ado_request("PATCH", f"{base}?api-version=7.1", pat,
                            {"autoCompleteSetBy": {"id": "00000000-0000-0000-0000-000000000000"}})
                print(f"auto-complete cancelled on !{a.id}")
                return 0
            if a.auto:
                me = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
                ado_request("PATCH", f"{base}?api-version=7.1", pat,
                            {"autoCompleteSetBy": {"id": me.get("id")}, "completionOptions": options})
                print(f"!{a.id} completes by itself when its policies pass ({strategy}"
                      f"{', deletes ' + summary['source'] if delete else ''})")
                return 0
            if summary["blockers"]:
                sys.exit("kb: can't complete yet: " + "; ".join(summary["blockers"]) + ". Use --auto to complete it when they pass.")
            got = ado_request("PATCH", f"{base}?api-version=7.1", pat,
                              {"status": "completed", "lastMergeSourceCommit": pr["lastMergeSourceCommit"],
                               "completionOptions": options})
            print(f"!{a.id} {got.get('status', 'completing')} ({strategy}{', deleted ' + summary['source'] if delete else ''})")
            return 0
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            body = json.loads(body).get("message", body)
        except ValueError:
            pass
        sys.exit(f"kb: Azure DevOps said {exc.code}: {body[:400]}")
    except urllib.error.URLError as exc:
        sys.exit(f"kb: could not reach Azure DevOps: {exc.reason}")
    return 0


def set_task_states(root: Path, ids: list[int], state: str) -> list[str]:
    return set_work_item_fields(root, ids, {"System.State": state}, f"is now {state}")


def ado_me(org: str, pat: str) -> str:
    """Who the PAT belongs to, as Azure DevOps resolves it best: the account's email, else the display name."""
    user = ado_request("GET", f"https://dev.azure.com/{org}/_apis/connectionData", pat).get("authenticatedUser") or {}
    account = ((user.get("properties") or {}).get("Account") or {}).get("$value") or ""
    return account if "@" in account else user.get("providerDisplayName", "")


def align_item_tags(root: Path, wid: int) -> str:
    """Adds the item's aligned KB tags to its Azure DevOps tags, keeping every tag it has."""
    store = load_item_tags(root)
    pat = ado_pat()
    for (org, proj), _ in ado_trackers(root).items():
        try:
            w = ado_request("GET", f"https://dev.azure.com/{org}/_apis/wit/workitems/{wid}?fields=System.Tags&api-version=7.1", pat)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            sys.exit(f"kb: #{wid}: {ado_error_detail(e)}")
        tool = [t.strip() for t in (w["fields"].get("System.Tags") or "").split(";") if t.strip()]
        add = item_tag_additions(store, f"azure-devops:{wid}", tool)
        if not add:
            return f"#{wid}: nothing to align"
        set_work_item_fields(root, [wid], {"System.Tags": "; ".join(tool + add)}, "tagged")
        return f"#{wid}: added {', '.join(add)}"
    sys.exit(f"kb: no Azure DevOps tracker has #{wid}")


def set_work_item_fields(root: Path, ids: list[int], fields: dict, what: str) -> list[str]:
    pat = ado_pat()
    done = []
    for (org, proj), _ in ado_trackers(root).items():
        for i in ids:
            try:
                ado_request("PATCH", f"https://dev.azure.com/{org}/{urllib.parse.quote(proj)}/_apis/wit/workitems/{i}?api-version=7.1",
                            pat, [{"op": "add", "path": f"/fields/{k}", "value": v} for k, v in fields.items()],
                            content_type="application/json-patch+json")
                done.append(f"#{i} {what}")
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    body = e.read().decode(errors="replace")
                    try:
                        body = json.loads(body).get("message", body)
                    except ValueError:
                        pass
                    sys.exit(f"kb: #{i}: Azure DevOps said {e.code}: {body[:300]}")
        break
    return done


def in_progress_state(current: str, states: list[dict]) -> str | None:
    """The state that starts work on an item still in a Proposed state (New, Approved, To Do): the first
    InProgress state in workflow order, which is Committed in Scrum, Active in Agile and Doing in Basic.
    None when the item is already under way or done, so starting never moves anything back."""
    category = next((s["category"] for s in states if s["name"].lower() == current.lower()), None)
    if category is None:
        category = "Proposed" if STAGE_BY_STATE.get(current.lower()) == "not_started" else "InProgress"
    if category != "Proposed":
        return None
    return next((s["name"] for s in workflow_order(states) if s["category"] == "InProgress"), None)


def start_work_item(root: Path, sid: str, iid: int) -> str:
    """Moves a PBI or bug into its tracker's in-progress state when nobody has started it yet."""
    tracker = load_settings(root, sid).get("tracker") or {}
    kind = tracker.get("kind")
    if kind == "local":
        data = load_work(root, sid)
        item = find_work_item(data, iid)
        target = in_progress_state(item["state"], SCRUM_STATES if item["type"] != "task" else
                                   [{"name": "To Do", "category": "Proposed"}, {"name": "In Progress", "category": "InProgress"}])
        if not target:
            return f"#{iid} is already {item['state']}"
        update_work_item(data, iid, {"state": target})
        save_work(root, sid, data)
        return f"#{iid} is now {target}"
    if kind != "azure-devops":
        sys.exit(f"kb: {sid} tracks work in {kind or 'no tracker'}; move it to in progress with Claude's connector for it")
    if missing := ado_tracker_missing(tracker):
        sys.exit(f"kb: {sid}'s azure-devops tracker has no {' or '.join(missing)}")
    api = f"https://dev.azure.com/{tracker['organization']}/{urllib.parse.quote(tracker['project'])}/_apis"
    pat = ado_pat()
    try:
        f = ado_request("GET", f"{api}/wit/workitems/{iid}?fields=System.State,System.WorkItemType&api-version=7.1", pat)["fields"]
        got = ado_request("GET", f"{api}/wit/workitemtypes/{urllib.parse.quote(f['System.WorkItemType'])}/states?api-version=7.1", pat)
        target = in_progress_state(f["System.State"], [{"name": x["name"], "category": x.get("category", "")}
                                                       for x in got.get("value", [])])
        if not target:
            return f"#{iid} is already {f['System.State']}"
        ado_request("PATCH", f"{api}/wit/workitems/{iid}?api-version=7.1", pat,
                    [{"op": "add", "path": "/fields/System.State", "value": target}],
                    content_type="application/json-patch+json")
    except urllib.error.HTTPError as e:
        sys.exit(f"kb: #{iid}: Azure DevOps said {e.code}: {ado_error_detail(e, 300)}")
    return f"#{iid} is now {target}"


def resolved_state(current: str, states: list[dict]) -> str | None:
    """The state that marks a PBI or bug as finished: the type's Resolved state when it has one (an Agile bug's
    Resolved, for testing to close), else its first Completed state (Done in Scrum, Closed in Agile). None when the
    item is already there or past it."""
    order = workflow_order(states)
    category = next((s["category"] for s in states if s["name"].lower() == current.lower()), None)
    if category in ("Resolved", "Completed", "Removed"):
        return None
    return next((s["name"] for s in order if s["category"] == "Resolved"), None) or \
        next((s["name"] for s in order if s["category"] == "Completed"), None)


def resolve_work_item(root: Path, sid: str, iid: int) -> str:
    """Moves a PBI or bug to its resolved (or done) state, for work that turned out finished."""
    tracker = load_settings(root, sid).get("tracker") or {}
    kind = tracker.get("kind")
    if kind == "local":
        data = load_work(root, sid)
        item = find_work_item(data, iid)
        target = resolved_state(item["state"], SCRUM_STATES)
        if not target:
            return f"#{iid} is already {item['state']}"
        update_work_item(data, iid, {"state": target})
        save_work(root, sid, data)
        return f"#{iid} is now {target}"
    if kind != "azure-devops":
        sys.exit(f"kb: {sid} tracks work in {kind or 'no tracker'}; resolve it with Claude's connector for it")
    if missing := ado_tracker_missing(tracker):
        sys.exit(f"kb: {sid}'s azure-devops tracker has no {' or '.join(missing)}")
    api = f"https://dev.azure.com/{tracker['organization']}/{urllib.parse.quote(tracker['project'])}/_apis"
    pat = ado_pat()
    try:
        f = ado_request("GET", f"{api}/wit/workitems/{iid}?fields=System.State,System.WorkItemType&api-version=7.1", pat)["fields"]
        got = ado_request("GET", f"{api}/wit/workitemtypes/{urllib.parse.quote(f['System.WorkItemType'])}/states?api-version=7.1", pat)
        target = resolved_state(f["System.State"], [{"name": x["name"], "category": x.get("category", "")}
                                                    for x in got.get("value", [])])
        if not target:
            return f"#{iid} is already {f['System.State']}"
        ado_request("PATCH", f"{api}/wit/workitems/{iid}?api-version=7.1", pat,
                    [{"op": "add", "path": "/fields/System.State", "value": target}],
                    content_type="application/json-patch+json")
    except urllib.error.HTTPError as e:
        sys.exit(f"kb: #{iid}: Azure DevOps said {e.code}: {ado_error_detail(e, 300)}")
    return f"#{iid} is now {target}"


def discussion_section_append(body: str, heading: str, line: str) -> str:
    """Adds `line` at the end of the `## heading` section, creating the section before Outcome when missing."""
    lines = body.rstrip("\n").split("\n") if body.strip() else []
    head = f"## {heading}"
    if head not in lines:
        at = lines.index("## Outcome") if "## Outcome" in lines else len(lines)
        block = [head, line, ""]
        lines = lines[:at] + ([""] if at and lines[at - 1].strip() else []) + block + lines[at:]
        return "\n".join(lines).rstrip("\n") + "\n"
    start = lines.index(head) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    last = end
    while last > start and not lines[last - 1].strip():
        last -= 1
    lines.insert(last, line)
    return "\n".join(lines).rstrip("\n") + "\n"


def discussion_set_section(body: str, heading: str, text: str) -> str:
    """Replaces the `## heading` section's text."""
    lines = body.rstrip("\n").split("\n")
    head = f"## {heading}"
    if head not in lines:
        return body.rstrip("\n") + f"\n\n{head}\n{text.strip()}\n"
    start = lines.index(head) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    tail = [""] + lines[end:] if end < len(lines) else []
    return "\n".join(lines[:start] + text.strip().split("\n") + tail).rstrip("\n") + "\n"


def cmd_discussion(a) -> int:
    root = kb_root()
    if a.action == "list":
        entries = all_entries(root) if a.all_projects else scope_entries(root, a.project or current_project_id(root))
        rows = [e for e in entries if e.section == "discussions" and (a.all or e.status == "open")]
        rows.sort(key=lambda e: str(e.get("updated") or e.date), reverse=True)
        if a.json:
            print(json.dumps([{"id": e.id, "title": e.title, "status": e.status, "waiting_on": e.get("waiting_on") or "",
                               "thread": e.get("thread") or "", "channel": e.get("channel") or "",
                               "updated": str(e.get("updated") or e.date), "people": e.get("people") or []}
                              for e in rows], indent=2, ensure_ascii=False))
        else:
            for e in rows:
                print(f"{e.id}\t{e.get('updated') or e.date}\t{e.title}\t{e.status}\t{e.get('waiting_on') or ''}\t{e.get('thread') or ''}")
        return 0
    e = find_entry(root, a.id)
    if not e or e.section != "discussions":
        sys.exit(f"kb: no discussion {a.id}")
    today = dt.date.today().isoformat()
    if a.action == "note":
        text = (a.text if a.text is not None else sys.stdin.read()).strip()
        if not text:
            sys.exit("kb: nothing to note; pass --text or the point on stdin")
        heading = {"point": "Points raised", "question": "Open questions", "finding": "Findings"}[a.kind]
        prefix = {"point": f"- {a.date or today} · {a.who}: " if a.who else f"- {a.date or today}: ",
                  "question": "- [ ] ", "finding": "- "}[a.kind]
        e.body = discussion_section_append(e.body, heading, prefix + " ".join(text.split("\n")))
    elif a.action == "status":
        e.set("status", a.status)
        if a.outcome:
            e.body = discussion_set_section(e.body, "Outcome", a.outcome)
    if getattr(a, "waiting_on", None):
        e.set("waiting_on", a.waiting_on)
    e.set("updated", today)
    e.save()
    print(e.id)
    return 0


def cmd_idea(a) -> int:
    root = kb_root()
    if a.action == "list":
        entries = all_entries(root) if a.all_projects else scope_entries(root, a.project or current_project_id(root))
        rows = [e for e in entries if e.section == "ideas" and (a.all or e.status in ("new", "exploring"))]
        rows.sort(key=lambda e: str(e.get("updated") or e.date), reverse=True)
        for e in rows:
            print(f"{e.id}\t{e.get('updated') or e.date}\t{e.title}\t{e.status or 'new'}\t{e.summary}")
        return 0
    e = find_entry(root, a.id)
    if not e or e.section != "ideas":
        sys.exit(f"kb: no idea {a.id}")
    if a.action == "note":
        text = (a.text if a.text is not None else sys.stdin.read()).strip()
        if not text:
            sys.exit("kb: nothing to note; pass --text or the note on stdin")
        heading, prefix = IDEA_NOTE[a.kind]
        e.body = discussion_section_append(e.body, heading, prefix + " ".join(text.split("\n")))
        if a.kind == "thought" and (e.status or "new") == "new":
            e.set("status", "exploring")
    elif a.action == "status":
        e.set("status", a.status)
    e.set("updated", dt.date.today().isoformat())
    e.save()
    print(e.id)
    return 0


def note_title(text: str) -> str:
    first = next((x.strip(" #-*") for x in text.strip().split("\n") if x.strip()), "Note")
    words = first.split()
    return " ".join(words[:8]) + ("…" if len(words) > 8 else "")


def cmd_note(a) -> int:
    root = kb_root()
    if a.action == "list":
        entries = all_entries(root) if a.all_projects else scope_entries(root, a.project or current_project_id(root))
        rows = [e for e in entries if e.section == "notes" and (a.all or (e.status or "open") == "open")]
        rows.sort(key=lambda e: str(e.get("updated") or e.date), reverse=True)
        for e in rows:
            print(f"{e.id}\t{e.get('updated') or e.date}\t{e.title}\t{e.status or 'open'}\t{e.summary}")
        return 0
    today = dt.date.today().isoformat()
    if a.action == "add":
        text = (a.text if a.text is not None else sys.stdin.read()).strip()
        if not text:
            sys.exit("kb: nothing to note; pass --text or the note on stdin")
        if a.to:
            e = find_entry(root, a.to)
            if not e or e.section != "notes":
                sys.exit(f"kb: no note {a.to}")
            e.body = discussion_section_append(e.body, "Notes", text)
        else:
            pid = target_project(root, a.project, True)
            title = one_line(a.title) if a.title else note_title(text)
            path = entry_path(root, pid, "notes", title, today, None)
            write_atomic(path, render_entry([("title", title), ("date", today), ("status", "open")],
                                            NOTE_TEMPLATE.format(body=text)))
            print(f"{pid}/notes/{path.stem}")
            return 0
    else:
        e = find_entry(root, a.id)
        if not e or e.section != "notes":
            sys.exit(f"kb: no note {a.id}")
        if a.action == "status":
            e.set("status", a.status)
        elif a.action == "summary":
            text = (a.text if a.text is not None else sys.stdin.read()).strip()
            e.body = section_set(e.body, "Summary", text)
            first = text.split("\n")[0].strip(" -*")
            if first:
                e.set("summary", one_line(first)[:200])
        elif a.action == "filed":
            e.body = discussion_section_append(e.body, "Filed", "- " + " ".join(a.text.split()))
    e.set("updated", today)
    e.save()
    print(e.id)
    return 0


def section_set(body: str, heading: str, text: str) -> str:
    """Replaces what is under `## heading` (made at the end when missing)."""
    lines = body.rstrip("\n").split("\n") if body.strip() else []
    head = f"## {heading}"
    block = [head, ""] + ([*text.strip().split("\n"), ""] if text.strip() else [])
    if head not in lines:
        return "\n".join(lines + ([""] if lines and lines[-1].strip() else []) + block).rstrip("\n") + "\n"
    start = lines.index(head)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[:start] + block + lines[end:]).rstrip("\n") + "\n"


def cmd_research(a) -> int:
    root = kb_root()
    if a.action == "list":
        entries = all_entries(root) if a.all_projects else scope_entries(root, a.project or current_project_id(root))
        rows = [e for e in entries if e.section == "research" and (a.all or e.status in ("open", "review"))]
        if a.for_:
            want = a.for_ if not a.for_.lstrip("#").isdigit() else f"wi:{a.for_.lstrip('#')}"
            rows = [e for e in rows if str(e.get("for") or "") == want]
        rows.sort(key=lambda e: str(e.get("updated") or e.date), reverse=True)
        for e in rows:
            target = f"\tfor {e.get('for')}" if e.get("for") else ""
            print(f"{e.id}\t{e.get('updated') or e.date}\t{e.title}\t{e.status or 'open'}{target}")
        return 0
    e = find_entry(root, a.id)
    if not e or e.section != "research":
        sys.exit(f"kb: no research {a.id}")
    if a.action == "note":
        text = (a.text if a.text is not None else sys.stdin.read()).strip()
        if not text:
            sys.exit("kb: nothing to note; pass --text or the note on stdin")
        heading, prefix = RESEARCH_NOTE[a.kind]
        e.body = discussion_section_append(e.body, heading, prefix + " ".join(text.split("\n")))
    elif a.action == "summary":
        summary = (a.text if a.text is not None else sys.stdin.read()).strip()
        if not summary:
            sys.exit("kb: no summary; pass --text or the summary on stdin")
        e.body = section_set(e.body, "Summary", summary)
        if a.takeaway:
            e.body = section_set(e.body, "Takeaways", "\n".join("- " + " ".join(t.split()) for t in a.takeaway if t.strip()))
        e.set("status", "review")
    elif a.action == "status":
        e.set("status", a.status)
        if a.transferred:
            e.set("transferred_to", a.transferred)
    e.set("updated", dt.date.today().isoformat())
    e.save()
    print(e.id)
    return 0


def ado_tracker_for(root: Path, sid: str | None) -> tuple[str, str]:
    """The organization and project of a scope's Azure DevOps tracker, else of the first one set up."""
    t = load_settings(root, sid).get("tracker") or {} if sid else {}
    if t.get("kind") == "azure-devops" and t.get("organization") and t.get("project"):
        return t["organization"], t["project"]
    found = list(ado_trackers(root).keys())
    if not found:
        sys.exit("kb: no azure-devops tracker is set up")
    return found[0]


def tracker_note(root: Path, sid: str | None, iid: int, text: str, heading: str, comment: bool) -> str:
    """Adds Markdown to a PBI or bug: under a heading at the end of its description, or as a comment. KB ids and
    paths on this machine are taken out first; they mean nothing to the team."""
    removed: list[str] = []
    text = strip_private_refs(root, text.strip(), removed)
    heading = strip_private_refs(root, one_line(heading), removed)
    if left := private_refs_left(root, text, heading):
        sys.exit("kb: the note still names KB entries or local paths: " + ", ".join(left))
    if not text:
        sys.exit("kb: nothing to add")
    kind = (load_settings(root, sid).get("tracker") or {}).get("kind") if sid else None
    if kind == "jira":
        sys.exit(f"kb: {sid} tracks work in Jira; use Claude's Jira connector")
    if kind == "local":
        if comment:
            sys.exit("kb: the built-in tracker has no comments; leave out --comment to add it to the description")
        data = load_work(root, sid)
        try:
            item = find_work_item(data, iid)
        except WorkError as e:
            sys.exit(f"kb: {e}")
        desc = (item.get("description") or "").rstrip()
        item["description"] = (desc + "\n\n" if desc else "") + (f"### {heading}\n\n" if heading else "") + text + "\n"
        item["changed"] = dt.datetime.now().isoformat(timespec="seconds")
        save_work(root, sid, data)
        return f"#{iid} description updated"
    org, project = ado_tracker_for(root, sid)
    pat = ado_pat()
    base = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis/wit/workitems/{iid}"
    html = (f"<h3>{html_lib.escape(heading)}</h3>" if heading else "") + md_to_html(text)
    try:
        if comment:
            ado_request("POST", f"{base}/comments?api-version=7.1-preview.4", pat, {"text": html})
            return f"#{iid} comment added"
        w = ado_request("GET", f"{base}?fields=System.Description&api-version=7.1", pat)
        old = (w.get("fields") or {}).get("System.Description") or ""
        ado_request("PATCH", f"{base}?api-version=7.1", pat,
                    [{"op": "add", "path": "/fields/System.Description", "value": old + html}],
                    content_type="application/json-patch+json")
        return f"#{iid} description updated"
    except urllib.error.HTTPError as e:
        sys.exit(f"kb: #{iid}: Azure DevOps said {e.code}: {ado_error_detail(e, 300)}")


def tracker_find(root: Path, sid: str, query: str, limit: int = 10) -> dict:
    """Work items of the scope's tracker whose id is the query or whose title has every word of it, for picking a
    parent or related item: open ones first, then the most recently changed. Tasks and removed items are left out."""
    q = query.strip().lstrip("#!").strip()
    tracker = load_settings(root, sid).get("tracker") or {}
    kind = tracker.get("kind") or ""
    words = [w for w in q.split() if w.strip("#!")]
    if not q:
        return {"kind": kind, "items": []}
    if kind == "local":
        data = load_work_or_warn(root, sid) or {"items": []}
        rows = [i for i in data["items"] if i.get("type") != "task" and i.get("state") != "Removed"
                and (str(i["id"]) == q or all(w.lower() in i["title"].lower() for w in words))]
        rows.sort(key=lambda i: (str(i["id"]) != q, i.get("state") in ("Done", "Closed"), -int(i["id"])))
        return {"kind": kind, "items": [{"id": i["id"], "type": i["type"], "title": i["title"], "state": i["state"],
                                         "url": ""} for i in rows[:limit]]}
    if kind != "azure-devops" or ado_tracker_missing(tracker):
        return {"kind": kind, "items": [], "note": "this tracker can't be searched from Mindmill"}
    org, project = tracker["organization"], tracker["project"]
    base = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis"
    pat = ado_pat()
    title = " AND ".join(f"[System.Title] CONTAINS '{wiql_text(w)}'" for w in words)
    match = f"([System.Id] = {int(q)} OR ({title}))" if q.isdigit() else f"({title})"
    wiql = {"query": "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project "
                     "AND [System.WorkItemType] NOT IN ('Task', 'Test Case', 'Test Plan', 'Test Suite') "
                     f"AND [System.State] <> 'Removed' AND {match} ORDER BY [System.ChangedDate] DESC"}
    ids = [w["id"] for w in ado_request("POST", f"{base}/wit/wiql?api-version=7.1&$top=60", pat,
                                        wiql).get("workItems", [])][:60]
    items = []
    if ids:
        got = ado_request("GET", f"https://dev.azure.com/{org}/_apis/wit/workitems?ids={','.join(map(str, ids))}"
                                 "&fields=System.Title,System.State,System.WorkItemType&api-version=7.1", pat)
        for w in got.get("value", []):
            f = w.get("fields") or {}
            items.append({"id": w["id"], "type": f.get("System.WorkItemType", ""), "title": f.get("System.Title", ""),
                          "state": f.get("System.State", ""),
                          "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_workitems/edit/{w['id']}"})
    order = {i: n for n, i in enumerate(ids)}
    items.sort(key=lambda i: (str(i["id"]) != q, i["state"] in ("Done", "Closed"), order.get(i["id"], 0)))
    return {"kind": kind, "items": items[:limit]}


LOCAL_TRACKER_ACTIONS = ("item", "state", "task-state", "assign", "move")


def tracker_local_scope(root: Path, a) -> str | None:
    """The scope a `kb tracker` command acts on when that scope keeps its work in Mindmill's own tracker."""
    if a.action not in LOCAL_TRACKER_ACTIONS:
        return None
    sid = getattr(a, "project", None) or (resolve_project(load_registry(root), Path(os.getcwd())) or {}).get("id")
    if not sid or (load_settings(root, sid).get("tracker") or {}).get("kind") != "local":
        return None
    return sid


def local_assignee(who: str) -> str:
    """Who an item in Mindmill's own tracker goes to: `me` is the name set in Mindmill's settings (`KB_ME`)."""
    who = who.strip()
    if who.lower() in ("none", "nobody", ""):
        return ""
    if who.lower() == "me":
        me = os.environ.get("KB_ME", "").strip()
        if not me:
            raise WorkError("Mindmill's own tracker needs your name to assign to you: set it in Mindmill's settings "
                            "(Your name), or pass --to <name>")
        return me
    return who


def tracker_local(root: Path, sid: str, a) -> int:
    """`kb tracker item/state/task-state/assign/move` for a scope that uses Mindmill's own tracker."""
    if a.action == "item":
        return work_action(root, sid, argparse.Namespace(action="show", id=a.id, json=a.json))
    data = load_work(root, sid)
    lines = []
    for iid in a.ids:
        if a.action in ("state", "task-state"):
            item = update_work_item(data, iid, {"state": a.state})
            lines.append(f"#{item['id']} set to {item['state']}")
        elif a.action == "assign":
            item = update_work_item(data, iid, {"assignee": local_assignee(a.to)})
            lines.append(f"#{item['id']} assigned to {item.get('assignee') or 'nobody'}")
        else:
            which = "none" if a.backlog else a.sprint
            if which.lower() == "next":
                today = dt.date.today().isoformat()
                which = next((s["name"] for s in sorted(data["sprints"], key=lambda s: s["start"]) if s["start"] > today), "")
                if not which:
                    raise WorkError("there is no sprint after the current one; see `kb work sprint list`")
            item = update_work_item(data, iid, {"sprint": which})
            lines.append(f"#{item['id']} moved to {item.get('sprint') or 'the backlog'}")
    save_work(root, sid, data)
    print("\n".join(lines))
    return 0


def cmd_tracker(a) -> int:
    root = kb_root()
    if sid := tracker_local_scope(root, a):
        try:
            return tracker_local(root, sid, a)
        except WorkError as e:
            sys.exit(f"kb: {e}")
    if a.action == "find":
        sid = a.project or current_project_id(root)
        try:
            out = tracker_find(root, sid, a.query, a.limit)
        except urllib.error.HTTPError as e:
            sys.exit(f"kb: Azure DevOps said {e.code} {e.reason}")
        if a.json:
            print(json.dumps(out, indent=2, ensure_ascii=False))
        else:
            for i in out["items"]:
                print(f"#{i['id']}\t{i['type']}\t{i['state']}\t{i['title']}")
        return 0
    if a.action == "note":
        text = sys.stdin.read() if a.text in (None, "-") else a.text
        print(tracker_note(root, a.project, int(a.id.lstrip("#")), text, a.heading or "", a.comment))
        return 0
    if a.action == "backlog":
        try:
            data = tracker_backlog(root, sprint=a.sprint, search=a.search)
        except urllib.error.HTTPError as e:
            sys.exit(f"kb: Azure DevOps said {e.code} {e.reason}")
        if a.scope:
            from_scope = {a.scope} | set(scope_members(root, a.scope))
            data["items"] = [i for i in data["items"] if from_scope & set(i["scopes"])]
        if a.json:
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return 0
        for i in data["items"]:
            tasks = f"{i['tasks_done']}/{i['tasks_total']} tasks" if i["tasks_total"] else ""
            print(f"#{i['id']}\t{i['type']}\t{i['state']}\t{','.join(i['scopes'])}\t{i['assignee'] or '(unassigned)'}\t{i['title']}\t{tasks}".rstrip())
        return 0
    if a.action == "mine":
        try:
            work = my_work(root)
        except urllib.error.HTTPError as e:
            sys.exit(f"kb: Azure DevOps said {e.code} {e.reason}")
        if a.json:
            print(json.dumps(work, indent=2, ensure_ascii=False))
            return 0
        names = {"in_pr": "In PR", "in_progress": "In progress", "not_started": "Not started", "resolved": "Resolved"}
        if work["reviews"]:
            print("To review")
            for r in work["reviews"]:
                print(f"  !{r['id']}\t{r['repo']}\t{r['title']}\t{r['author']}")
        for stage in ("in_pr", "in_progress", "not_started", "resolved"):
            rows = [i for i in work["items"] if i["stage"] == stage]
            if rows:
                print(names[stage])
                for i in rows:
                    prs = " ".join(f"!{p['id']}" for p in i["prs"])
                    print(f"  #{i['id']}\t{i['type']}\t{i['state']}\t{i['title']}\t{i['sprint']}\t{prs}".rstrip())
        return 0
    if a.action == "tag":
        if not a.yes:
            sys.exit("kb: writing tags to the tracker needs --yes, after the user confirmed exactly which tags")
        print(align_item_tags(root, int(a.id.lstrip("#"))))
        return 0
    if a.action == "resolve":
        if not a.yes:
            sys.exit("kb: resolving changes the tracker; pass --yes after the user said to resolve it")
        sid = a.project or current_project_id(root)
        try:
            print(resolve_work_item(root, sid, int(a.id.lstrip("#"))))
        except (WorkError, ValueError) as e:
            sys.exit(f"kb: {e}")
        return 0
    if a.action == "start":
        sid = a.project or current_project_id(root)
        try:
            print(start_work_item(root, sid, int(a.id.lstrip("#"))))
        except (WorkError, ValueError) as e:
            sys.exit(f"kb: {e}")
        return 0
    if a.action in ("task-state", "state", "assign", "move") and (getattr(a, "project", None) or not ado_trackers(root)):
        here = getattr(a, "project", None) or (resolve_project(load_registry(root), Path(os.getcwd())) or {}).get("id")
        if here and (why := tracker_elsewhere(root, here)):
            sys.exit(why)
    if a.action in ("task-state", "state"):
        for line in set_task_states(root, [int(x.lstrip("#")) for x in a.ids], a.state):
            print(line)
        return 0
    if a.action == "assign":
        who = a.to.strip()
        if who.lower() == "me":
            orgs = list(ado_trackers(root).keys())
            if not orgs:
                sys.exit("kb: no azure-devops tracker is set up")
            who = ado_me(orgs[0][0], ado_pat())
            if not who:
                sys.exit("kb: Azure DevOps didn't say who you are")
        else:
            who = ado_identity(who)
        for line in set_work_item_fields(root, [int(x.lstrip("#")) for x in a.ids], {"System.AssignedTo": who},
                                         "assigned to " + ("you" if a.to.strip().lower() == "me" else a.to.strip())):
            print(line)
        return 0
    if a.action == "move":
        path = a.sprint
        if a.backlog:
            t = load_settings(root, a.project or current_project_id(root)).get("tracker") or {}
            if t.get("kind") != "azure-devops" or ado_tracker_missing(t):
                sys.exit("kb: that scope has no azure-devops tracker")
            path = ado_backlog_iteration(t)
        elif path in ("current", "next"):
            t = load_settings(root, a.project or current_project_id(root)).get("tracker") or {}
            path = ado_sprint(t, ado_pat(), path)
            if not path:
                sys.exit("kb: that scope's tracker has no tracker.iteration_root to find sprints under")
        for line in set_work_item_fields(root, [int(x.lstrip("#")) for x in a.ids], {"System.IterationPath": path},
                                         f"moved to {path.rsplit(chr(92), 1)[-1]}"):
            print(line)
        return 0
    pid = a.project or current_project_id(root)
    tracker = load_settings(root, pid).get("tracker") or {}
    if a.action == "show":
        print(json.dumps(tracker, indent=2, ensure_ascii=False))
        return 0 if tracker else 1
    if why := tracker_elsewhere(root, pid):
        sys.exit(why)
    if tracker.get("kind") != "azure-devops" or not tracker.get("organization") or not tracker.get("project"):
        sys.exit(f"kb: project {pid} has no azure-devops tracker yet; set tracker.kind, tracker.organization "
                 "and tracker.project with `kb settings set`")
    org, project = tracker["organization"], tracker["project"]
    base = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis"
    pat = ado_pat()
    try:
        if a.action == "sprints":
            sprints = ado_sprints(tracker, pat)
            if tracker.get("iteration_root") and not any(x["when"] != "past" for x in sprints):
                print(f"note: tracker.iteration_root {tracker['iteration_root']} has no current or future sprint; "
                      "showing every iteration. Update it with `kb settings set tracker.iteration_root`.")
                sprints = ado_sprints({**tracker, "iteration_root": ""}, pat)
            cur = next((i for i, s in enumerate(sprints) if s["when"] == "current"), None)
            if cur is None:
                cur = next((i for i, s in enumerate(sprints) if s["when"] == "future"), len(sprints))
            for s in sprints[max(0, cur - 1):cur + a.ahead + 1]:
                print(f"{s['when']:<8} {s['start']}..{s['finish']}  {s['path']}")
        elif a.action == "areas":
            tree = ado_request("GET", f"{base}/wit/classificationnodes/Areas?api-version=7.1&$depth=4", pat)

            def walk(node, path):
                here = f"{path}\\{node['name']}" if path else node["name"]
                print(here)
                for k in node.get("children") or []:
                    walk(k, here)
            walk(tree, "")
        elif a.action in ("features", "items"):
            types = [t.strip() for t in (a.type or ("Feature,Epic" if a.action == "features" else
                                                    "Product Backlog Item,Bug")).split(",")]
            where = [f"[System.TeamProject] = '{project}'",
                     "[System.WorkItemType] IN (" + ", ".join("'" + t.replace("'", "''") + "'" for t in types) + ")",
                     "[System.State] NOT IN ('Closed', 'Done', 'Removed')"]
            if a.search:
                where += [f"[System.Title] CONTAINS '{wiql_text(w)}'" for w in a.search.split() if w.strip("#!")]
            if a.area or tracker.get("area_path"):
                where.append(f"[System.AreaPath] UNDER '{(a.area or tracker['area_path']).replace(chr(39), chr(39) * 2)}'")
            wiql = {"query": "SELECT [System.Id] FROM WorkItems WHERE " + " AND ".join(where) +
                             " ORDER BY [System.ChangedDate] DESC"}
            ids = [w["id"] for w in ado_request("POST", f"{base}/wit/wiql?api-version=7.1&$top={a.limit}", pat,
                                                wiql).get("workItems", [])][:a.limit]
            if ids:
                got = ado_request("GET", f"https://dev.azure.com/{org}/_apis/wit/workitems?ids="
                                  f"{','.join(map(str, ids))}&fields=System.Title,System.State,System.WorkItemType"
                                  "&api-version=7.1", pat)
                for w in got.get("value", []):
                    f = w["fields"]
                    print(f"{w['id']}  [{f['System.WorkItemType']}, {f['System.State']}]  {f['System.Title']}")
        elif a.action == "item" and a.json:
            w = ado_request("GET", f"https://dev.azure.com/{org}/_apis/wit/workitems/{a.id}?"
                            "fields=System.Title,System.State,System.WorkItemType,System.AreaPath,System.IterationPath,"
                            "System.AssignedTo,System.Tags,System.Description,Microsoft.VSTS.Common.AcceptanceCriteria,"
                            "Microsoft.VSTS.TCM.ReproSteps&api-version=7.1", pat)
            f = w["fields"]
            print(json.dumps({
                "id": w["id"], "title": f.get("System.Title", ""), "state": f.get("System.State", ""),
                "type": f.get("System.WorkItemType", ""), "iteration": f.get("System.IterationPath", ""),
                "assignee": (f.get("System.AssignedTo") or {}).get("displayName", ""),
                "tags": [t.strip() for t in (f.get("System.Tags") or "").split(";") if t.strip()],
                "description": html_to_text(f.get("System.Description") or ""),
                "acceptance": html_to_text(f.get("Microsoft.VSTS.Common.AcceptanceCriteria") or ""),
                "repro": html_to_text(f.get("Microsoft.VSTS.TCM.ReproSteps") or ""),
                "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_workitems/edit/{w['id']}",
            }, indent=2))
        elif a.action == "item":
            w = ado_request("GET", f"https://dev.azure.com/{org}/_apis/wit/workitems/{a.id}?"
                            "fields=System.Title,System.State,System.WorkItemType,System.AreaPath,"
                            "System.IterationPath&api-version=7.1", pat)
            f = w["fields"]
            print(f"{w['id']}  [{f['System.WorkItemType']}, {f['System.State']}]  {f['System.Title']}\n"
                  f"area: {f.get('System.AreaPath', '')}\niteration: {f.get('System.IterationPath', '')}")
        elif a.action == "people":
            # Identity search needs a wider PAT scope; people assigned to recent items are enough to choose from.
            area = (a.area or tracker.get("area_path") or "").replace("'", "''")
            wiql = {"query": f"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '{project}' "
                             "AND [System.AssignedTo] <> ''" + (f" AND [System.AreaPath] UNDER '{area}'" if area else "") +
                             " AND [System.ChangedDate] >= @Today - 90 ORDER BY [System.ChangedDate] DESC"}
            ids = [w["id"] for w in ado_request("POST", f"{base}/wit/wiql?api-version=7.1&$top=200", pat,
                                                wiql).get("workItems", [])][:200]
            seen: dict[str, str] = {}
            for i in range(0, len(ids), 100):
                chunk = ",".join(map(str, ids[i:i + 100]))
                got = ado_request("GET", f"https://dev.azure.com/{org}/_apis/wit/workitems?ids={chunk}"
                                  "&fields=System.AssignedTo&api-version=7.1", pat)
                for w in got.get("value", []):
                    who = w["fields"].get("System.AssignedTo") or {}
                    if who.get("uniqueName"):
                        seen.setdefault(who["uniqueName"], who.get("displayName", ""))
            q = (a.search or "").lower()
            for mail, name in sorted(seen.items(), key=lambda kv: kv[1]):
                if q in name.lower() or q in mail.lower():
                    print(f"{name}  <{mail}>")
    except urllib.error.HTTPError as exc:
        sys.exit(f"kb: Azure DevOps said {exc.code}: {exc.read().decode()[:300]}")
    except urllib.error.URLError as exc:
        sys.exit(f"kb: could not reach Azure DevOps: {exc.reason}")
    return 0


# ---------------------------------------------------------------- built-in work tracker
#
# A scope whose tracker.kind is `local` keeps its features, PBIs, bugs and tasks in <private dir>/work.json.
# The Mindmill app reads and writes the same file, so keys it adds and this code doesn't know are kept on save.

WORK_TYPES = ("feature", "pbi", "bug", "task")
WORK_PARENT_TYPES = {"feature": (), "pbi": ("feature",), "bug": ("feature",), "task": ("pbi", "bug")}
BACKLOG_STATES = ("New", "Approved", "Committed", "Done", "Removed")
TASK_STATES = ("To Do", "In Progress", "Done", "Removed")
WORK_FILE_KEYS = ("version", "next_id", "use_sprints", "sprints", "items")
WORK_ITEM_KEYS = ("id", "type", "title", "state", "parent", "sprint", "assignee", "tags", "description", "acceptance",
                  "repro", "effort", "order", "created", "changed")
WORK_SPRINT_KEYS = ("name", "start", "finish")
LOCAL_STAGE = {"New": "not_started", "Approved": "not_started", "Committed": "in_progress", "Done": "resolved"}
SCRUM_STATES = [{"name": "New", "category": "Proposed"}, {"name": "Approved", "category": "Proposed"},
                {"name": "Committed", "category": "InProgress"}, {"name": "Done", "category": "Completed"},
                {"name": "Removed", "category": "Removed"}]


class WorkError(ValueError):
    pass


def work_path(root: Path, sid: str) -> Path:
    return private_dir(root, sid) / "work.json"


def empty_work() -> dict:
    return {"version": 1, "next_id": 1, "use_sprints": False, "sprints": [], "items": []}


def blank_work_item() -> dict:
    return {"id": 0, "type": "pbi", "title": "", "state": "New", "parent": None, "sprint": "", "assignee": "",
            "tags": [], "description": "", "acceptance": "", "repro": "", "effort": None, "order": 1.0,
            "created": "", "changed": ""}


def keys_first(d: dict, keys: tuple) -> dict:
    return {**{k: d[k] for k in keys if k in d}, **{k: v for k, v in d.items() if k not in keys}}


def load_work(root: Path, sid: str) -> dict:
    path = work_path(root, sid)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return empty_work()
    except (OSError, ValueError) as e:
        raise WorkError(f"can't read {path}: {e}")
    if not isinstance(data, dict):
        raise WorkError(f"{path} isn't a work tracker file")
    for k, v in empty_work().items():
        data.setdefault(k, v)
    return data


def work_json(data: dict) -> str:
    out = keys_first(data, WORK_FILE_KEYS)
    out["next_id"] = max(int(data.get("next_id") or 1), max((int(i["id"]) for i in data["items"]), default=0) + 1)
    out["sprints"] = [keys_first(s, WORK_SPRINT_KEYS) for s in data["sprints"]]
    out["items"] = [keys_first({**blank_work_item(), **i}, WORK_ITEM_KEYS) for i in data["items"]]
    return json.dumps(out, indent=2, ensure_ascii=False) + "\n"


def save_work(root: Path, sid: str, data: dict) -> None:
    write_atomic(work_path(root, sid), work_json(data))


def squash(s: str) -> str:
    return re.sub(r"[\s_-]+", "", s).lower()


def canonical_type(raw: str) -> str:
    kind = squash(raw)
    if kind not in WORK_TYPES:
        raise WorkError(f"{raw!r} isn't a work item type; use one of: {', '.join(WORK_TYPES)}")
    return kind


def work_states(kind: str) -> tuple[str, ...]:
    return TASK_STATES if kind == "task" else BACKLOG_STATES


def canonical_state(kind: str, raw: str) -> str:
    """`committed`, `in progress`, `todo` and `To-Do` become the stored names."""
    for s in work_states(kind):
        if squash(s) == squash(raw):
            return s
    raise WorkError(f"{raw!r} isn't a {kind} state; use one of: {', '.join(work_states(kind))}")


def find_work_item(data: dict, iid) -> dict:
    try:
        n = int(str(iid).lstrip("#"))
    except ValueError:
        raise WorkError(f"{iid!r} isn't a work item id")
    for i in data["items"]:
        if i["id"] == n:
            return i
    raise WorkError(f"no work item #{n}")


def check_parent(data: dict, kind: str, parent) -> int | None:
    if parent is None or str(parent).strip().lower() in ("", "none"):
        return None
    allowed = WORK_PARENT_TYPES[kind]
    if not allowed:
        raise WorkError("a feature has no parent")
    p = find_work_item(data, parent)
    if p["type"] not in allowed:
        raise WorkError(f"a {kind}'s parent must be a {' or '.join(allowed)}; #{p['id']} is a {p['type']}")
    return p["id"]


def next_order(data: dict, parent: int | None, but: int | None = None) -> float:
    siblings = [float(i.get("order") or 0) for i in data["items"] if i.get("parent") == parent and i["id"] != but]
    return max(siblings, default=0.0) + 1.0


def current_sprint(sprints: list[dict], today: str | None = None) -> dict | None:
    """The sprint running today. On a changeover day, when one sprint's last day is the next one's first, the later one."""
    today = today or dt.date.today().isoformat()
    return next((s for s in sorted(sprints, key=lambda s: s.get("start", ""), reverse=True)
                 if s.get("start", "") <= today <= s.get("finish", "")), None)


def sprint_when(s: dict, today: str | None = None, sprints: list[dict] = ()) -> str:
    """past, current or future. A sprint still in its dates is past once a later one among `sprints` has started."""
    today = today or dt.date.today().isoformat()
    if s["finish"] < today:
        return "past"
    if s["start"] > today:
        return "future"
    superseded = any(s["start"] < o.get("start", "") <= today <= o.get("finish", "") for o in sprints)
    return "past" if superseded else "current"


def resolve_sprint(data: dict, raw: str | None, today: str | None = None) -> str:
    """The sprint name to store: `current` is today's sprint, `none` (or nothing) none, else a sprint the file has."""
    name = (raw or "").strip()
    if not name or name.lower() == "none":
        return ""
    if name.lower() == "current":
        cur = current_sprint(data["sprints"], today)
        if not cur:
            raise WorkError("no sprint is current today; see `kb work sprint list`")
        return cur["name"]
    for s in data["sprints"]:
        if s["name"].lower() == name.lower():
            return s["name"]
    raise WorkError(f"no sprint {name!r}; add it with `kb work sprint add` or see `kb work sprint list`")


def parse_effort(raw):
    if raw is None or str(raw).strip().lower() in ("", "none"):
        return None
    try:
        v = float(raw)
    except ValueError:
        raise WorkError(f"effort {raw!r} isn't a number")
    return int(v) if v.is_integer() else v


def parse_tags(raw: str | list) -> list[str]:
    parts = raw if isinstance(raw, list) else str(raw).split(",")
    return list(dict.fromkeys(t.strip() for t in parts if t.strip()))


def add_work_item(data: dict, kind: str, title: str, parent=None, sprint: str | None = None, state: str | None = None,
                  now: str | None = None, today: str | None = None, **fields) -> dict:
    kind = canonical_type(kind)
    title = " ".join(title.split())
    if not title:
        raise WorkError("the title is empty")
    now = now or iso_now()
    item = {**blank_work_item(), "id": max(int(data.get("next_id") or 1),
                                           max((i["id"] for i in data["items"]), default=0) + 1),
            "type": kind, "title": title, "state": canonical_state(kind, state or work_states(kind)[0]),
            "parent": check_parent(data, kind, parent), "sprint": resolve_sprint(data, sprint, today),
            "created": now, "changed": now}
    item.update(work_fields(fields))
    item["order"] = next_order(data, item["parent"])
    data["items"].append(item)
    data["next_id"] = item["id"] + 1
    return item


def work_fields(fields: dict) -> dict:
    out = {}
    for k in ("description", "acceptance", "repro", "assignee"):
        if fields.get(k) is not None:
            out[k] = fields[k].strip() if k == "assignee" else fields[k]
    if out.get("assignee", "").lower() == "none":
        out["assignee"] = ""
    if fields.get("tags") is not None:
        out["tags"] = parse_tags(fields["tags"])
    if "effort" in fields and fields["effort"] is not None:
        out["effort"] = parse_effort(fields["effort"])
    return out


def update_work_item(data: dict, iid, changes: dict, now: str | None = None, today: str | None = None) -> dict:
    """Applies the given changes (only keys present): title, state, parent (`none` clears), sprint, and the rest."""
    item = find_work_item(data, iid)
    new = dict(item)
    if changes.get("title") is not None:
        new["title"] = " ".join(changes["title"].split())
        if not new["title"]:
            raise WorkError("the title is empty")
    if changes.get("state") is not None:
        new["state"] = canonical_state(item["type"], changes["state"])
    if changes.get("parent") is not None:
        new["parent"] = check_parent(data, item["type"], changes["parent"])
        if new["parent"] != item.get("parent"):
            new["order"] = next_order(data, new["parent"], but=item["id"])
    if changes.get("sprint") is not None:
        new["sprint"] = resolve_sprint(data, changes["sprint"], today)
    new.update(work_fields(changes))
    if new != item:
        new["changed"] = now or iso_now()
        item.clear()
        item.update(new)
    return item


def remove_work_items(data: dict, ids: list, delete: bool = False, now: str | None = None) -> list[str]:
    """Sets them Removed, or with `delete` takes them out of the file; an item with children can't be deleted."""
    items = [find_work_item(data, i) for i in ids]
    if delete:
        gone = {i["id"] for i in items}
        for i in items:
            kids = [c["id"] for c in data["items"] if c.get("parent") == i["id"] and c["id"] not in gone]
            if kids:
                raise WorkError(f"#{i['id']} has children ({', '.join(f'#{k}' for k in kids)}); "
                                "delete or move them first, or remove it without --delete")
        data["items"] = [i for i in data["items"] if i["id"] not in gone]
        return [f"#{i['id']} deleted" for i in items]
    for i in items:
        update_work_item(data, i["id"], {"state": "Removed"}, now)
    return [f"#{i['id']} removed" for i in items]


def work_tree(items: list[dict]) -> list[tuple[int, dict]]:
    """The items in backlog order, each after its parent with its depth. An item whose parent isn't among them is
    a root."""
    ids = {i["id"] for i in items}
    kids: dict = {}
    for i in items:
        kids.setdefault(i.get("parent") if i.get("parent") in ids else None, []).append(i)
    out: list[tuple[int, dict]] = []
    seen: set[int] = set()

    def walk(parent, depth):
        for i in sorted(kids.get(parent, []), key=lambda x: (float(x.get("order") or 0), x["id"])):
            if i["id"] not in seen:
                seen.add(i["id"])
                out.append((depth, i))
                walk(i["id"], depth + 1)
    walk(None, 0)
    return out


def filter_work(data: dict, types: str | None = None, states: str | None = None, sprint: str | None = None,
                include_closed: bool = False, today: str | None = None) -> list[dict]:
    kinds = {canonical_type(t) for t in types.split(",")} if types else None
    wanted = {squash(s) for s in states.split(",")} if states else None
    if wanted:
        known = {squash(s) for s in (*BACKLOG_STATES, *TASK_STATES)}
        bad = [s for s in states.split(",") if squash(s) not in known]
        if bad:
            raise WorkError(f"{bad[0]!r} isn't a state; use one of: {', '.join(dict.fromkeys((*BACKLOG_STATES, *TASK_STATES)))}")
    in_sprint = resolve_sprint(data, sprint, today) if sprint else None
    out = []
    for i in data["items"]:
        if kinds and i["type"] not in kinds:
            continue
        if wanted is not None:
            if squash(i["state"]) not in wanted:
                continue
        elif not include_closed and i["state"] in ("Done", "Removed"):
            continue
        if in_sprint is not None and i.get("sprint", "") != in_sprint:
            continue
        out.append(i)
    return out


def work_line(i: dict, depth: int = 0) -> str:
    return f"{'  ' * depth}#{i['id']}\t{i['type']}\t{i['state']}\t{i.get('sprint', '')}\t{i['title']}"


def work_children(data: dict, iid: int) -> list[dict]:
    return sorted((c for c in data["items"] if c.get("parent") == iid), key=lambda x: (float(x.get("order") or 0), x["id"]))


def local_tracker_scopes(root: Path) -> list[dict]:
    return [sc for sc in load_registry(root) if (load_settings(root, sc["id"]).get("tracker") or {}).get("kind") == "local"]


def load_work_or_warn(root: Path, sid: str) -> dict | None:
    try:
        return load_work(root, sid)
    except WorkError as e:
        print(f"kb: {sid}: {e}", file=sys.stderr)
        return None


def local_my_work(data: dict, sid: str) -> list[dict]:
    """A local tracker's open PBIs and bugs in the shape `my_work` gives Azure DevOps items."""
    return [{"id": i["id"], "type": i["type"], "title": i["title"], "state": i["state"], "sprint": i.get("sprint", ""),
             "changed": i.get("changed", ""), "project": sid, "url": "", "stage": LOCAL_STAGE.get(i["state"], "in_progress"),
             "prs": []}
            for _, i in work_tree(data["items"])
            if i["type"] in ("pbi", "bug") and i["state"] not in ("Done", "Removed")]


def local_backlog(data: dict, sid: str, done_days: int = 14, sprint: str | None = None, search: str | None = None,
                  today: str | None = None) -> list[dict]:
    """A local tracker's PBIs and bugs in the shape `tracker_backlog` gives Azure DevOps items, picked the same way."""
    today = today or dt.date.today().isoformat()
    since = (dt.date.fromisoformat(today) - dt.timedelta(days=done_days)).isoformat()
    q = (search or "").strip().lstrip("#")
    words = [w.strip("#!").lower() for w in (search or "").split() if w.strip("#!")]

    def picked(i: dict) -> bool:
        if search:
            return i["id"] == int(q) if q.isdigit() else (i["state"] != "Removed" and
                                                           all(w in i["title"].lower() for w in words))
        if sprint:
            return i.get("sprint", "") == sprint and i["state"] != "Removed"
        return i["state"] not in ("Done", "Removed") or (i["state"] == "Done" and i.get("changed", "")[:10] >= since)

    me = os.environ.get("KB_ME", "").strip()
    rows = []
    for _, i in work_tree(data["items"]):
        if i["type"] not in ("pbi", "bug") or not picked(i):
            continue
        tasks = sorted(({"id": t["id"], "title": t["title"], "state": t["state"], "assignee": t.get("assignee", "")}
                        for t in work_children(data, i["id"]) if t["type"] == "task" and t["state"] != "Removed"),
                       key=task_order)
        rows.append({
            "id": i["id"], "type": i["type"], "title": i["title"], "state": i["state"],
            "stage": "done" if i["state"] == "Done" else LOCAL_STAGE.get(i["state"], "in_progress"),
            "scope": sid, "scopes": [sid], "tags": list(i.get("tags") or []), "assignee": i.get("assignee", ""),
            "mine": bool(me) and (i.get("assignee") or "").strip().lower() == me.lower(), "sprint": i.get("sprint", ""), "changed": i.get("changed", ""), "url": "", "prs": [],
            "tasks": tasks, "tasks_done": sum(1 for t in tasks if task_is_done(t["state"])), "tasks_total": len(tasks),
        })
    return rows


def tracker_elsewhere(root: Path, sid: str) -> str | None:
    """Why `kb tracker` can't act for this scope: its work is in Jira or in Mindmill's own tracker."""
    kind = (load_settings(root, sid).get("tracker") or {}).get("kind")
    if kind == "jira":
        return f"kb: {sid} tracks work in Jira; use Claude's Jira connector"
    if kind == "local":
        return f"kb: {sid} tracks work in Mindmill's own tracker; use `kb work`"
    return None


def read_text_arg(value: str | None) -> str | None:
    return sys.stdin.read().strip("\n") if value == "-" else value


def cmd_work(a) -> int:
    root = kb_root()
    sid = a.scope or current_project_id(root)
    if sid not in scope_map(root):
        sys.exit(f"kb: unknown scope {sid}")
    try:
        return work_action(root, sid, a)
    except WorkError as e:
        sys.exit(f"kb: {e}")


def work_action(root: Path, sid: str, a) -> int:
    data = load_work(root, sid)
    as_json = getattr(a, "json", False)
    if a.action == "list":
        items = filter_work(data, a.type, a.state, a.sprint, a.all)
        if as_json:
            print(json.dumps({**data, "items": [i for _, i in work_tree(items)]}, indent=2, ensure_ascii=False))
            return 0
        for depth, i in work_tree(items):
            print(work_line(i, depth))
        return 0
    if a.action == "show":
        i = find_work_item(data, a.id)
        parent = next((p for p in data["items"] if p["id"] == i.get("parent")), None)
        kids = work_children(data, i["id"])
        if as_json:
            print(json.dumps({**i, "parent_title": parent["title"] if parent else "",
                              "children": [{k: c[k] for k in ("id", "type", "state", "title")} for c in kids]},
                             indent=2, ensure_ascii=False))
            return 0
        print(f"#{i['id']}  [{i['type']}, {i['state']}]  {i['title']}")
        if parent:
            print(f"parent: #{parent['id']} {parent['title']}")
        for k in ("sprint", "assignee", "effort"):
            if i.get(k) not in (None, ""):
                print(f"{k}: {i[k]}")
        if i.get("tags"):
            print(f"tags: {', '.join(i['tags'])}")
        print(f"created: {i.get('created', '')}  changed: {i.get('changed', '')}")
        if kids:
            print("children:")
            for c in kids:
                print(f"  #{c['id']}\t{c['type']}\t{c['state']}\t{c['title']}")
        for k, head in (("description", "Description"), ("acceptance", "Acceptance criteria"), ("repro", "Repro steps")):
            if (i.get(k) or "").strip():
                print(f"\n## {head}\n\n{i[k].strip()}")
        return 0
    if a.action in ("add", "set"):
        if [a.description, a.acceptance, a.repro].count("-") > 1:
            raise WorkError("only one of --description, --acceptance and --repro can read stdin")
        fields = {"description": read_text_arg(a.description), "acceptance": read_text_arg(a.acceptance),
                  "repro": read_text_arg(a.repro), "tags": a.tags, "effort": a.effort,
                  "assignee": local_assignee(a.assignee) if (a.assignee or "").strip().lower() == "me" else a.assignee}
        if a.action == "add":
            item = add_work_item(data, a.type, a.title, parent=a.parent, sprint=a.sprint, state=a.state, **fields)
            save_work(root, sid, data)
            print(f"created {item['id']}")
            return 0
        changes = {"title": a.title, "state": a.state, "parent": a.parent, "sprint": a.sprint, **fields}
        lines = []
        for iid in a.ids:
            before = dict(find_work_item(data, iid))
            item = update_work_item(data, iid, changes)
            lines.append(f"#{item['id']} " + ("updated" if item != before else "unchanged"))
        save_work(root, sid, data)
        print("\n".join(lines))
        return 0
    if a.action == "remove":
        lines = remove_work_items(data, a.ids, a.delete)
        save_work(root, sid, data)
        print("\n".join(lines))
        return 0
    if a.action == "sprint":
        if a.sprint_action == "list":
            sprints = sorted(data["sprints"], key=lambda s: s.get("start", ""))
            if as_json:
                print(json.dumps({"use_sprints": data["use_sprints"],
                                  "sprints": [{**s, "when": sprint_when(s, sprints=sprints)} for s in sprints]}, indent=2, ensure_ascii=False))
                return 0
            if not data["use_sprints"]:
                print("sprints are off; turn them on with `kb work sprint use on`")
            for s in sprints:
                print(f"{sprint_when(s, sprints=sprints):<8} {s['start']}..{s['finish']}  {s['name']}")
            return 0
        if a.sprint_action == "add":
            name = " ".join(a.name.split())
            for d in (a.start, a.finish):
                try:
                    dt.date.fromisoformat(d)
                except ValueError:
                    raise WorkError(f"{d!r} isn't a date (YYYY-MM-DD)")
            if a.finish < a.start:
                raise WorkError("the sprint finishes before it starts")
            if not name or name.lower() in ("current", "none") or any(s["name"].lower() == name.lower() for s in data["sprints"]):
                raise WorkError(f"there is already a sprint {name!r}" if name else "the sprint name is empty")
            data["sprints"].append({"name": name, "start": a.start, "finish": a.finish})
            data["sprints"].sort(key=lambda s: s.get("start", ""))
            save_work(root, sid, data)
            print(f"added sprint {name} {a.start}..{a.finish}")
            return 0
        data["use_sprints"] = a.on_off == "on"
        save_work(root, sid, data)
        print(f"sprints {a.on_off}")
        return 0
    if a.action == "board":
        sprint = a.sprint
        if sprint is None and data["use_sprints"] and current_sprint(data["sprints"]):
            sprint = "current"
        items = [i for i in filter_work(data, "pbi,bug", None, sprint, include_closed=True) if i["state"] != "Removed"]
        if sprint:
            print(f"Sprint: {resolve_sprint(data, sprint) or '(none)'}\n")
        for state in BACKLOG_STATES[:-1]:
            rows = [i for _, i in work_tree(items) if i["state"] == state]
            print(f"{state} ({len(rows)})")
            for i in rows:
                print(f"  #{i['id']}\t{i['type']}\t{i.get('assignee') or '-'}\t{i['title']}")
        return 0
    return 1


# ---------------------------------------------------------------- sprints, whichever tracker
#
# `kb sprint status` gives each tracker's sprint running today, the one before it and the one after it, so the app
# notices when a new sprint starts or one ends with nothing after it. `kb sprint review` lists what the previous
# sprint left unfinished, `kb sprint apply` carries out the user's decisions on it, and `kb sprint create` adds the
# next sprint where Mindmill can (its own tracker).

ADO_ITERATIONS_HELP = "Azure DevOps (Project settings → Boards → Project configuration → Iterations, then select it for the team)"
LOCAL_TASK_STATES = [{"name": "To Do", "category": "Proposed"}, {"name": "In Progress", "category": "InProgress"},
                     {"name": "Done", "category": "Completed"}, {"name": "Removed", "category": "Removed"}]
SPRINT_DECISIONS = ("state", "move", "backlog")


def sprint_brief(s: dict | None) -> dict | None:
    if not s:
        return None
    return {"name": s["name"], "path": s.get("path") or s["name"], "start": s["start"], "finish": s["finish"]}


def sprint_neighbours(sprints: list[dict], today: str) -> dict:
    """The sprint running today, the last one finished before it (before today when none runs), the first one after,
    and `state`: running, between (one ended, the next is planned), ended (nothing after it), upcoming or none."""
    dated = sorted((s for s in sprints if s.get("start") and s.get("finish")), key=lambda s: (s["start"], s["finish"]))
    cur = next((s for s in reversed(dated) if s["start"] <= today <= s["finish"]), None)
    prev = next((s for s in reversed(dated) if (s["start"] < cur["start"] if cur else s["finish"] < today)), None)
    nxt = next((s for s in dated if s["start"] > (cur["finish"] if cur else today)), None)
    state = "running" if cur else "between" if prev and nxt else "ended" if prev else "upcoming" if nxt else "none"
    since = (dt.date.fromisoformat(today) - dt.date.fromisoformat(prev["finish"])).days if prev and not cur else None
    return {"state": state, "current": sprint_brief(cur), "previous": sprint_brief(prev), "next": sprint_brief(nxt),
            "days_since_end": since}


def sprint_trackers(root: Path) -> list[dict]:
    """Every tracker the scopes use, once: Azure DevOps by organization, project and iteration root (scopes sharing
    them share sprints), any other kind per scope."""
    groups: dict[str, dict] = {}
    for sc in load_registry(root):
        t = load_settings(root, sc["id"]).get("tracker") or {}
        kind = str(t.get("kind") or "none")
        if kind == "none" or (kind == "azure-devops" and ado_tracker_missing(t)):
            continue
        key = (f"azure-devops:{t['organization']}/{t['project']}:{t.get('iteration_root') or ''}"
               if kind == "azure-devops" else f"{kind}:{sc['id']}")
        groups.setdefault(key, {"key": key, "kind": kind, "scopes": [], "tracker": t})["scopes"].append(sc["id"])
    return list(groups.values())


def sprint_tracker_of(root: Path, sid: str) -> dict:
    group = next((g for g in sprint_trackers(root) if sid in g["scopes"]), None)
    if not group:
        sys.exit(f"kb: {sid} has no tracker; set tracker.kind with `kb settings set` or in the Mindmill app")
    return group


def connector_name(kind: str) -> str:
    return {"jira": "Jira", "github": "GitHub"}.get(kind, kind[:1].upper() + kind[1:])


def ado_iterations_url(t: dict) -> str:
    return f"https://dev.azure.com/{t['organization']}/{urllib.parse.quote(t['project'])}/_settings/work"


def ado_backlog_iteration(t: dict) -> str:
    """Where "no sprint" is in Azure DevOps: tracker.backlog_iteration, else the iteration root the sprints sit
    under, else the project's root iteration."""
    return t.get("backlog_iteration") or (t.get("iteration_root") or "").rstrip("\\") or t["project"]


def tracker_sprint_status(root: Path, group: dict, today: str, pat: list | None = None) -> dict:
    """One tracker's sprints around today. `pat` caches the Azure DevOps PAT between trackers."""
    kind, t = group["kind"], group["tracker"]
    out = {"key": group["key"], "kind": kind, "scopes": group["scopes"], "reachable": True, "state": "none",
           "current": None, "previous": None, "next": None, "days_since_end": None, "can_create": False,
           "create_url": "", "note": ""}
    if kind == "local":
        data = load_work_or_warn(root, group["scopes"][0])
        if data is None:
            return {**out, "reachable": False, "state": "unknown", "note": "its work.json can't be read"}
        if not data["use_sprints"]:
            return {**out, "state": "off", "note": "sprints are off for this scope"}
        return {**out, **sprint_neighbours([{**s, "path": s["name"]} for s in data["sprints"]], today), "can_create": True}
    if kind == "azure-devops":
        out["create_url"] = ado_iterations_url(t)
        try:
            if pat is not None and not pat:
                pat.append(ado_pat())
            sprints = ado_sprints(t, pat[0] if pat else ado_pat())
        except SystemExit as e:
            return {**out, "reachable": False, "state": "unknown", "note": str(e.code).removeprefix("kb: ")}
        except urllib.error.HTTPError as e:
            return {**out, "reachable": False, "state": "unknown", "note": f"Azure DevOps said {e.code}: {ado_error_detail(e, 200)}"}
        except urllib.error.URLError as e:
            return {**out, "reachable": False, "state": "unknown", "note": f"could not reach Azure DevOps: {e.reason}"}
        except (KeyError, TypeError, ValueError) as e:
            return {**out, "reachable": False, "state": "unknown", "note": f"Azure DevOps sent iterations Mindmill can't read: {e}"}
        out.update(sprint_neighbours(sprints, today))
        if not t.get("iteration_root"):
            out["note"] = ("tracker.iteration_root isn't set, so every dated iteration in the project counts; "
                           "set it with `kb settings set tracker.iteration_root`")
        return out
    name = connector_name(kind)
    return {**out, "reachable": False, "state": "unknown",
            "note": f"{name} is read through Claude's {name} connector, not the kb CLI; ask Claude to check its sprints"}


def sprint_status(root: Path, scope: str | None = None, today: str | None = None) -> dict:
    today = today or dt.date.today().isoformat()
    groups = [g for g in sprint_trackers(root) if not scope or scope in g["scopes"]]
    pat: list = []
    return {"today": today, "trackers": [tracker_sprint_status(root, g, today, pat) for g in groups]}


def ado_states(api: str, pat: str, type_name: str) -> list[dict]:
    try:
        got = ado_request("GET", f"{api}/wit/workitemtypes/{urllib.parse.quote(type_name)}/states?api-version=7.1", pat)
    except urllib.error.HTTPError:
        return []
    return workflow_order([{"name": x["name"], "category": x.get("category", "")} for x in got.get("value", [])])


def state_category(states: list[dict], name: str) -> str | None:
    return next((s["category"] for s in states if s["name"].lower() == name.lower()), None)


def sprint_review(root: Path, sid: str, sprint: str | None = None, today: str | None = None) -> dict:
    """What a sprint (by default the one before today's) left unfinished in the scope's tracker: its PBIs and bugs
    not done or removed, each with its tasks, plus the states they can take and the sprint to move them to."""
    today = today or dt.date.today().isoformat()
    group = sprint_tracker_of(root, sid)
    status = tracker_sprint_status(root, group, today)
    if not status["reachable"]:
        sys.exit(f"kb: {status['note']}")
    if status["state"] == "off":
        sys.exit("kb: sprints are off for this scope; turn them on with `kb work sprint use on`")
    picked = ({"name": sprint.split("\\")[-1], "path": sprint, "start": "", "finish": ""} if sprint
              else status["previous"])
    out = {"key": group["key"], "kind": group["kind"], "scopes": group["scopes"], "state": status["state"],
           "sprint": picked, "target": status["current"] or status["next"], "items": [], "states": {}, "backlog": ""}
    if not picked:
        return out
    t = group["tracker"]
    if group["kind"] == "local":
        data = load_work(root, group["scopes"][0])
        out["states"] = {"pbi": SCRUM_STATES, "bug": SCRUM_STATES, "task": LOCAL_TASK_STATES}
        out["items"] = [i for i in local_backlog(data, sid, sprint=picked["path"], today=today) if i["stage"] != "done"]
        out["backlog"] = "no sprint"
        return out
    pat = ado_pat()
    api = f"https://dev.azure.com/{t['organization']}/{urllib.parse.quote(t['project'])}/_apis"
    out["states"] = {kind: ado_states(api, pat, name) for kind, name in
                     (("pbi", "Product Backlog Item"), ("bug", "Bug"), ("task", "Task"))}
    ours = set(group["scopes"])
    items = [i for i in tracker_backlog(root, sprint=picked["path"])["items"] if ours & set(i.get("scopes") or [])]

    def unfinished(i: dict) -> bool:
        category = state_category(out["states"].get(i["type"]) or [], i["state"])
        return category not in ("Completed", "Removed") if category else i["stage"] != "done"
    out["items"] = [i for i in items if unfinished(i)]
    out["backlog"] = ado_backlog_iteration(t)
    return out


def work_id(raw) -> int | None:
    if isinstance(raw, (int, float)) and not isinstance(raw, bool) and float(raw).is_integer():
        return int(raw)
    s = str(raw).strip().lstrip("#")
    return int(s) if s.isdigit() else None


def check_decision(d) -> dict:
    if not isinstance(d, dict) or work_id(d.get("id")) is None:
        raise WorkError(f"a decision needs an id: {d!r}")
    what = d.get("do")
    if what not in SPRINT_DECISIONS:
        raise WorkError(f"#{d['id']}: `do` must be one of {', '.join(SPRINT_DECISIONS)}")
    if what == "state" and not str(d.get("state") or "").strip():
        raise WorkError(f"#{d['id']}: which state?")
    if what == "move" and not str(d.get("sprint") or "").strip():
        raise WorkError(f"#{d['id']}: which sprint?")
    tasks = [work_id(x) for x in d.get("tasks") or []]
    if None in tasks:
        raise WorkError(f"#{d['id']}: a task id isn't a number")
    return {**d, "id": work_id(d["id"]), "tasks": tasks}


def decision_text(d: dict, backlog: str) -> str:
    if d["do"] == "state":
        return f"set to {d['state']}" + (f", {len(d['tasks'])} task(s) to {d['task_state']}" if d["tasks"] and d.get("task_state") else "")
    where = d["sprint"].split("\\")[-1] if d["do"] == "move" else backlog
    return f"moved to {where}" + (f" with {len(d['tasks'])} task(s)" if d["tasks"] else "")


def ado_patch_item(t: dict, pat: str, iid: int, fields: dict) -> None:
    ado_request("PATCH", f"https://dev.azure.com/{t['organization']}/{urllib.parse.quote(t['project'])}/_apis/wit/"
                f"workitems/{iid}?api-version=7.1", pat,
                [{"op": "add", "path": f"/fields/{k}", "value": v} for k, v in fields.items()],
                content_type="application/json-patch+json")


def apply_sprint_decisions(root: Path, sid: str, decisions: list[dict]) -> list[dict]:
    """Carries out each decision on its own, so one failing leaves the rest done; every one gets a result line.
    A move or a trip to the backlog takes the item's listed tasks along; a new state sets them to `task_state`."""
    group = sprint_tracker_of(root, sid)
    kind, t = group["kind"], group["tracker"]
    if kind not in ("local", "azure-devops"):
        sys.exit(f"kb: {sid} tracks work in {connector_name(kind)}; change it with Claude's {connector_name(kind)} connector")
    results = []
    if kind == "local":
        data = load_work(root, group["scopes"][0])
        for d in decisions:
            try:
                d = check_decision(d)
                if d["do"] == "state":
                    update_work_item(data, d["id"], {"state": d["state"]})
                    for tid in d["tasks"] if d.get("task_state") else []:
                        update_work_item(data, tid, {"state": d["task_state"]})
                else:
                    sprint = d["sprint"] if d["do"] == "move" else "none"
                    for iid in [d["id"], *d["tasks"]]:
                        update_work_item(data, iid, {"sprint": sprint})
                results.append({"id": d["id"], "ok": True, "message": f"#{d['id']} {decision_text(d, 'no sprint')}"})
            except WorkError as e:
                results.append({"id": d.get("id") if isinstance(d, dict) else None, "ok": False, "message": str(e)})
        save_work(root, group["scopes"][0], data)
        return results
    pat = ado_pat()
    backlog = ado_backlog_iteration(t)
    for d in decisions:
        try:
            d = check_decision(d)
        except WorkError as e:
            results.append({"id": d.get("id") if isinstance(d, dict) else None, "ok": False, "message": str(e)})
            continue
        if d["do"] == "state":
            fields, task_fields = {"System.State": d["state"]}, ({"System.State": d["task_state"]} if d.get("task_state") else None)
        else:
            path = d["sprint"] if d["do"] == "move" else backlog
            fields = task_fields = {"System.IterationPath": path}
        try:
            ado_patch_item(t, pat, d["id"], fields)
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            why = ado_error_detail(e, 300) if isinstance(e, urllib.error.HTTPError) else str(e.reason)
            results.append({"id": d["id"], "ok": False, "message": f"#{d['id']}: {why}"})
            continue
        failed = []
        for tid in d["tasks"] if task_fields else []:
            try:
                ado_patch_item(t, pat, tid, task_fields)
            except (urllib.error.HTTPError, urllib.error.URLError) as e:
                failed.append(f"task #{tid}: " + (ado_error_detail(e, 200) if isinstance(e, urllib.error.HTTPError) else str(e.reason)))
        message = f"#{d['id']} {decision_text(d, backlog.split(chr(92))[-1])}"
        results.append({"id": d["id"], "ok": not failed, "message": message + ("; " + "; ".join(failed) if failed else "")})
    return results


def next_sprint_proposal(sprints: list[dict], today: str) -> dict:
    """The sprint after the last one: the same length, starting the day after it ends (today when that is past),
    named with its number one up ("Sprint 42" → "Sprint 43")."""
    dated = sorted((s for s in sprints if s.get("start") and s.get("finish")), key=lambda s: s["finish"])
    if not dated:
        start = dt.date.fromisoformat(today)
        return {"name": "Sprint 1", "start": today, "finish": (start + dt.timedelta(days=13)).isoformat()}
    last = dated[-1]
    a, b = dt.date.fromisoformat(last["start"]), dt.date.fromisoformat(last["finish"])
    start = max(b + dt.timedelta(days=1), dt.date.fromisoformat(today))
    m = re.match(r"^(.*?)(\d+)(\D*)$", last["name"])
    name = f"{m.group(1)}{int(m.group(2)) + 1:0{len(m.group(2))}d}{m.group(3)}" if m else f"Sprint {len(dated) + 1}"
    taken = {s["name"].lower() for s in sprints}
    n = 2
    while name.lower() in taken:
        name = f"{last['name']} ({n})"
        n += 1
    return {"name": name, "start": start.isoformat(), "finish": (start + (b - a)).isoformat()}


def cmd_sprint(a) -> int:
    root = kb_root()
    today = a.today or dt.date.today().isoformat()
    if a.action == "status":
        data = sprint_status(root, a.scope, today)
        if a.json:
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return 0
        for t in data["trackers"]:
            parts = [t["kind"], ",".join(t["scopes"]), t["state"]]
            for k in ("previous", "current", "next"):
                if t[k]:
                    parts.append(f"{k} {t[k]['name']} ({t[k]['start']}..{t[k]['finish']})")
            if t["note"]:
                parts.append(f"note: {t['note']}")
            print("\t".join(parts))
        return 0
    sid = a.scope or current_project_id(root)
    if sid not in scope_map(root):
        sys.exit(f"kb: unknown scope {sid}")
    if a.action == "review":
        try:
            data = sprint_review(root, sid, a.sprint, today)
        except urllib.error.HTTPError as e:
            sys.exit(f"kb: Azure DevOps said {e.code}: {ado_error_detail(e, 300)}")
        except WorkError as e:
            sys.exit(f"kb: {e}")
        if a.json:
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return 0
        if not data["sprint"]:
            print("no sprint has finished yet")
            return 0
        print(f"{data['sprint']['name']}: {len(data['items'])} unfinished" +
              (f"; the next sprint is {data['target']['name']}" if data["target"] else "; no next sprint yet"))
        for i in data["items"]:
            tasks = f"{i['tasks_done']}/{i['tasks_total']} tasks" if i["tasks_total"] else ""
            print(f"#{i['id']}\t{i['type']}\t{i['state']}\t{i['assignee'] or '(unassigned)'}\t{i['title']}\t{tasks}".rstrip())
        return 0
    if a.action == "apply":
        try:
            decisions = json.loads(sys.stdin.read() or "[]")
        except ValueError as e:
            sys.exit(f"kb: the decisions aren't JSON: {e}")
        if isinstance(decisions, dict):
            decisions = decisions.get("decisions") or []
        if not a.yes:
            for d in decisions:
                try:
                    d = check_decision(d)
                    print(f"would have #{d['id']} {decision_text(d, 'the backlog')}")
                except WorkError as e:
                    print(f"invalid: {e}")
            print("nothing changed; add --yes once the user confirmed")
            return 0
        try:
            results = apply_sprint_decisions(root, sid, decisions)
        except WorkError as e:
            sys.exit(f"kb: {e}")
        if a.json:
            print(json.dumps({"results": results}, indent=2, ensure_ascii=False))
            return 0
        for r in results:
            print(("" if r["ok"] else "failed: ") + r["message"])
        return 0 if all(r["ok"] for r in results) else 1
    group = sprint_tracker_of(root, sid)
    if group["kind"] == "azure-devops":
        sys.exit(f"kb: Mindmill doesn't create iterations in Azure DevOps; add the next sprint in {ADO_ITERATIONS_HELP}: "
                 f"{ado_iterations_url(group['tracker'])}")
    if group["kind"] != "local":
        sys.exit(f"kb: {sid} tracks work in {connector_name(group['kind'])}; create the sprint there or with Claude's connector")
    data = load_work(root, group["scopes"][0])
    if not data["use_sprints"]:
        sys.exit("kb: sprints are off for this scope; turn them on with `kb work sprint use on`")
    plan = next_sprint_proposal(data["sprints"], today)
    name = " ".join((a.name or plan["name"]).split())
    start, finish = a.start or plan["start"], a.finish or plan["finish"]
    for d in (start, finish):
        try:
            dt.date.fromisoformat(d)
        except ValueError:
            sys.exit(f"kb: {d!r} isn't a date (YYYY-MM-DD)")
    if finish < start:
        sys.exit("kb: the sprint finishes before it starts")
    if not name or name.lower() in ("current", "none") or any(s["name"].lower() == name.lower() for s in data["sprints"]):
        sys.exit(f"kb: there is already a sprint {name!r}" if name else "kb: the sprint name is empty")
    data["sprints"].append({"name": name, "start": start, "finish": finish})
    data["sprints"].sort(key=lambda s: s.get("start", ""))
    save_work(root, group["scopes"][0], data)
    if a.json:
        print(json.dumps({"name": name, "path": name, "start": start, "finish": finish}, ensure_ascii=False))
    else:
        print(f"added sprint {name} {start}..{finish}")
    return 0


def html_to_text(html: str) -> str:
    """Azure DevOps rich text as plain text: lists as dashes, paragraphs on their own lines."""
    t = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", "", html)
    t = re.sub(r"(?i)<li[^>]*>", "\n- ", t)
    t = re.sub(r"(?i)<br\s*/?>|</(p|div|h[1-6]|tr|ul|ol)>", "\n", t)
    t = re.sub(r"<[^>]+>", "", t)
    t = html_lib.unescape(t).replace("\xa0", " ")
    t = re.sub(r"[ \t]+\n", "\n", t)
    return re.sub(r"\n{3,}", "\n\n", t).strip()


def md_to_html(md: str) -> str:
    import html
    out, in_list = [], False

    def inline(t: str) -> str:
        t = html.escape(t)
        t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
        t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
        t = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', t)
        return t

    for line in md.strip().splitlines():
        m = re.match(r"^\s*[-*]\s+(?:\[[ x]\]\s+)?(.*)$", line)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(m.group(1))}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.strip():
            out.append(f"<p>{inline(line.strip())}</p>")
    if in_list:
        out.append("</ul>")
    return "".join(out)


def body_section(body: str, heading: str) -> str:
    m = re.search(rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)", body, re.S | re.M)
    return m.group(1).strip() if m else ""


ENTRY_SECTIONS = "decisions|meetings|facts|architecture|followups|backlog|discussions|ideas|research|references|notes|inbox|goals|reminders|daily"


def private_ref_pattern(root: Path) -> re.Pattern:
    """KB entry ids, kb:// links and paths on this machine: they mean nothing to someone reading a work item."""
    ids = [re.escape(p["id"]) for p in load_registry(root)] or [r"[a-z0-9][a-z0-9-]*"]
    entry = rf"(?:{'|'.join(ids)})/(?:(?:{ENTRY_SECTIONS})/[\w.-]+|overview)"
    home = re.escape(str(Path.home()))
    rest = r"[^\s`()<>\[\]]"
    paths = [rf"{home}/{rest}+", rf"~/{rest}+", re.escape(str(root)) + rf"{rest}*", rf"kb://{rest}+"]
    return re.compile(rf"`?(?:{entry}|{'|'.join(paths)})`?")


def strip_private_refs(root: Path, text: str, removed: list[str]) -> str:
    """Takes parenthetical KB references, "(decision product/decisions/x)", out of text bound for a shared tracker."""
    if not text:
        return text
    pat = private_ref_pattern(root)

    def note(m: re.Match) -> str:
        removed.extend(x.strip("`") for x in pat.findall(m.group(0)))
        return ""

    text = re.sub(rf"\s*\((?:[^()]*?){pat.pattern}(?:[^()]*?)\)", note, text)
    return re.sub(r"[ \t]+([.,;:])", r"\1", text)


def private_refs_left(root: Path, *texts: str) -> list[str]:
    pat = private_ref_pattern(root)
    return list(dict.fromkeys(m.strip("`") for t in texts if t for m in pat.findall(t)))


def cmd_backlog(a) -> int:
    root = kb_root()
    if a.action == "duplicates":
        return backlog_duplicates_cmd(root, a)
    if a.action == "link":
        return backlog_link_cmd(root, a)
    if a.action == "create":
        entries = [backlog_entry(root, x) for x in a.ids]
        return max(backlog_create(root, e, a) for e in entries)
    e = backlog_entry(root, a.id)
    if a.action == "reject":
        e.set("status", "rejected")
        e.save()
        print(f"rejected {a.id}")
        return 0
    if a.action == "drop":
        return backlog_drop(root, e, a)
    if a.action == "not-duplicate":
        kept = related_values_of(e.get("not_duplicate_of"))
        e.set("not_duplicate_of", list(dict.fromkeys(kept + [x.strip().lstrip("#") for x in a.others if x.strip()])))
        e.save()
        print(f"{e.id}: not a duplicate of {', '.join(a.others)}")
        return 0
    sys.exit(f"kb: unknown backlog action {a.action}")


def backlog_entry(root: Path, eid: str) -> Entry:
    e = find_entry(root, eid)
    if not e or e.section != "backlog":
        sys.exit(f"kb: no backlog entry {eid}")
    return e


def prefixed_title(prefix: str, title: str) -> str:
    """The title with the tracker's prefix, once: a title that already starts with it ("Android: …") keeps its own."""
    word = prefix.strip()
    return title if word and title.lower().startswith(word.lower()) else prefix + title


def backlog_create(root: Path, e: Entry, a) -> int:
    if e.status != "proposed":
        sys.exit(f"kb: {e.id} is {e.status}, not proposed")
    tracker = load_settings(root, e.project).get("tracker") or {}
    if tracker.get("kind") == "local":
        return backlog_create_local(root, e, a)
    if why := tracker_elsewhere(root, e.project):
        sys.exit(why)
    if tracker.get("kind") != "azure-devops":
        sys.exit(f"kb: project {e.project} has no azure-devops tracker in settings.json")
    missing = ado_tracker_missing(tracker)
    if missing:
        sys.exit(f"kb: the {e.project} tracker has no {' or '.join(missing)} set. Fill in its Tracker settings "
                 f"(Project Settings → Tracker in the app, or `kb settings set tracker.<key> <value> --project {e.project}`).")
    kind = str(e.get("kind") or "pbi")
    wit = "Bug" if kind == "bug" else "Product Backlog Item"
    title = prefixed_title(tracker.get("title_prefix") or "", e.title)
    # The scope's tracker tags, plus only the entry tags the user aligned: KB tags stay in the KB otherwise.
    store = load_item_tags(root)
    entry_tag_list = normalize_tags(e.get("tags") or [])
    tags = list(dict.fromkeys([*tracker.get("tags", []),
                               *tracker_tag_additions(entry_tag_list, store["aligned_tags"], tracker.get("tags", []))]))
    desc = body_section(e.body, "Description") or e.body
    ac = body_section(e.body, "Acceptance criteria")
    # Work items are shared with the team: nothing that only resolves on this machine goes into them.
    removed: list[str] = []
    title, desc, ac = (strip_private_refs(root, t, removed) for t in (title, desc, ac))
    if removed:
        print("kb: left out of the work item (KB ids and local paths only make sense on this machine): "
              + ", ".join(dict.fromkeys(removed)), file=sys.stderr)
    left = private_refs_left(root, title, desc, ac)
    if left:
        sys.exit(f"kb: {e.id} mentions things that only exist on this machine: {', '.join(left)}. "
                 "Work items are shared, so describe the source in words instead (the meeting's name and date, "
                 "who decided what) and edit the backlog entry; its `source` field keeps the KB link.")
    which = a.sprint or str(e.get("sprint") or "current")
    if which in ("current", "next", "none"):
        sprint = None if which == "none" or not tracker.get("iteration_root") else ado_sprint(tracker, ado_pat(), which)
    else:
        sprint = re.sub(r"\\{2,}", r"\\", which)
    ops = [{"op": "add", "path": "/fields/System.Title", "value": title},
           {"op": "add", "path": "/fields/System.Description", "value": md_to_html(desc)}]
    if ac:
        field = "Microsoft.VSTS.TCM.ReproSteps" if kind == "bug" and tracker.get("bug_ac_as_repro") else \
            "Microsoft.VSTS.Common.AcceptanceCriteria"
        ops.append({"op": "add", "path": f"/fields/{field}", "value": md_to_html(ac)})
    area = re.sub(r"\\{2,}", r"\\", str(e.get("area") or tracker.get("area_path") or ""))
    if area and area != "none":
        ops.append({"op": "add", "path": "/fields/System.AreaPath", "value": area})
    if sprint:
        ops.append({"op": "add", "path": "/fields/System.IterationPath", "value": sprint})
    assignee = e.get("assignee") or tracker.get("assignee")
    if assignee and str(assignee).lower() == "me":
        assignee = ado_me(tracker["organization"], ado_pat()) if a.yes else "me (you)"
        if not assignee:
            sys.exit("kb: Azure DevOps didn't say who you are")
        ops.append({"op": "add", "path": "/fields/System.AssignedTo", "value": assignee})
    elif assignee and assignee != "none":
        ops.append({"op": "add", "path": "/fields/System.AssignedTo", "value": ado_identity(assignee)})
    if tags:
        ops.append({"op": "add", "path": "/fields/System.Tags", "value": "; ".join(tags)})
    if kind == "bug":
        found_in = e.get("found_in")
        if not found_in:
            sys.exit("kb: a bug needs found_in; set it on the backlog entry first")
        ops.append({"op": "add", "path": "/fields/Microsoft.VSTS.Build.FoundIn", "value": found_in})
    org, project = tracker["organization"], tracker["project"]
    items_api = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis/wit/workitems"
    parent, parent_note = backlog_parent(root, e, tracker, getattr(a, "parent", None))
    if parent:
        ops.append({"op": "add", "path": "/relations/-", "value": {
            "rel": "System.LinkTypes.Hierarchy-Reverse", "url": f"{items_api}/{parent}"}})
    related, pending = backlog_related(root, e)
    for n in related:
        ops.append({"op": "add", "path": "/relations/-", "value": {"rel": "System.LinkTypes.Related", "url": f"{items_api}/{n}"}})
    if not a.yes:
        plan = {"type": wit, "sprint": sprint, "operations": ops}
        if parent_note:
            plan["parent_from"] = parent_note
            print(f"kb: parent #{parent} {parent_note}", file=sys.stderr)
        if pending:
            plan["related_later"] = pending
        print(json.dumps(plan, indent=2, ensure_ascii=False))
        print("dry run: pass --yes to create it", file=sys.stderr)
        return 2
    url = f"{items_api}/${urllib.parse.quote(wit)}?api-version=7.1"
    try:
        created = ado_request("POST", url, ado_pat(), ops, "application/json-patch+json")
    except Exception as exc:  # urllib raises HTTPError with the server's message in the body
        sys.exit(f"kb: Azure DevOps refused the work item: {ado_error_detail(exc)}")
    wid = created["id"]
    web = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_workitems/edit/{wid}"
    e.set("status", "created")
    e.set("work_item", str(wid))
    e.set("url", web)
    if sprint:
        e.set("sprint", sprint)
    finish_created_links(root, e, wid, parent, related, pending)
    if entry_tag_list:
        store["items"][f"azure-devops:{wid}"] = {"tags": entry_tag_list, "aligned": []}
        save_item_tags(root, store)
    print(f"created {wid} {web}")
    print_link_notes(parent, parent_note, related, pending)
    return 0


def backlog_create_local(root: Path, e: Entry, a) -> int:
    """Creates the entry in Mindmill's own tracker, with its parent feature and related items."""
    sid = e.project
    try:
        data = load_work(root, sid)
    except WorkError as exc:
        sys.exit(f"kb: {exc}")
    kind = "bug" if str(e.get("kind") or "pbi") == "bug" else "pbi"
    parent, parent_note = backlog_parent(root, e, {}, getattr(a, "parent", None))
    if parent is not None and not any(i["id"] == parent and i["type"] == "feature" for i in data["items"]):
        if not parent_note:
            sys.exit(f"kb: #{parent} isn't a feature in {sid}'s tracker")
        print(f"kb: left out parent #{parent} {parent_note}: it isn't a feature in Mindmill's tracker", file=sys.stderr)
        parent, parent_note = None, ""
    related, pending = backlog_related(root, e)
    known = {i["id"] for i in data["items"]}
    related = [n for n in related if n in known]
    which = (a.sprint or str(e.get("sprint") or "none")).strip()
    sprint = None
    if data["use_sprints"] and which.lower() != "none":
        if which.lower() == "next":
            today = dt.date.today().isoformat()
            sprint = next((s["name"] for s in sorted(data["sprints"], key=lambda s: s["start"]) if s["start"] > today), None)
        else:
            sprint = which
    desc = (body_section(e.body, "Description") or e.body).strip()
    ac = body_section(e.body, "Acceptance criteria")
    assignee = str(e.get("assignee") or "")
    fields = {"description": desc, "acceptance": ac, "tags": normalize_tags(e.get("tags") or []),
              "assignee": "" if assignee.lower() == "none" else
              os.environ.get("KB_ME", "").strip() if assignee.lower() == "me" else assignee}
    if not a.yes:
        print(json.dumps({"tracker": "local", "type": kind, "title": e.title, "parent": parent, "related": related,
                          "sprint": sprint, **({"parent_from": parent_note} if parent_note else {}),
                          **({"related_later": pending} if pending else {})}, indent=2, ensure_ascii=False))
        print("dry run: pass --yes to create it", file=sys.stderr)
        return 2
    try:
        item = add_work_item(data, kind, e.title, parent=parent, sprint=sprint, **fields)
    except WorkError as exc:
        sys.exit(f"kb: {exc}")
    link_local_related(data, item["id"], related)
    save_work(root, sid, data)
    e.set("status", "created")
    e.set("work_item", str(item["id"]))
    if item.get("sprint"):
        e.set("sprint", item["sprint"])
    finish_created_links(root, e, item["id"], parent, related, pending)
    print(f"created {item['id']} -")
    print_link_notes(parent, parent_note, related, pending)
    return 0


def link_local_related(data: dict, iid: int, related: list[int]) -> None:
    """Related items in Mindmill's own tracker point at each other."""
    for i in data["items"]:
        if i["id"] == iid:
            i["related"] = sorted(set(i.get("related") or []) | {n for n in related if n != iid})
        elif i["id"] in related:
            i["related"] = sorted(set(i.get("related") or []) | {iid})


def print_link_notes(parent, parent_note: str, related: list[int], pending: list[str]) -> None:
    if parent:
        print(f"parent #{parent}" + (f" {parent_note}" if parent_note else ""))
    if related:
        print("related to " + ", ".join(f"#{n}" for n in related))
    if pending:
        print("related once created: " + ", ".join(pending))


def finish_created_links(root: Path, e: Entry, wid: int, parent, related: list[int], pending: list[str]) -> None:
    """Writes the new links into the entries: this one gets its parent and related work item numbers (entries not
    created yet stay as ids), entries that named it by id now name its number, and the related ones name it too."""
    if parent:
        e.set("parent", str(parent))
    if related or pending:
        e.set("related", [str(n) for n in related] + pending)
    e.save()
    for x in backlog_entries(root):
        if x.id == e.id:
            continue
        vals = related_values_of(x.get("related"))
        wi = str(x.get("work_item") or "")
        if e.id in vals:
            x.set("related", list(dict.fromkeys(str(wid) if v == e.id else v for v in vals)))
            x.save()
        elif wi.isdigit() and int(wi) in related and str(wid) not in vals:
            x.set("related", vals + [str(wid)])
            x.save()


def backlog_entries(root: Path) -> list[Entry]:
    return [x for x in all_entries(root) if x.section == "backlog"]


def related_values_of(v) -> list[str]:
    """`related` (or `not_duplicate_of`) as a list of work item numbers and entry ids, without `#`."""
    return [s for s in (str(x).strip().lstrip("#").strip() for x in as_list(v)) if s and s.lower() != "none"]


WORK_ITEM_REF = re.compile(r"_workitems/edit/(\d+)|#\s?(\d{3,})\b|"
                           r"\b(?:feature|epic|pbi|bug|product backlog item|user story|work item)\s+#?(\d{4,})\b", re.I)
PARENT_CUE = re.compile(r"\bparent\b|\bunder\s+(?:the\s+)?(?:feature|epic)\b|"
                        r"\b(?:feature|epic)\b(?=[^\n:]{0,12}:\s*\S*_workitems/edit/\d)", re.I)
PARENT_NEAR = re.compile(r"_workitems/edit/(\d+)|#\s?(\d+)\b|"
                         r"\b(?:feature|epic|pbi|product backlog item|user story)\s+#?(\d+)\b|^\s*(?:is\s+|:\s*)?(\d{3,})\b", re.I)
WEAK_PARENT = re.compile(r"\b(?:feature|epic)\s+#?(\d{4,})\b", re.I)
TIMESTAMPED_LINE = re.compile(r"^\s*[-*]\s*\d{1,2}:\d{2}\b")


def first_group(m: re.Match) -> int:
    return int(next(g for g in m.groups() if g))


def work_item_refs(text: str) -> list[int]:
    """Work item numbers a text names: Azure DevOps links, #431006, or "Feature 431006"."""
    return list(dict.fromkeys(first_group(m) for m in WORK_ITEM_REF.finditer(text or "")))


def parent_mentions(text: str, strong_only: bool = False) -> list[int]:
    """Work items a text names as the parent: "Parent: Feature #431006", "under Feature #431006", "Feature here:
    <link>". Without `strong_only` a plain "Feature 431006" counts too. Timestamped lines (transcript, screen text)
    are skipped: they quote whatever was on screen."""
    out: list[int] = []
    for line in (text or "").splitlines():
        if TIMESTAMPED_LINE.match(line):
            continue
        for m in PARENT_CUE.finditer(line):
            window = re.split(r"[.;]\s", line[m.end():m.end() + 160], maxsplit=1)[0]
            near = PARENT_NEAR.search(window)
            if near:
                out.append(first_group(near))
        if not strong_only:
            out += [int(x) for x in WEAK_PARENT.findall(line)]
    return list(dict.fromkeys(out))


def inferred_parent(root: Path, e: Entry) -> tuple[int | None, str]:
    """The one parent the entry's text names, else the one its sources clearly name ("under Feature #N")."""
    own = str(e.get("work_item") or "")
    found = [n for n in parent_mentions(e.body) if str(n) != own]
    if len(found) == 1:
        return found[0], "the entry's text"
    if found:
        return None, ""
    hits: dict[int, str] = {}
    for sid in as_list(e.get("source")):
        src = find_entry(root, sid)
        if src:
            for n in parent_mentions(src.body, strong_only=True):
                if str(n) != own:
                    hits.setdefault(n, src.title)
    if len(hits) == 1:
        n, title = next(iter(hits.items()))
        return n, f"its source “{title}”"
    return None, ""


def backlog_parent(root: Path, e: Entry, tracker: dict, override=None) -> tuple[int | None, str]:
    """The parent to link: `--parent`, else the entry's `parent`, else the one its text or source clearly names,
    else `tracker.default_parent` when the entry has no `parent` at all. The note says where an inferred one came from."""
    if override is not None:
        v = str(override).strip().lstrip("#")
        if v.lower() in ("", "none"):
            return None, ""
        if not v.isdigit():
            sys.exit(f"kb: parent {override!r} isn't a work item number")
        return int(v), ""
    raw = str(e.get("parent") or "").strip()
    if raw.lower() != "none" and (m := re.search(r"\d+", raw)):
        return int(m.group(0)), ""
    found, where = inferred_parent(root, e)
    if found:
        return found, f"(read from {where}; the entry's parent was {raw or 'empty'})"
    default = str(tracker.get("default_parent") or "").strip().lstrip("#")
    if not raw and default.isdigit():
        return int(default), ""
    return None, ""


def backlog_related(root: Path, e: Entry) -> tuple[list[int], list[str]]:
    """The work items to link as related: numbers in `related`, the work items of related entries already created,
    and of created entries whose `related` names this one. Related entries not created yet come back as pending."""
    numbers: list[int] = []
    pending: list[str] = []
    own = str(e.get("work_item") or "")
    for r in related_values_of(e.get("related")):
        if r.isdigit():
            n = int(r)
        else:
            other = find_entry(root, r)
            wi = str(other.get("work_item") or "") if other else ""
            if not wi.isdigit():
                pending.append(r)
                continue
            n = int(wi)
        if str(n) != own and n not in numbers:
            numbers.append(n)
    for x in backlog_entries(root):
        wi = str(x.get("work_item") or "")
        if x.id != e.id and wi.isdigit() and wi != own and e.id in related_values_of(x.get("related")) \
                and int(wi) not in numbers:
            numbers.append(int(wi))
    return numbers, pending


# ---------------------------------------------------------------- backlog link


def backlog_link_cmd(root: Path, a) -> int:
    """Sets the parent and related links of backlog entries or work items, in the tracker and in the entries.
    Several targets given together are siblings: each is linked as related to the others."""
    targets = [link_target(root, t, a.scope) for t in a.targets]
    extra: list[str] = [x for r in (a.related or []) for x in re.split(r"[,\s]+", r) if x.strip()]
    lines: list[str] = []
    done_pairs: set[tuple[int, int]] = set()
    plans = []
    for t in targets:
        e = t["entry"]
        clear = a.parent is not None and a.parent.strip().lower() == "none"
        parent, note = backlog_parent(root, e, {}, a.parent) if a.parent is not None or e else (None, "")
        want: list[str] = list(extra)
        want += [str(o["number"]) if o["number"] else o["entry"].id for o in targets if o is not t]
        if e:
            want += related_values_of(e.get("related"))
        want = [w for w in dict.fromkeys(w.strip().lstrip("#") for w in want) if w and w != str(t["number"] or "")
                and (not e or w != e.id)]
        plans.append((t, parent, note, clear, want))
    for t, parent, note, clear, want in plans:
        e = t["entry"]
        if not t["number"]:
            lines.append(f"{e.id}: parent {('#' + str(parent)) if parent else 'none'}, related "
                         f"{', '.join(want) or 'none'} (on the proposal; linked when it is created)")
            if a.yes:
                if parent or clear:
                    e.set("parent", str(parent) if parent else "none")
                if want:
                    e.set("related", list(dict.fromkeys(related_values_of(e.get("related")) + want)))
                e.save()
            continue
        numbers = []
        for w in want:
            if w.isdigit():
                numbers.append(int(w))
                continue
            other = find_entry(root, w)
            wi = str(other.get("work_item") or "") if other else ""
            if not wi.isdigit():
                sys.exit(f"kb: {w} isn't created yet; create it first, or link it from the proposal's `related`")
            numbers.append(int(wi))
        numbers = [n for n in dict.fromkeys(numbers) if n != t["number"]]
        kind = t["kind"]
        if kind == "local":
            lines += link_local(root, t, parent, clear, numbers, a.yes)
        else:
            lines += link_ado(root, t, parent, clear, numbers, done_pairs, a.yes)
        if note and parent:
            lines.append(f"#{t['number']}: parent #{parent} {note}")
        if a.yes:
            remember_links(root, t["number"], t["scope"], parent if parent else ("none" if clear else None), numbers)
    print("\n".join(lines) if lines else "nothing to link")
    if not a.yes:
        print("dry run: pass --yes to change the links", file=sys.stderr)
        return 2
    return 0


def link_target(root: Path, raw: str, scope: str | None) -> dict:
    """A backlog entry or a work item number, with its tracker."""
    v = raw.strip().lstrip("#")
    entry = None
    if v.isdigit():
        number = int(v)
        entry = next((x for x in backlog_entries(root) if str(x.get("work_item") or "") == v
                      and (not scope or x.project == scope)), None)
    else:
        entry = backlog_entry(root, raw)
        wi = str(entry.get("work_item") or "")
        number = int(wi) if wi.isdigit() and entry.status == "created" else None
    sid = scope or (entry.project if entry else None)
    tracker = (load_settings(root, sid).get("tracker") or {}) if sid else {}
    kind = tracker.get("kind") or ("azure-devops" if not sid else "")
    if number and kind == "jira":
        sys.exit(f"kb: {sid} tracks work in Jira; link it with Claude's Jira connector")
    if number and kind not in ("azure-devops", "local"):
        sys.exit(f"kb: {sid or raw} has no tracker kb can link in")
    return {"number": number, "entry": entry, "scope": sid, "kind": kind}


def link_ado(root: Path, t: dict, parent, clear: bool, numbers: list[int], done_pairs: set, yes: bool) -> list[str]:
    org, project = ado_tracker_for(root, t["scope"])
    pat = ado_pat()
    api = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis/wit/workitems"
    n = t["number"]
    try:
        w = ado_request("GET", f"{api}/{n}?$expand=relations&api-version=7.1", pat)
    except urllib.error.HTTPError as exc:
        sys.exit(f"kb: #{n}: Azure DevOps said {exc.code}: {ado_error_detail(exc, 300)}")
    current, related_now = None, set()
    for i, r in enumerate(w.get("relations") or []):
        tail = str(r.get("url", "")).rsplit("/", 1)[-1]
        if not tail.isdigit():
            continue
        if r.get("rel") == "System.LinkTypes.Hierarchy-Reverse":
            current = (i, int(tail))
        elif r.get("rel") == "System.LinkTypes.Related":
            related_now.add(int(tail))
    ops, lines = [], []
    if parent and (not current or current[1] != parent):
        if current:
            ops.append({"op": "remove", "path": f"/relations/{current[0]}"})
        ops.append({"op": "add", "path": "/relations/-", "value": {
            "rel": "System.LinkTypes.Hierarchy-Reverse", "url": f"{api}/{parent}"}})
        lines.append(f"#{n}: parent #{parent}" + (f" (was #{current[1]})" if current else ""))
    elif parent:
        lines.append(f"#{n}: parent #{parent} already")
    elif clear and current:
        ops.append({"op": "remove", "path": f"/relations/{current[0]}"})
        lines.append(f"#{n}: parent #{current[1]} removed")
    for m in numbers:
        if m in related_now or (n, m) in done_pairs:
            lines.append(f"#{n}: related to #{m} already")
            continue
        ops.append({"op": "add", "path": "/relations/-", "value": {"rel": "System.LinkTypes.Related", "url": f"{api}/{m}"}})
        done_pairs |= {(n, m), (m, n)}
        lines.append(f"#{n}: related to #{m}")
    if ops and yes:
        try:
            ado_request("PATCH", f"{api}/{n}?api-version=7.1", pat, ops, "application/json-patch+json")
        except urllib.error.HTTPError as exc:
            sys.exit(f"kb: #{n}: Azure DevOps said {exc.code}: {ado_error_detail(exc, 300)}")
    return lines


def link_local(root: Path, t: dict, parent, clear: bool, numbers: list[int], yes: bool) -> list[str]:
    sid, n = t["scope"], t["number"]
    data = load_work(root, sid)
    try:
        item = find_work_item(data, n)
        new_parent = check_parent(data, item["type"], parent) if parent else None
    except WorkError as exc:
        sys.exit(f"kb: {exc}")
    known = {i["id"] for i in data["items"]}
    numbers = [m for m in numbers if m in known]
    lines = []
    if new_parent and item.get("parent") != new_parent:
        lines.append(f"#{n}: parent #{new_parent}")
        item["parent"] = new_parent
    elif clear and item.get("parent"):
        lines.append(f"#{n}: parent #{item['parent']} removed")
        item["parent"] = None
    lines += [f"#{n}: related to #{m}" for m in numbers if m not in (item.get("related") or [])]
    link_local_related(data, n, numbers)
    if yes:
        save_work(root, sid, data)
    return lines


def remember_links(root: Path, number: int, scope: str | None, parent, related: list[int]) -> None:
    """Keeps the entries in step with the tracker: the entry of `number` gets its parent and related numbers, and the
    entries of the related items name `number` back."""
    for x in backlog_entries(root):
        wi = str(x.get("work_item") or "")
        if not wi.isdigit() or (scope and x.project != scope and int(wi) == number):
            continue
        vals = related_values_of(x.get("related"))
        changed = False
        if int(wi) == number:
            if parent is not None:
                x.set("parent", str(parent))
                changed = True
            add = [str(m) for m in related if str(m) not in vals]
            if add:
                x.set("related", vals + add)
                changed = True
        elif int(wi) in related and str(number) not in vals:
            x.set("related", vals + [str(number)])
            changed = True
        if changed:
            x.save()


# ---------------------------------------------------------------- backlog drop


def backlog_drop(root: Path, e: Entry, a) -> int:
    """Drops a proposal that duplicates an existing item: rejected with `duplicate_of`, optionally with its notes as
    a comment on the existing item. Entries that named it in `related` name the existing item instead."""
    if e.status != "proposed":
        sys.exit(f"kb: {e.id} is {e.status}, not proposed")
    of = a.duplicate_of.strip().lstrip("#")
    number = int(of) if of.isdigit() else None
    if not number and not find_entry(root, of):
        sys.exit(f"kb: no work item number or entry {a.duplicate_of}")
    plan = [f"{e.id}: rejected as a duplicate of {'#' + of if number else of}"]
    if a.comment:
        if not number:
            sys.exit("kb: --comment needs a work item number")
        notes = (body_section(e.body, "Description") or e.body).strip()
        ac = body_section(e.body, "Acceptance criteria")
        if ac:
            notes += "\n\n**Acceptance criteria**\n\n" + ac
        heading = f"Also proposed: {e.title}"
        plan.append(f"#{number}: comment “{heading}” with the proposal's description")
    if not a.yes:
        print("\n".join(plan))
        print("dry run: pass --yes to drop it", file=sys.stderr)
        return 2
    if a.comment:
        tracker = load_settings(root, e.project).get("tracker") or {}
        print(tracker_note(root, e.project, number, notes, heading, tracker.get("kind") != "local"))
    e.set("status", "rejected")
    e.set("duplicate_of", of)
    e.save()
    for x in backlog_entries(root):
        vals = related_values_of(x.get("related"))
        if x.id != e.id and e.id in vals:
            x.set("related", list(dict.fromkeys(of if v == e.id else v for v in vals)))
            x.save()
    print(plan[0])
    return 0


# ---------------------------------------------------------------- backlog duplicates

DUP_STOP_WORDS = {
    "the", "and", "for", "with", "from", "into", "that", "this", "when", "then", "than", "are", "was", "were",
    "will", "should", "can", "not", "but", "all", "any", "its", "our", "you", "your", "have", "has", "had",
    "how", "what", "who", "why", "where", "which", "about", "after", "before", "over", "under", "per", "via",
    "add", "make", "use", "new", "get", "set", "app", "android", "ios",
    "og", "der", "det", "den", "som", "til", "med", "fra", "ikke", "skal", "kan", "vil", "har", "eller",
    "pbi", "bug", "task",
    "show", "fix", "update", "remove", "support", "handle", "allow", "change", "display", "implement", "create",
    "enable", "user",
}
DUP_LIKELY = 0.75
DUP_POSSIBLE = 0.45


def dup_words(s: str) -> set[str]:
    """Lowercased words of three or more letters, without common words, generic verbs and a plural `s`
    (as BacklogDuplicates in the app)."""
    out = set()
    for p in re.split(r"[\W_]+", (s or "").lower()):
        if len(p) < 3 or p in DUP_STOP_WORDS or p.isdigit():
            continue
        if len(p) > 4 and p.endswith("s") and not p.endswith("ss"):
            p = p[:-1]
        if p not in DUP_STOP_WORDS:
            out.add(p)
    return out


def bare_title(title: str, prefix: str = "") -> str:
    """The title without the tracker's prefix and a short platform lead ("iOS: ", "Android: ")."""
    t = (title or "").strip()
    if prefix and t.startswith(prefix):
        t = t[len(prefix):]
    return re.sub(r"^[^:]{1,20}:\s+", "", t).strip()


def dice(a: set, b: set) -> float:
    return 2 * len(a & b) / (len(a) + len(b)) if a and b else 0.0


def duplicate_score(p: dict, c: dict) -> tuple[float, str, list[str]]:
    """How likely candidate `c` is the same work as proposal `p`, 0…1, its verdict and why. Title words count most;
    the description counts when both have one; the same parent and the proposal naming the item add to it. One shared
    title word is never enough on its own."""
    tp, tc = bare_title(p["title"]), bare_title(c["title"])
    wp, wc = dup_words(tp), dup_words(tc)
    t = 1.0 if tp and tp.lower() == tc.lower() else dice(wp, wc)
    reasons = []
    shared = sorted(wp & wc)
    if shared:
        reasons.append("title words: " + ", ".join(shared))
    score = t
    if p.get("text") and c.get("text"):
        ctx = dice(wp | dup_words(p["text"]), wc | dup_words(c["text"]))
        score = 0.7 * t + 0.3 * ctx
    if p.get("parent") and p.get("parent") == c.get("parent"):
        score += 0.1
        reasons.append(f"same parent #{p['parent']}")
    mentioned = bool(c.get("number")) and c["number"] in (p.get("refs") or [])
    if mentioned:
        score += 0.15
        reasons.append(f"the proposal mentions #{c['number']}")
    score = round(min(score, 1.0), 2)
    if len(shared) < 2 and t < 1 and not (shared and p.get("parent") and p.get("parent") == c.get("parent")):
        score = min(score, DUP_POSSIBLE - 0.01)
    verdict = "likely" if score >= DUP_LIKELY else "possible" if score >= DUP_POSSIBLE or mentioned else "none"
    return score, verdict, reasons


def duplicate_proposal(root: Path, e: Entry) -> dict:
    parent, _ = backlog_parent(root, e, {})
    related = related_values_of(e.get("related"))
    refs = [n for n in work_item_refs(e.body + "\n" + e.summary) if n != parent and str(n) not in related]
    return {"id": e.id, "scope": e.project, "title": e.title, "text": " ".join([e.summary, e.body])[:2000],
            "parent": parent, "refs": refs, "related": related,
            "dismissed": related_values_of(e.get("not_duplicate_of"))}


def same_scope_family(scope: str, others: list[str], info: dict[str, tuple[str, bool]]) -> bool:
    """Whether items of `others` can duplicate work in `scope`: the same scope, or the project-wide scope of the same
    project on either side. Another platform's scope (its twin) can't."""
    if scope in others:
        return True
    project, wide = info.get(scope, (scope, False))
    same_project = bool(others) and all(info.get(s, (s, False))[0] == project for s in others)
    return same_project and (wide or all(info.get(s, (s, False))[1] for s in others))


def duplicates_for(p: dict, candidates: list[dict], info: dict[str, tuple[str, bool]], limit: int = 3) -> dict:
    """The proposal's best matches among the candidates of its scope. Its parent, its related items and those the
    user said aren't duplicates are left out; items of another scope (the other platform's twin) too."""
    skip = set(p["related"]) | set(p["dismissed"]) | ({str(p["parent"])} if p.get("parent") else set()) | {p["id"]}
    matches = []
    for c in candidates:
        key = str(c.get("number") or c.get("id"))
        if key in skip or str(c.get("id")) in skip:
            continue
        if not same_scope_family(p["scope"], c.get("scopes") or [], info):
            continue
        score, verdict, reasons = duplicate_score(p, c)
        if verdict != "none":
            matches.append({**{k: c.get(k) for k in ("kind", "id", "number", "title", "state", "type", "url")},
                            "score": score, "verdict": verdict, "reasons": reasons})
    matches.sort(key=lambda m: (-m["score"], str(m["id"])))
    matches = matches[:limit]
    return {"id": p["id"], "scope": p["scope"], "title": p["title"],
            "verdict": matches[0]["verdict"] if matches else "none", "matches": matches}


def ado_duplicate_candidates(root: Path, org: str, project: str, owners: list[tuple[dict, dict]], wide: str,
                             proposals: list[dict], pat: str) -> list[dict]:
    """PBIs and bugs that could already cover the proposals: those open or done or created in the last 60 days in
    the trackers' areas, those whose title has a proposal's two most telling words, and the children of the
    proposals' parents."""
    api = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_apis"
    areas = sorted({t["area_path"] for _, t in owners if t.get("area_path")})
    where_area = (" AND (" + " OR ".join(f"[System.AreaPath] UNDER '{wiql_text(x)}'" for x in areas) + ")") if areas else ""
    base = ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
            f"{where_area} AND [System.WorkItemType] IN ('Product Backlog Item', 'Bug') AND [System.State] <> 'Removed' AND ")
    since = (dt.date.today() - dt.timedelta(days=60)).isoformat()
    queries = [(base + f"([System.State] NOT IN ('Done', 'Closed') OR [System.ChangedDate] >= '{since}' "
                f"OR [System.CreatedDate] >= '{since}') ORDER BY [System.ChangedDate] DESC", 400)]
    for p in proposals:
        words = sorted(dup_words(bare_title(p["title"])), key=lambda w: (-len(w), w))[:2]
        if words:
            queries.append((base + " AND ".join(f"[System.Title] CONTAINS '{wiql_text(w)}'" for w in words)
                            + " ORDER BY [System.ChangedDate] DESC", 20))
    ids: list[int] = []
    for q, top in queries:
        got = ado_request("POST", f"{api}/wit/wiql?api-version=7.1&$top={top}", pat, {"query": q}).get("workItems", [])
        ids += [w["id"] for w in got[:top]]
    for parent in sorted({p["parent"] for p in proposals if p.get("parent")}):
        try:
            w = ado_request("GET", f"{api}/wit/workitems/{parent}?$expand=relations&api-version=7.1", pat)
        except urllib.error.HTTPError:
            continue
        ids += [int(r["url"].rsplit("/", 1)[-1]) for r in w.get("relations") or []
                if r.get("rel") == "System.LinkTypes.Hierarchy-Forward" and r.get("url", "").rsplit("/", 1)[-1].isdigit()]
    ids = list(dict.fromkeys(ids))
    out = []
    fields = ("System.Title,System.State,System.WorkItemType,System.Tags,System.Parent,System.ChangedDate,"
              "System.CreatedDate,System.Description")
    for chunk in range(0, len(ids), 200):
        batch = ids[chunk:chunk + 200]
        for w in ado_request("GET", f"{api}/wit/workitems?ids={','.join(map(str, batch))}&fields={fields}"
                                    "&api-version=7.1", pat).get("value", []):
            f = w.get("fields") or {}
            if f.get("System.WorkItemType") not in ("Product Backlog Item", "Bug") or f.get("System.State") == "Removed":
                continue
            title = f.get("System.Title", "")
            tags = [x.strip() for x in (f.get("System.Tags") or "").split(";") if x.strip()]
            scopes = scopes_of_item(title, tags, owners, wide)
            prefix = next((t.get("title_prefix") or "" for sc, t in owners if sc["id"] == scopes[0]), "")
            out.append({"kind": "work_item", "id": str(w["id"]), "number": w["id"],
                        "type": "bug" if f.get("System.WorkItemType") == "Bug" else "pbi",
                        "title": title[len(prefix):] if prefix and title.startswith(prefix) else title,
                        "state": f.get("System.State", ""), "scopes": scopes, "parent": f.get("System.Parent"),
                        "changed": f.get("System.ChangedDate", ""), "created": f.get("System.CreatedDate", ""),
                        "text": html_to_text(f.get("System.Description") or "")[:1500],
                        "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_workitems/edit/{w['id']}"})
    return out


def local_duplicate_candidates(data: dict, sid: str) -> list[dict]:
    return [{"kind": "work_item", "id": str(i["id"]), "number": i["id"], "type": i["type"], "title": i["title"],
             "state": i["state"], "scopes": [sid], "parent": i.get("parent"), "text": i.get("description") or "",
             "url": ""}
            for i in data["items"] if i["type"] in ("pbi", "bug") and i["state"] != "Removed"]


def backlog_duplicates(root: Path, scope: str | None = None, only: list[str] | None = None,
                       offline: bool = False) -> dict:
    """Checks every proposal waiting to be created against the tracker's items, the KB's created entries and the
    other proposals of its scope."""
    entries = backlog_entries(root)
    proposals_e = [x for x in entries if x.status == "proposed" and not is_draft(x)
                   and (not scope or x.project == scope or scope in as_list(x.get("scopes")))
                   and (not only or x.id in only)]
    proposals = [duplicate_proposal(root, x) for x in proposals_e]
    registry = load_registry(root)
    info = {sc["id"]: (sc["project"], bool(sc.get("wide"))) for sc in registry}
    notes: list[str] = []
    tracker_candidates: list[dict] = []
    by_tracker: dict[tuple[str, str], list[dict]] = {}
    local_scopes = set()
    for p in proposals:
        t = load_settings(root, p["scope"]).get("tracker") or {}
        if t.get("kind") == "azure-devops" and t.get("organization") and t.get("project"):
            by_tracker.setdefault((t["organization"], t["project"]), []).append(p)
        elif t.get("kind") == "local":
            local_scopes.add(p["scope"])
        elif t.get("kind") == "jira":
            notes.append(f"{p['scope']}: Jira issues are checked through Claude's Jira connector, not here")
    if not offline and by_tracker:
        owners_by = ado_trackers(root)
        wide_of = {sc["project"]: sc["id"] for sc in registry if sc.get("wide")}
        try:
            pat = ado_pat()
        except SystemExit as exc:
            pat = ""
            notes.append(str(exc.code))
        for (org, proj), ps in by_tracker.items():
            if not pat:
                break
            owners = owners_by.get((org, proj)) or []
            w = wide_of.get(owners[0][0]["project"], owners[0][0]["id"]) if owners else ps[0]["scope"]
            try:
                tracker_candidates += ado_duplicate_candidates(root, org, proj, owners, w, ps, pat)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                notes.append(f"{org}/{proj}: {ado_error_detail(exc, 200)}")
    for sid in sorted(local_scopes):
        data = load_work_or_warn(root, sid)
        if data is not None:
            tracker_candidates += local_duplicate_candidates(data, sid)
    in_tracker = {str(c["number"]) for c in tracker_candidates}
    kb_candidates = []
    for x in entries:
        wi = str(x.get("work_item") or "")
        if x.status == "created" and wi and wi not in in_tracker:
            kb_candidates.append({"kind": "entry", "id": x.id, "number": int(wi) if wi.isdigit() else None,
                                  "type": str(x.get("kind") or "pbi"), "title": x.title, "state": "created",
                                  "scopes": [x.project], "parent": backlog_parent(root, x, {})[0],
                                  "text": " ".join([x.summary, x.body])[:1500], "url": str(x.get("url") or "")})
    for x in entries:
        if x.status == "proposed" and not is_draft(x):
            kb_candidates.append({"kind": "proposal", "id": x.id, "number": None, "type": str(x.get("kind") or "pbi"),
                                  "title": x.title, "state": "proposed", "scopes": [x.project],
                                  "parent": backlog_parent(root, x, {})[0],
                                  "text": " ".join([x.summary, x.body])[:1500], "url": ""})
    candidates = tracker_candidates + kb_candidates
    return {"checked": iso_now(), "proposals": [duplicates_for(p, candidates, info) for p in proposals],
            "candidates": tracker_candidates, "notes": notes}


def backlog_duplicates_cmd(root: Path, a) -> int:
    report = backlog_duplicates(root, a.scope, a.entry or None, a.offline)
    if a.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    for p in report["proposals"]:
        if p["verdict"] == "none":
            print(f"{p['id']}: no match")
            continue
        for m in p["matches"]:
            label = f"#{m['number']}" if m.get("number") else m["id"]
            print(f"{p['id']}: {m['verdict']} duplicate of {label} {m['title']} ({m['state']}, {m['score']:.2f}; "
                  f"{'; '.join(m['reasons'])})")
    for n in report["notes"]:
        print(f"kb: {n}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------- daily plan


def daily_path(root: Path, date: str) -> Path:
    return home(root) / "daily" / f"{date}.md"


def cmd_today(a) -> int:
    root = kb_root()
    date = a.date or dt.date.today().isoformat()
    path = daily_path(root, date)
    if a.check is None:
        print(path)
        return 0 if path.exists() else 1
    try:
        lines = path.read_text(encoding="utf-8").split("\n")
    except OSError:
        sys.exit(f"kb: no daily plan for {date}")
    want = a.check.strip()
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*[-*] )\[([ xX])\] (.*)$", line)
        if m and m.group(3).strip() == want:
            lines[i] = f"{m.group(1)}[{'x' if a.done == 'true' else ' '}] {m.group(3)}"
            write_atomic(path, "\n".join(lines))
            print(f"{'done' if a.done == 'true' else 'open'}: {want}")
            return 0
    sys.exit(f"kb: no checklist line {want!r} in {path}")


# ---------------------------------------------------------------- knowledge sources


SOURCE_KINDS = ("folder", "url", "ado-wiki", "ado-work-items", "ado-repos", "teams", "outlook", "mcp", "command")
CLAUDE_ONLY_KINDS = ("teams", "outlook", "mcp")


def global_sources_path(root: Path) -> Path:
    return home(root) / "sources.json"


def read_sources(root: Path, pid: str | None) -> list[dict]:
    if pid is None:
        try:
            return json.loads(global_sources_path(root).read_text()).get("sources", [])
        except (OSError, ValueError):
            return []
    return load_settings(root, pid).get("sources", [])


def write_sources(root: Path, pid: str | None, sources: list[dict]) -> None:
    if pid is None:
        path = global_sources_path(root)
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            data = {}
        data["sources"] = sources
    else:
        path = settings_path(root, pid)
        data = load_settings(root, pid)
        data["sources"] = sources
    write_atomic(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def builtin_sources(root: Path, pid: str) -> list[dict]:
    projects = {p["id"]: p for p in load_registry(root)}
    project = projects.get(pid, {})
    out = [{"id": "kb", "kind": "kb", "title": "Knowledge base", "scope": "builtin", "enabled": True,
            "use_for": f"Decisions, meetings, facts, architecture and follow-ups recorded for {pid}",
            "config": {"path": str(private_dir(root, pid))}}]
    for path in project.get("paths", []):
        out.append({"id": "code" if len(project["paths"]) == 1 else f"code:{Path(path).name}",
                    "kind": "folder", "title": f"Code and docs ({Path(path).name})", "scope": "builtin",
                    "enabled": True, "use_for": "How the code works today; in-repo docs and ai-context",
                    "config": {"path": path}})
    for rid in project.get("related", []):
        rp = projects.get(rid)
        if rp:
            out.append({"id": f"related:{rid}", "kind": "related", "title": f"{rp.get('title', rid)} (reference)",
                        "scope": "builtin", "enabled": True,
                        "use_for": f"How {rp.get('title', rid)} does it; its KB and repos. Reference only",
                        "config": {"project": rid, "paths": rp.get("paths", [])}})
    return out


def all_sources(root: Path, pid: str) -> list[dict]:
    project = [{**s, "scope": "project"} for s in read_sources(root, pid)]
    glob_ = [{**s, "scope": "global"} for s in read_sources(root, None)]
    return builtin_sources(root, pid) + project + glob_


def find_source(root: Path, pid: str, sid: str) -> dict | None:
    return next((s for s in all_sources(root, pid) if s.get("id") == sid), None)


def cmd_sources(a) -> int:
    root = kb_root()
    if a.action in ("add", "remove") and a.globally:
        pid = None
    else:
        pid = a.project or current_project_id(root)
    if a.action == "list":
        sources = all_sources(root, pid)
        if a.json:
            print(json.dumps(sources, indent=2, ensure_ascii=False))
        else:
            for s in sources:
                flag = "" if s.get("enabled", True) else " (disabled)"
                print(f"{s['id']}\t{s['kind']}\t{s['scope']}\t{s.get('title', '')}{flag}\t{s.get('use_for', '')}")
        return 0
    if a.action == "add":
        sources = read_sources(root, pid)
        taken = {s.get("id") for s in sources} | {"kb", "code"}
        sid = a.id or slugify(a.title)
        base, i = sid, 2
        while sid in taken:
            sid, i = f"{base}-{i}", i + 1
        config = {k: v for k, v in parse_field_args(a.config)}
        sources.append({"id": sid, "kind": a.kind, "title": a.title, "use_for": a.use_for,
                        "enabled": True, "config": config})
        write_sources(root, pid, sources)
        print(sid)
        return 0
    if a.action == "remove":
        sources = read_sources(root, pid)
        kept = [s for s in sources if s.get("id") != a.id]
        if len(kept) == len(sources):
            sys.exit(f"kb: no source {a.id} in {'global sources' if pid is None else pid}")
        write_sources(root, pid, kept)
        print(f"removed {a.id}")
        return 0
    if a.action == "enable":
        for scope_pid in ([pid] if not a.globally else [None]):
            sources = read_sources(root, scope_pid)
            for s in sources:
                if s.get("id") == a.id:
                    s["enabled"] = a.state == "on"
                    write_sources(root, scope_pid, sources)
                    print(f"{a.id} {'enabled' if a.state == 'on' else 'disabled'}")
                    return 0
        sys.exit(f"kb: no source {a.id}")
    s = find_source(root, pid, a.id)
    if not s:
        sys.exit(f"kb: no source {a.id} for {pid}")
    return test_source(s, a.query)


def test_source(s: dict, query: str) -> int:
    kind, cfg = s["kind"], s.get("config") or {}
    if kind in CLAUDE_ONLY_KINDS:
        print(f"{s['id']} ({kind}) is read through Claude's connectors, not the CLI. Test it with Claude.")
        return 3
    if kind in ("folder", "kb", "related"):
        paths = cfg.get("paths") or [cfg.get("path")]
        hits = 0
        terms = query.lower().split()
        for base in filter(None, paths):
            base = Path(os.path.expanduser(base))
            pattern = cfg.get("glob") or "**/*"
            for p in base.glob(pattern):
                if hits >= 10:
                    break
                if not p.is_file() or any(part.startswith(".") or part in ("build", "node_modules")
                                           for part in p.relative_to(base).parts):
                    continue
                if p.suffix.lower() not in (".md", ".txt", ".kt", ".kts", ".swift", ".py", ".json", ".yml",
                                            ".yaml", ".xml", ".html", ".fbs", ".h", ".cpp", ".c", ".ts", ".js"):
                    continue
                try:
                    text = p.read_text(encoding="utf-8", errors="ignore").lower()
                except OSError:
                    continue
                if all(t in text for t in terms):
                    print(p)
                    hits += 1
        print(f"{hits} matching files" + (" (stopped at 10)" if hits >= 10 else ""), file=sys.stderr)
        return 0 if hits else 1
    if kind == "command":
        r = run_shell(str(cfg.get("run", "")), query, os.path.expanduser(cfg["cwd"]) if cfg.get("cwd") else None, 60)
        print(r.stdout[:4000])
        if r.stderr:
            print(r.stderr[:1000], file=sys.stderr)
        return r.returncode
    if kind == "url":
        try:
            with urllib.request.urlopen(cfg["url"], timeout=20) as resp:
                text = resp.read(200_000).decode("utf-8", errors="ignore")
            plain = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", "", text)))
            found = query.lower() in plain.lower()
            print(f"fetched {len(text)} bytes; query {'found' if found else 'not found'} on the page")
            print(plain[:500])
            return 0
        except Exception as exc:
            print(f"could not fetch {cfg.get('url')}: {exc}", file=sys.stderr)
            return 1
    org, project = cfg.get("organization"), cfg.get("project")
    if not org or not project:
        sys.exit(f"kb: {s['id']} needs config organization and project")
    pat = ado_pat()
    q = urllib.parse.quote(project)
    try:
        if kind == "ado-wiki":
            res = ado_request("POST", f"https://almsearch.dev.azure.com/{org}/{q}/_apis/search/wikisearchresults"
                              "?api-version=7.1", pat, {"searchText": query, "$top": 5})
            for r in res.get("results", []):
                print(f"{r.get('fileName')}\t{r.get('path')}")
            return 0 if res.get("results") else 1
        if kind == "ado-repos":
            body = {"searchText": query, "$top": 5}
            if cfg.get("repos"):
                body["filters"] = {"Repository": cfg["repos"], "Project": [project]}
            res = ado_request("POST", f"https://almsearch.dev.azure.com/{org}/{q}/_apis/search/codesearchresults"
                              "?api-version=7.1", pat, body)
            for r in res.get("results", []):
                print(f"{(r.get('repository') or {}).get('name')}\t{r.get('path')}")
            return 0 if res.get("results") else 1
        if kind == "ado-work-items":
            safe = query.replace("'", "''")
            area = f" AND [System.AreaPath] UNDER '{cfg['area_path']}'" if cfg.get("area_path") else ""
            wiql = (f"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project{area} "
                    f"AND [System.Title] CONTAINS '{safe}' ORDER BY [System.ChangedDate] DESC")
            res = ado_request("POST", f"https://dev.azure.com/{org}/{q}/_apis/wit/wiql?$top=5&api-version=7.1",
                              pat, {"query": wiql})
            for w in res.get("workItems", [])[:5]:
                print(f"ado:{w['id']}\t{w['url']}")
            return 0 if res.get("workItems") else 1
    except Exception as exc:
        detail = exc.read().decode()[:300] if hasattr(exc, "read") else str(exc)
        print(f"{kind} request failed: {detail}", file=sys.stderr)
        return 1
    print(f"no CLI test for kind {kind}", file=sys.stderr)
    return 3


# ---------------------------------------------------------------- delete


REFERENCE_FIELDS = ("supersedes", "superseded_by", "source", "raised_in", "resolved_by", "proposed_by", "previous", "related", "merged_into",
                    "updates")


def references_to(root: Path, target: str) -> list[tuple[Entry, str]]:
    hits = []
    for e in all_entries(root):
        if e.id == target:
            continue
        for key in REFERENCE_FIELDS:
            v = e.get(key)
            if v == target or (isinstance(v, list) and target in v):
                hits.append((e, key))
    return hits


def cmd_delete(a) -> int:
    """Delete an entry and unhook everything that pointed at it, so no link dangles."""
    root = kb_root()
    target = find_entry(root, a.id)
    if not target:
        sys.exit(f"kb: no entry {a.id}")
    lines = delete_entry(root, target, a.dry_run)
    print(f"{'would delete' if a.dry_run else 'deleted'} {target.id}" + (f" ({target.path})" if a.dry_run else ""))
    for line in lines:
        print(f"  {line}")
    return 0


def delete_entry(root: Path, target: Entry, dry_run: bool = False) -> list[str]:
    refs = references_to(root, target.id)
    plan = []
    for e, key in refs:
        if key == "updates":
            plan.append((e, key, f"{e.id}: pending change to it dropped"))
        elif key == "superseded_by":
            plan.append((e, key, f"{e.id}: back in force (it was superseded by the deleted decision)"))
        else:
            plan.append((e, key, f"{e.id}: drop {key} → {target.id}"))
    if target.section == "decisions":
        for old in target.get("supersedes") or []:
            o = find_entry(root, old)
            if o and o.get("superseded_by") == target.id and not any(x.id == o.id for x, _, _ in plan):
                plan.append((o, "superseded_by", f"{o.id}: back in force (it was superseded by the deleted decision)"))
    if dry_run:
        return [line for _, _, line in plan]
    for e, key, _ in plan:
        if key == "updates":
            e.path.unlink(missing_ok=True)
            continue
        e = find_entry(root, e.id) or e
        if key == "superseded_by":
            e.fields = [(k, v) for k, v in e.fields if k != "superseded_by"]
            if e.get("status") == "superseded":
                e.set("status", "active")
        else:
            v = e.get(key)
            if isinstance(v, list):
                e.set(key, [x for x in v if x != target.id])
            else:
                e.fields = [(k, val) for k, val in e.fields if k != key]
        e.fields = [(k, v) for k, v in e.fields if v not in ("", [], None)]
        e.save()
    target.path.unlink()
    share_sync(root, target.project)
    return [line for _, _, line in plan]


# ---------------------------------------------------------------- move


def cmd_move(a) -> int:
    """Move an entry to another project, keeping its file name, and repoint every reference to it."""
    root = kb_root()
    target = find_entry(root, a.id)
    if not target or target.section == "overview":
        sys.exit(f"kb: no movable entry {a.id}")
    if a.project not in {p["id"] for p in load_registry(root)}:
        sys.exit(f"kb: unknown project {a.project}")
    if a.project == target.project:
        print(target.id)
        return 0
    dest = unique_path(entry_dir(root, a.project, target.section) / target.section / target.path.name)
    new_id = f"{a.project}/{target.section}/{dest.stem}"
    for e, key in references_to(root, target.id):
        e = find_entry(root, e.id) or e
        v = e.get(key)
        e.set(key, [new_id if x == target.id else x for x in v] if isinstance(v, list) else new_id)
        e.save()
    known = scope_map(root)
    kept = [x for x in entry_scopes(target)[1:] if x != a.project and x in known
            and known[x]["project"] == known[a.project]["project"]]
    target.fields = [(k, v) for k, v in target.fields if k not in ("project_guessed", "scopes")]
    target.fields += scopes_field([a.project, *kept])
    write_atomic(dest, render_entry(target.fields, target.body))
    target.path.unlink()
    share_sync(root, target.project)
    print(new_id)
    print(dest)
    return 0


# ---------------------------------------------------------------- reminders


REMINDER_STATUSES = ("open", "proposed", "done", "dismissed")


def reminders_dir(root: Path) -> Path:
    return home(root) / "reminders"


def read_reminder(path: Path) -> Entry | None:
    try:
        fields, body = split_frontmatter(path.read_text(encoding="utf-8"))
    except OSError:
        return None
    return Entry(f"reminders/{path.stem}", "", "reminders", path, fields, body)


def all_reminders(root: Path) -> list[Entry]:
    d = reminders_dir(root)
    out = [read_reminder(p) for p in sorted(d.glob("*.md"))] if d.is_dir() else []
    return [r for r in out if r]


def find_reminder(root: Path, rid: str) -> Entry:
    stem = rid.strip().removesuffix(".md").split("/")[-1]
    r = read_reminder(reminders_dir(root) / f"{stem}.md")
    if not r:
        sys.exit(f"kb: no reminder {rid}")
    return r


def cmd_reminder(a) -> int:
    root = kb_root()
    today = dt.date.today().isoformat()
    if a.reminder_cmd == "add":
        if a.due and not re.match(r"^\d{4}-\d{2}-\d{2}$", a.due):
            sys.exit("kb: --due needs YYYY-MM-DD")
        if a.project and a.project not in {p["id"] for p in load_registry(root)}:
            sys.exit(f"kb: unknown project {a.project}")
        if a.source:
            dup = next((r for r in all_reminders(root) if r.get("source") == a.source), None)
            if dup:
                print(dup.id)
                print("exists")
                return 0
        fields: list[tuple[str, object]] = [("title", a.title)] + ([("due", a.due)] if a.due else [])
        fields += [("status", "proposed" if a.proposed else "open"), ("created", today)]
        for key, value in (("project", a.project), ("source", a.source), ("from", a.sender),
                           ("from_domain", a.from_domain), ("link", a.link), ("reason", a.reason)):
            if value:
                fields.append((key, value))
        body = sys.stdin.read() if a.body_stdin else (a.note or "")
        path = unique_path(reminders_dir(root) / f"{slugify(a.title)}.md")
        write_atomic(path, render_entry(fields, body.strip() + "\n" if body.strip() else ""))
        print(f"reminders/{path.stem}")
        return 0
    if a.reminder_cmd == "list":
        rows = all_reminders(root)
        if a.status:
            rows = [r for r in rows if r.status == a.status]
        elif not a.all:
            rows = [r for r in rows if r.status in ("open", "proposed")]
        for r in sorted(rows, key=lambda r: (str(r.get("due") or "~"), r.title)):
            due = str(r.get("due") or "")
            late = " OVERDUE" if r.status == "open" and due and due < today else ""
            proj = f" [{r.get('project')}]" if r.get("project") else ""
            print(f"{due or 'no-date'} {r.status}{late} {r.id}{proj}: {r.title}")
        return 0
    r = find_reminder(root, a.id)
    if a.reminder_cmd == "due":
        if a.date == "none":
            r.fields = [(k, v) for k, v in r.fields if k != "due"]
        elif re.match(r"^\d{4}-\d{2}-\d{2}$", a.date):
            r.set("due", a.date)
        else:
            sys.exit("kb: due needs YYYY-MM-DD or none")
    else:
        r.set("status", {"done": "done", "dismiss": "dismissed", "accept": "open", "reopen": "open"}[a.reminder_cmd])
        if a.reminder_cmd == "done":
            r.set("done", today)
    r.save()
    print(f"{r.id}: {r.status}, due {r.get('due') or 'none'}")
    return 0


# ---------------------------------------------------------------- project docs
# Documentation files in a scope's repository that the user added in Architecture. Edits made in the app are
# drafts in the private folder (<private>/docs-drafts/<path>) until a Build session puts them in a pull request.

DOC_EXTENSIONS = (".md", ".markdown", ".mdx", ".adoc", ".rst", ".mmd", ".puml")
DOC_SKIP_DIRS = {".git", "node_modules", "build", ".build", "Pods", "Carthage", ".gradle", ".idea", "DerivedData",
                 "vendor", "dist", "out", "target", ".venv", "venv", "__pycache__", ".claude", TEAM_FOLDER}


def docs_checkout(root: Path, sid: str) -> Path:
    sc = scope_map(root).get(sid)
    if not sc:
        sys.exit(f"kb: no scope {sid}")
    checkout = scope_checkout(sc)
    if not checkout:
        sys.exit(f"kb: scope {sid} has no repository on this Mac")
    return checkout


def docs_state_path(root: Path, sid: str) -> Path:
    return private_dir(root, sid) / "docs.json"


def docs_drafts_dir(root: Path, sid: str) -> Path:
    return private_dir(root, sid) / "docs-drafts"


def load_docs_state(root: Path, sid: str) -> dict:
    try:
        data = json.loads(docs_state_path(root, sid).read_text())
    except (OSError, ValueError):
        data = {}
    data.setdefault("docs", [])
    data.setdefault("drafts", {})
    return data


def save_docs_state(root: Path, sid: str, data: dict) -> None:
    data["docs"] = sorted(set(data["docs"]))
    path = docs_state_path(root, sid)
    path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(path, json.dumps(data, indent=1, ensure_ascii=False) + "\n")


def doc_rel(path: str) -> str:
    """A repository-relative documentation path, refusing anything that leaves the repository."""
    raw = path.strip()
    while raw.startswith("./"):
        raw = raw[2:]
    p = Path(raw)
    if p.is_absolute() or ".." in p.parts or not p.parts:
        sys.exit(f"kb: {path}: give a path inside the repository, such as docs/architecture.md")
    if p.suffix.lower() not in DOC_EXTENSIONS:
        sys.exit(f"kb: {path}: not a documentation file ({', '.join(DOC_EXTENSIONS)})")
    if p.parts[0] in DOC_SKIP_DIRS:
        sys.exit(f"kb: {path}: {p.parts[0]}/ isn't project documentation")
    return p.as_posix()


def file_sha(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def doc_title(text: str, path: str) -> str:
    m = re.search(r"^#\s+(.+?)\s*#*\s*$", text, re.M)
    if m:
        return m.group(1).strip()
    return Path(path).stem.replace("-", " ").replace("_", " ").strip().capitalize() or path


def scan_docs(checkout: Path) -> list[str]:
    r = subprocess.run(["git", "-C", str(checkout), "ls-files", "--cached", "--others", "--exclude-standard"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        files = r.stdout.splitlines()
    else:
        files = [p.relative_to(checkout).as_posix() for p in checkout.rglob("*") if p.is_file()]
    out = []
    for f in files:
        parts = Path(f).parts
        if Path(f).suffix.lower() in DOC_EXTENSIONS and not any(x in DOC_SKIP_DIRS for x in parts[:-1]) \
                and (checkout / f).is_file():
            out.append(Path(f).as_posix())
    return sorted(set(out), key=lambda x: (x.count("/"), x.lower()))


def project_docs(root: Path, sid: str) -> list[dict]:
    """The added docs and any drafts, each with where to read it now and whether the repository moved on."""
    sc = scope_map(root).get(sid)
    checkout = scope_checkout(sc) if sc else None
    if not checkout:
        return []
    state = load_docs_state(root, sid)
    drafts = docs_drafts_dir(root, sid)
    out = []
    for path in sorted(set(state["docs"]) | set(state["drafts"])):
        repo_file = checkout / path
        draft = state["drafts"].get(path)
        current = file_sha(repo_file)
        read = drafts / path if draft is not None else repo_file
        try:
            text = read.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        out.append({"path": path, "title": doc_title(text, path), "file": str(read), "repo_file": str(repo_file),
                    "exists": current is not None,
                    "draft": None if draft is None else ("new" if draft.get("base") is None and current is None else "edited"),
                    "draft_file": str(drafts / path) if draft is not None else None,
                    "stale": draft is not None and draft.get("base") != current,
                    "modified": dt.datetime.fromtimestamp(read.stat().st_mtime).isoformat(timespec="minutes")
                    if read.exists() else ""})
    return out


def cmd_docs(a) -> int:
    root = kb_root()
    sid = a.project or current_project_id(root)
    checkout = docs_checkout(root, sid)
    state = load_docs_state(root, sid)
    drafts = docs_drafts_dir(root, sid)
    if a.action == "scan":
        added = set(state["docs"]) | set(state["drafts"])
        rows = []
        for path in scan_docs(checkout):
            try:
                text = (checkout / path).read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            rows.append({"path": path, "title": doc_title(text, path), "size": len(text), "added": path in added})
        if a.json:
            print(json.dumps({"checkout": str(checkout), "docs": rows}, indent=1, ensure_ascii=False))
        else:
            for r in rows:
                print(f"{'*' if r['added'] else ' '} {r['path']}\t{r['title']}")
        return 0
    if a.action == "list":
        docs = project_docs(root, sid)
        if a.json:
            print(json.dumps({"checkout": str(checkout), "docs": docs}, indent=1, ensure_ascii=False))
        else:
            for d in docs:
                flag = {"new": " [new, not in the repository]", "edited": " [edited, not in the repository]"}.get(d["draft"] or "", "")
                print(f"{d['path']}\t{d['title']}{flag}{' [the repository changed since]' if d['stale'] else ''}")
        return 0
    if a.action == "add":
        paths = [doc_rel(p) for p in a.paths]
        missing = [p for p in paths if not (checkout / p).is_file()]
        if missing:
            sys.exit(f"kb: not in {checkout}: {', '.join(missing)}")
        state["docs"] += paths
        save_docs_state(root, sid, state)
        print(f"{len(paths)} added")
        return 0
    path = doc_rel(a.path) if getattr(a, "path", None) else None
    if a.action == "show":
        f = drafts / path if path in state["drafts"] else checkout / path
        if not f.is_file():
            sys.exit(f"kb: no {path}")
        sys.stdout.write(f.read_text(encoding="utf-8", errors="replace"))
        return 0
    if a.action == "draft":
        text = sys.stdin.read()
        if path not in state["drafts"]:
            state["drafts"][path] = {"base": file_sha(checkout / path)}
        state["drafts"][path]["saved"] = dt.datetime.now().isoformat(timespec="seconds")
        if (checkout / path).is_file() and (checkout / path).read_text(encoding="utf-8", errors="replace") == text:
            state["drafts"].pop(path)
            (drafts / path).unlink(missing_ok=True)
        else:
            (drafts / path).parent.mkdir(parents=True, exist_ok=True)
            write_atomic(drafts / path, text)
        state["docs"].append(path)
        save_docs_state(root, sid, state)
        print(path)
        return 0
    if a.action == "diff":
        names = [path] if path else sorted(state["drafts"])
        for p in names:
            if p not in state["drafts"]:
                continue
            old = (checkout / p).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True) \
                if (checkout / p).is_file() else []
            new = (drafts / p).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
            sys.stdout.writelines(difflib.unified_diff(old, new, f"a/{p}", f"b/{p}"))
        return 0
    if a.action in ("discard", "saved", "remove"):
        for p in [doc_rel(x) for x in a.paths]:
            state["drafts"].pop(p, None)
            (drafts / p).unlink(missing_ok=True)
            if a.action == "remove" or (a.action == "discard" and not (checkout / p).is_file()):
                state["docs"] = [d for d in state["docs"] if d != p]
        save_docs_state(root, sid, state)
        print({"discard": "discarded", "saved": "drafts cleared", "remove": "removed from the list"}[a.action])
        return 0
    return 1


# ---------------------------------------------------------------- goals


GOAL_STATUSES = ("active", "paused", "achieved", "dropped")
GOAL_TEMPLATE = "## Why\n{why}\n\n## What it takes\n\n## Suggestions\n\n## Progress\n"


def goals_dir(root: Path) -> Path:
    return home(root) / "goals"


def all_goals(root: Path) -> list[Entry]:
    d = goals_dir(root)
    out = []
    for path in sorted(d.glob("*.md")) if d.is_dir() else []:
        try:
            fields, body = split_frontmatter(path.read_text(encoding="utf-8"))
        except OSError:
            continue
        out.append(Entry(f"goals/{path.stem}", "", "goals", path, fields, body))
    return out


def find_goal(root: Path, gid: str) -> Entry:
    stem = gid.strip().removesuffix(".md").split("/")[-1]
    g = next((g for g in all_goals(root) if g.path.stem == stem), None)
    if not g:
        sys.exit(f"kb: no goal {gid}")
    return g


def add_section_line(body: str, name: str, line: str, before: str | None = None) -> str:
    """Adds a line at the top of `## name`, creating the section (ahead of `## before` when given)."""
    m = re.search(rf"^## {re.escape(name)}[ \t]*\n", body, re.M)
    if m:
        return body[:m.end()] + line + "\n" + body[m.end():]
    b = re.search(rf"^## {re.escape(before)}[ \t]*$", body, re.M) if before else None
    if b:
        return body[:b.start()] + f"## {name}\n{line}\n\n" + body[b.start():]
    return body.rstrip("\n") + f"\n\n## {name}\n{line}\n"


def add_progress(body: str, line: str) -> str:
    m = re.search(r"^## Progress[ \t]*\n", body, re.M)
    if not m:
        return body.rstrip("\n") + f"\n\n## Progress\n{line}\n"
    return body[:m.end()] + line + "\n" + body[m.end():]


# ---------------------------------------------------------------- people


def people_cache_path() -> Path:
    """The directory of colleagues fetched from Azure DevOps: a cache on this machine, outside the KB."""
    if os.environ.get("KB_PEOPLE_CACHE"):
        return Path(os.environ["KB_PEOPLE_CACHE"])
    if WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA") or Path("~/AppData/Local").expanduser()) / "Mindmill" / "cache"
    else:
        base = Path("~/Library/Caches/KB") if sys.platform == "darwin" else Path("~/.cache/kb")
    return base.expanduser() / "people-directory.json"


def people_registry_path(root: Path) -> Path:
    return home(root) / "people.json"


def initials_for(name: str, email: str = "") -> str:
    """Mail addresses that are initials (`abc@`) give those; otherwise the first letters of the first and last name."""
    local = email.split("@")[0].lower() if email else ""
    if re.fullmatch(r"[a-z]{2,5}", local):
        return local.upper()
    words = [w for w in re.split(r"[\s\-]+", name.strip()) if w and w[0].isalpha()]
    if not words:
        return ""
    return (words[0][0] + (words[-1][0] if len(words) > 1 else "")).upper()


def read_people_registry(root: Path) -> list[dict]:
    try:
        data = json.loads(people_registry_path(root).read_text())
    except (OSError, ValueError):
        return []
    return [p for p in data.get("people", []) if isinstance(p, dict) and p.get("name")]


def write_people_registry(root: Path, people: list[dict]) -> None:
    people = sorted(people, key=lambda p: p["name"].lower())
    write_atomic(people_registry_path(root), json.dumps({"people": people}, indent=2, ensure_ascii=False) + "\n")


def people_directory() -> list[dict]:
    try:
        return json.loads(people_cache_path().read_text()).get("people", [])
    except (OSError, ValueError):
        return []


def all_people(root: Path) -> list[dict]:
    """The KB's own people first (chosen before, or added by name), then the directory, one row per person."""
    out: list[dict] = []
    seen: set[str] = set()
    own = read_people_registry(root)
    for i, p in enumerate(own + people_directory()):
        key = (p.get("email") or p["name"]).lower()
        if key in seen or p["name"].lower() in seen:
            continue
        seen.add(key)
        seen.add(p["name"].lower())
        out.append({"name": p["name"], "initials": p.get("initials") or initials_for(p["name"], p.get("email", "")),
                    "email": p.get("email", ""), "source": p.get("source", "ado"), "known": i < len(own)})
    return out


def search_people(people: list[dict], query: str, limit: int = 10) -> list[dict]:
    q = query.strip().lower()
    if not q:
        return people[:limit]
    scored = []
    for p in people:
        name, ini, mail = p["name"].lower(), p["initials"].lower(), p.get("email", "").lower()
        words = re.split(r"[\s\-]+", name)
        if ini == q:
            score = 0
        elif name.startswith(q):
            score = 1
        elif any(w.startswith(q) for w in words):
            score = 2
        elif ini.startswith(q) or mail.startswith(q):
            score = 3
        elif q in name:
            score = 4
        else:
            continue
        scored.append((score, 0 if p.get("known") else 1, name, p))
    return [x[3] for x in sorted(scored, key=lambda x: x[:3])[:limit]]


def people_sync(root: Path) -> int:
    """Every member of every team in the Azure DevOps organisations the KB's trackers use."""
    from concurrent.futures import ThreadPoolExecutor
    pat = ado_pat()
    orgs = sorted({(load_settings(root, sc["id"]).get("tracker") or {}).get("organization") for sc in load_registry(root)} - {None, ""})
    found: dict[str, dict] = {}
    for org in orgs:
        def get(url):
            try:
                return ado_request("GET", url, pat)
            except urllib.error.HTTPError:
                return {}
        projects = get(f"https://dev.azure.com/{org}/_apis/projects?api-version=7.1&$top=500").get("value", [])
        with ThreadPoolExecutor(8) as ex:
            teams = [(p["id"], t["id"]) for res, p in zip(ex.map(lambda p: get(
                f"https://dev.azure.com/{org}/_apis/projects/{p['id']}/teams?api-version=7.1&$top=300"), projects), projects)
                for t in res.get("value", [])]
            lists = ex.map(lambda pt: get(f"https://dev.azure.com/{org}/_apis/projects/{pt[0]}/teams/{pt[1]}/members"
                                          "?api-version=7.1&$top=1000"), teams)
            for res in lists:
                for m in res.get("value", []):
                    i = m.get("identity") or {}
                    mail = i.get("uniqueName", "")
                    if i.get("isContainer") or "@" not in mail or not i.get("displayName"):
                        continue
                    found.setdefault(mail.lower(), {"name": i["displayName"], "email": mail,
                                                    "initials": initials_for(i["displayName"], mail)})
    path = people_cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(path, json.dumps({"fetched": iso_now(), "people": sorted(found.values(), key=lambda p: p["name"].lower())},
                                  indent=1, ensure_ascii=False) + "\n")
    return len(found)


def cmd_people(a) -> int:
    root = kb_root()
    if a.people_cmd == "sync":
        try:
            n = people_sync(root)
        except urllib.error.URLError as e:
            sys.exit(f"kb: could not reach Azure DevOps: {getattr(e, 'reason', e)}")
        print(f"{n} people")
        return 0
    if a.people_cmd == "add":
        name = one_line(a.name)
        if not name:
            sys.exit("kb: --name is empty")
        people = [p for p in read_people_registry(root) if p["name"].lower() != name.lower()]
        known = next((p for p in people_directory() if p["name"].lower() == name.lower()
                      or (a.email and p.get("email", "").lower() == a.email.lower())), None)
        email = a.email or (known or {}).get("email", "")
        entry = {"name": name, "initials": a.initials or initials_for(name, email), "source": "ado" if known else "manual"}
        if email:
            entry["email"] = email
        write_people_registry(root, people + [entry])
        print(f"{entry['name']}\t{entry['initials']}")
        return 0
    people = all_people(root)
    rows = search_people(people, a.query, a.limit) if a.people_cmd == "search" else people
    if a.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        for p in rows:
            print(f"{p['initials']}\t{p['name']}\t{p.get('email', '')}".rstrip())
    return 0


def cmd_goal(a) -> int:
    root = kb_root()
    today = dt.date.today().isoformat()
    if a.goal_cmd == "add":
        why = sys.stdin.read().strip() if a.why_stdin else (a.why or "")
        fields: list[tuple[str, object]] = [("title", a.title), ("status", "active"), ("created", today)]
        if a.horizon:
            fields.append(("horizon", a.horizon))
        path = unique_path(goals_dir(root) / f"{slugify(a.title)}.md")
        write_atomic(path, render_entry(fields, GOAL_TEMPLATE.format(why=why)))
        print(f"goals/{path.stem}")
        return 0
    if a.goal_cmd == "list":
        for g in all_goals(root):
            if a.all or g.status == "active":
                open_ = len(re.findall(r"^- \[ \]", body_section(g.body, "Suggestions"), re.M))
                proposed = len(re.findall(r"^[-*] ", body_section(g.body, "Proposed progress"), re.M))
                print(f"{g.id} [{g.status}] {g.title}" + (f" ({g.get('horizon')})" if g.get("horizon") else "")
                      + f": {open_} open suggestions, {proposed} proposed progress, last looked for progress "
                      + (g.get("progress_scanned") or "never"))
        return 0
    g = find_goal(root, a.id)
    if a.goal_cmd == "show":
        print(g.path.read_text(encoding="utf-8"))
        return 0
    if a.goal_cmd == "log":
        g.body = add_progress(g.body, f"- {a.date or today}: {a.text.strip()}")
    elif a.goal_cmd in ("propose", "scanned"):
        if a.goal_cmd == "propose":
            text = " ".join(a.text.split())
            known = {t.lower() for t in re.findall(r"^[-*] (?:\d{4}-\d{2}-\d{2}: ?)?(.+)$",
                                                     body_section(g.body, "Progress") + "\n"
                                                     + body_section(g.body, "Proposed progress"), re.M)}
            if text.lower() in known:
                print(f"{g.id}: already there")
                return 0
            g.body = add_section_line(g.body, "Proposed progress", f"- {a.date or today}: {text}", before="Progress")
        g.set("progress_scanned", today)
    elif a.goal_cmd == "status":
        g.set("status", a.status)
    g.save()
    print(f"{g.id}: {g.status}")
    return 0


# ---------------------------------------------------------------- email


EMAIL_IGNORE = ["medium.com", "postman.com", "getpostman.com", "linkedin.com", "substack.com", "mailchimp",
                "newsletter", "marketing", "noreply@github.com"]


def email_state_path(root: Path) -> Path:
    return home(root) / "email.json"


def load_email_state(root: Path) -> dict:
    try:
        data = json.loads(email_state_path(root).read_text())
    except (OSError, ValueError):
        data = {}
    data.setdefault("ignore", list(EMAIL_IGNORE))
    data.setdefault("last_scan", "")
    return data


def cmd_email(a) -> int:
    root = kb_root()
    state = load_email_state(root)
    if a.email_cmd == "state":
        since = state["last_scan"] or (dt.datetime.now() - dt.timedelta(days=3)).strftime("%Y-%m-%dT%H:%M")
        print(json.dumps({"since": since, "last_scan": state["last_scan"], "ignore": state["ignore"],
                          "reminder_sources": sorted(str(r.get("source")) for r in all_reminders(root)
                                                     if str(r.get("source")).startswith("email:"))}, indent=1))
        return 0
    if a.email_cmd == "scanned":
        state["last_scan"] = a.at or dt.datetime.now().strftime("%Y-%m-%dT%H:%M")
    elif a.email_cmd == "ignore":
        word = a.sender.strip().lower()
        if "@" in word and not word.startswith("noreply"):
            word = word.split("@", 1)[1]
        if word and word not in state["ignore"]:
            state["ignore"].append(word)
    write_atomic(email_state_path(root), json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: state[k] for k in ("last_scan", "ignore")}))
    return 0


# ---------------------------------------------------------------- calendar


def calendar_settings(root: Path) -> dict:
    try:
        data = json.loads((root / "calendar.json").read_text())
    except (OSError, ValueError):
        data = {}
    projects = load_registry(root)
    ids = [p["id"] for p in projects]
    shared = next((p["id"] for p in projects if not p.get("paths")), ids[0] if ids else "")
    if data.get("default_project") not in ids:
        data["default_project"] = shared
    data.setdefault("ignore", ["lunch", "frokost", "focus", "fokus", "out of office"])
    return data


def series_key(title: str) -> str:
    """A meeting title without numbers and punctuation, so "Sprint 24 retro" and "Sprint 25 retro" match."""
    s = re.sub(r"[^a-zæøåäöü]+", " ", title.lower())
    return " ".join(s.split())


def meeting_has_content(e: Entry) -> bool:
    for heading in ("Materials", "Suggested questions", "Questions", "Raw notes", "Summary"):
        if body_section(e.body, heading).strip():
            return True
    return False


def clock(value: str) -> str:
    m = re.search(r"T?(\d{1,2}):(\d{2})", value or "")
    return f"{int(m.group(1)):02d}:{m.group(2)}" if m else ""


def day(value: str) -> str:
    m = re.match(r"(\d{4}-\d{2}-\d{2})", value or "")
    return m.group(1) if m else ""


def normalize_event(ev: dict) -> dict:
    """Accepts our own event shape or the Outlook connector's raw one (subject, start.dateTime, namedAttendees…)."""
    def when(v):
        return str(v.get("dateTime", "")) if isinstance(v, dict) else str(v or "")
    text = str(ev.get("body") or ev.get("summary") or ev.get("bodyPreview") or "")
    url = ev.get("online_url") or ev.get("onlineMeetingUrl") or ""
    if not url:
        m = re.search(r"https://teams\.microsoft\.com/\S+", text)
        url = m.group(0) if m else ""
    text = re.split(r"\n\s*_{5,}|^_{5,}", text.replace("\r", ""), maxsplit=1, flags=re.M)[0]
    named = ev.get("namedAttendees")
    if isinstance(named, list) and named:
        people = [str(n.get("name") or "") for n in named
                  if not re.search(r"meetingroom|room\d", str(n.get("address", "")), re.I)
                  and not re.search(r"\d", str(n.get("name") or ""))]
    else:
        people = [str(x) for x in ev.get("attendees") or [] if "@" not in str(x) and not re.search(r"\d", str(x))]
    response = ev.get("response") or ev.get("responseStatus") or ""
    if isinstance(response, dict):
        response = response.get("response", "")
    return {
        "id": str(ev.get("id") or "").strip(),
        "title": str(ev.get("title") or ev.get("subject") or "").strip(),
        "start": when(ev.get("start")), "end": when(ev.get("end")),
        "attendees": [x.strip() for x in people if x.strip()],
        "organizer": str(ev.get("organizerName") or ("" if "@" in str(ev.get("organizer") or "") else ev.get("organizer") or "")),
        "location": str(ev.get("location") or ""),
        "online_url": str(url).rstrip(">)\"'"),
        "calendar_url": str(ev.get("calendar_url") or ev.get("webLink") or ""),
        "body": text.strip(),
        "series": str(ev.get("series") or ev.get("seriesMasterId") or ""),
        "all_day": bool(ev.get("all_day") or ev.get("isAllDay")),
        "cancelled": bool(ev.get("cancelled") or ev.get("isCancelled")),
        "response": str(response).lower(),
    }


def route_meeting(root: Path, ev: dict, earlier: Entry | None, cal: dict) -> tuple[str, bool]:
    if earlier:
        return earlier.project, False
    hay = " ".join([str(ev.get("title", "")), str(ev.get("body", "")), str(ev.get("organizer", "")),
                    " ".join(ev.get("attendees") or [])]).lower()
    for p in load_registry(root):
        hints = (load_settings(root, p["id"]).get("conventions") or {}).get("meeting_hints") or []
        if any(str(h).lower() in hay for h in hints if str(h).strip()):
            return p["id"], False
    return cal["default_project"], True


def cmd_calendar(a) -> int:
    root = kb_root()
    try:
        data = json.load(sys.stdin)
    except ValueError as err:
        sys.exit(f"kb: calendar import needs JSON on stdin: {err}")
    events = data.get("events", []) if isinstance(data, dict) else data
    start = a.date_from or (data.get("from") if isinstance(data, dict) else None) or dt.date.today().isoformat()
    end = a.date_to or (data.get("to") if isinstance(data, dict) else None) or start
    today = dt.date.today().isoformat()
    lock = open(root / ".calendar.lock", "w")
    lock_exclusive(lock)
    cal = calendar_settings(root)
    ignore = [str(w).lower() for w in cal["ignore"] if str(w).strip()]
    meetings = [e for e in all_entries(root) if e.section == "meetings"]
    by_cal = {str(e.get("calendar_id")): e for e in meetings if e.get("calendar_id")}
    counts = {"new": 0, "updated": 0, "cancelled": 0, "pruned": 0, "skipped": 0}
    log: list[str] = []
    seen: set[str] = set()

    def same_series(ev: dict, date: str) -> list[Entry]:
        series, key = ev["series"], series_key(ev["title"])
        return by_date_desc([m for m in meetings if m.date < date
                             and ((series and str(m.get("calendar_series")) == series)
                                  or (key and series_key(str(m.get("calendar_title") or m.title)) == key))])

    events = [normalize_event(ev) for ev in events if isinstance(ev, dict)]
    for ev in events:
        cid = str(ev.get("id") or "").strip()
        title = str(ev.get("title") or "").strip()
        date = day(str(ev.get("start", "")))
        if not cid or not title or not date:
            counts["skipped"] += 1
            continue
        seen.add(cid)
        declined = ev["response"] == "declined"
        cancelled = bool(ev.get("cancelled")) or declined
        existing = by_cal.get(cid)
        if not existing and (date < today or ev.get("all_day") or cancelled
                             or any(w in title.lower() for w in ignore)):
            counts["skipped"] += 1
            continue
        attendees = [str(x).strip() for x in (ev.get("attendees") or []) if str(x).strip()]
        wanted = [("date", date), ("start", clock(str(ev.get("start", "")))), ("end", clock(str(ev.get("end", "")))),
                  ("attendees", attendees), ("organizer", str(ev.get("organizer") or "")),
                  ("location", str(ev.get("location") or "")), ("online_url", str(ev.get("online_url") or "")),
                  ("calendar_series", ev["series"]), ("calendar_url", ev["calendar_url"])]
        if existing:
            e = existing
            before = render_entry(e.fields, e.body)
            if e.get("title") == e.get("calendar_title") or not e.get("calendar_title"):
                e.set("title", title)
            e.set("calendar_title", title)
            for k, v in wanted:
                if v not in ("", []) or e.get(k):
                    e.set(k, v)
            if cancelled and e.status in ("scheduled", "prepared") and not body_section(e.body, "Raw notes").strip():
                e.set("status", "cancelled")
            elif not cancelled and e.status == "cancelled":
                e.set("status", "prepared" if meeting_has_content(e) else "scheduled")
            e.fields = [(k, v) for k, v in e.fields if v not in ("", [], None)]
            if render_entry(e.fields, e.body) != before:
                e.save()
                kind = "cancelled" if e.status == "cancelled" and "status: cancelled" not in before else "updated"
                counts[kind] += 1
                log.append(f"{kind} {e.id}")
            continue
        series = same_series(ev, date)
        earlier = next((m for m in series if m.status not in ("scheduled", "cancelled")), None)
        placed = next((m for m in series if not m.get("project_guessed")), None)
        pid, guessed = route_meeting(root, ev, placed, cal)
        fields: list[tuple[str, object]] = [("title", title), ("date", date), ("status", "scheduled")]
        fields += [(k, v) for k, v in wanted if v not in ("", []) and k != "date"]
        fields += [("calendar_id", cid), ("calendar_title", title)]
        if earlier:
            fields.append(("previous", earlier.id))
        if guessed:
            fields.append(("project_guessed", "true"))
        invite = re.sub(r"\s+", " ", str(ev.get("body") or "")).strip()
        body = (f"## Prep\n- **Invite:** {invite[:400]}\n\n" if invite else "") + TEMPLATES["meetings"]
        path = entry_path(root, pid, "meetings", title, date)
        write_atomic(path, render_entry(fields, body))
        new = read_entry(root, path)
        if new:
            meetings.append(new)
            by_cal[cid] = new
        counts["new"] += 1
        log.append(f"new {pid}/meetings/{path.stem}" + (" (project guessed)" if guessed else ""))

    for cid, e in list(by_cal.items()) if events else []:
        if cid in seen or not (start <= e.date <= end) or e.status != "scheduled":
            continue
        e.set("status", "cancelled")
        e.save()
        counts["cancelled"] += 1
        log.append(f"cancelled {e.id} (no longer in the calendar)")

    for e in [m for m in all_entries(root) if m.section == "meetings"]:
        if e.date < today and e.status in ("scheduled", "cancelled") and e.get("calendar_id") \
                and not meeting_has_content(e):
            delete_entry(root, e)
            counts["pruned"] += 1
            log.append(f"pruned {e.id} (past, never prepared or held)")

    print("calendar: " + ", ".join(f"{n} {k}" for k, n in counts.items()))
    for line in log:
        print(f"  {line}")
    return 0


def cmd_lint(a) -> int:
    root = kb_root()
    problems = []
    entries = all_entries(root)
    ids = {e.id for e in entries}
    scopes = scope_map(root)
    registry = set(scopes)
    data = read_registry_file(root)
    if is_nested(data):
        for proj in load_projects(root):
            wide = [sid for sid in proj["scopes"] if scopes[sid].get("wide")]
            if len(wide) != 1:
                problems.append(f"kb.json: project {proj['id']} needs exactly one project-wide scope (\"wide\": true), "
                                f"has {len(wide)}")
    for d in (root / "projects").iterdir() if (root / "projects").is_dir() and not is_split(root) else []:
        if d.is_dir() and d.name not in registry:
            problems.append(f"projects/{d.name}: folder not in kb.json")
    for e in entries:
        section = str(e.get("proposed_section")) if e.section == "inbox" else e.section
        if not e.get("title"):
            problems.append(f"{e.id}: missing title")
        if section in DATED_SECTIONS and not re.match(r"^\d{4}-\d{2}-\d{2}$", e.date):
            problems.append(f"{e.id}: missing or malformed date")
        if e.section == "inbox" and section not in APPROVABLE:
            problems.append(f"{e.id}: proposed_section {section!r} is not approvable")
        status = str(e.get("status") or "")
        if section in STATUSES and status and status not in STATUSES[section]:
            problems.append(f"{e.id}: unknown status {status!r}")
        if e.section == "decisions":
            if e.status == "superseded" and e.get("superseded_by") not in ids:
                problems.append(f"{e.id}: superseded_by points nowhere ({e.get('superseded_by')!r})")
        if section == "decisions":
            for s in e.get("supersedes") or []:
                if s not in ids:
                    problems.append(f"{e.id}: supersedes unknown {s}")
        if e.get("updates") and e.get("updates") not in ids:
            problems.append(f"{e.id}: updates unknown fact {e.get('updates')}")
        for sid in entry_scopes(e)[1:]:
            if sid not in scopes:
                problems.append(f"{e.id}: unknown scope {sid}")
            elif e.project in scopes and scopes[sid]["project"] != scopes[e.project]["project"]:
                problems.append(f"{e.id}: scope {sid} is in another project")
        if e.get("previous") and e.get("previous") not in ids:
            problems.append(f"{e.id}: previous unknown {e.get('previous')}")
        sources = e.get("source") or []
        for src in sources if isinstance(sources, list) else [sources]:
            if src and "://" not in src and not src.startswith(("ado:", "session:", "daily:")) and src not in ids:
                problems.append(f"{e.id}: source unknown {src}")
    problems += name_problems(root)
    for team in team_folders_without_gitattributes(root):
        print(f"note: {team} has no .gitattributes; add one with `{TEAM_GITATTRIBUTES.strip()}` so Windows "
              "checkouts don't write CRLF into shared entries", file=sys.stderr)
    for p in problems:
        print(p)
    if not problems:
        print("ok")
    return 1 if problems else 0


def name_problems(root: Path) -> list[str]:
    """Every folder the KB reads, checked for names that would break a Windows checkout or copy."""
    if not is_split(root):
        return portability_problems(root, ".")
    out = portability_problems(home(root), "shared")
    for sid in scope_map(root):
        out += portability_problems(private_dir(root, sid), sid)
        team = team_dir(root, sid)
        if team:
            out += portability_problems(team, f"{sid} (team)")
    return out


def team_folders_without_gitattributes(root: Path) -> list[str]:
    if not is_split(root):
        return []
    seen = []
    for sid in scope_map(root):
        team = team_dir(root, sid)
        if team and team.is_dir() and not (team / ".gitattributes").exists() and str(team) not in seen:
            seen.append(str(team))
    return seen


def split_ids(raw: str | None) -> list[str]:
    return [x.strip() for x in (raw or "").split(",") if x.strip()]


def cmd_scopes(a) -> int:
    """Print an entry's scopes, or change them."""
    root = kb_root()
    e = find_entry(root, a.id)
    if not e:
        sys.exit(f"kb: no entry {a.id}")
    current = entry_scopes(e)
    if a.set is None and not a.add and not a.remove:
        print("\n".join(current))
        return 0
    if a.set is not None:
        new = split_ids(a.set)  # the folder scope is always kept
    elif a.add:
        new = current + split_ids(a.add)
    else:
        gone = set(split_ids(a.remove))
        if e.project in gone:
            sys.exit(f"kb: {a.id} lives in {e.project}; move it with `kb move --project <scope>` instead")
        new = [x for x in current if x not in gone]
    scopes = check_scopes(root, e.project, new)
    e.fields = [(k, v) for k, v in e.fields if k != "scopes"] + scopes_field(scopes)
    e.save()
    print("\n".join(scopes))
    return 0


def normalize_tag(raw: str) -> str:
    return " ".join(raw.strip().lstrip("#").lower().split())


def normalize_tags(tags) -> list[str]:
    """Lower-case, single-spaced, without empties or repeats, in their first order."""
    if isinstance(tags, str):
        tags = [tags]
    out: list[str] = []
    for t in tags or []:
        n = normalize_tag(str(t))
        if n and n not in out:
            out.append(n)
    return out


def entry_tags(e: "Entry", key: str = "tags") -> list[str]:
    return normalize_tags(e.get(key) or [])


def item_tags_path(root: Path) -> Path:
    """KB's own tags on tracker items, by `<kind>:<id>`. They never reach the tracker unless aligned."""
    return home(root) / "item-tags.json"


def load_item_tags(root: Path) -> dict:
    try:
        data = json.loads(item_tags_path(root).read_text())
    except (OSError, ValueError):
        data = {}
    return {"version": 1, "items": data.get("items") or {}, "aligned_tags": data.get("aligned_tags") or []}


def save_item_tags(root: Path, data: dict) -> None:
    write_atomic(item_tags_path(root), json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def tracker_tag_additions(local, aligned, tool) -> list[str]:
    """The only tags KB may write to a tracker item: local tags the user aligned that the item doesn't have yet."""
    allowed, present = set(normalize_tags(aligned)), set(normalize_tags(tool))
    return [t for t in normalize_tags(local) if t in allowed and t not in present]


def item_tag_additions(store: dict, key: str, tool) -> list[str]:
    item = store["items"].get(key) or {}
    return tracker_tag_additions(item.get("tags") or [], [*(item.get("aligned") or []), *store["aligned_tags"]], tool)


def tag_vocabulary(root: Path, scope: str | None = None) -> list[tuple[str, int]]:
    counts: dict[str, int] = {}
    for e in all_entries(root):
        if scope and scope not in entry_scopes(e):
            continue
        for t in entry_tags(e):
            counts[t] = counts.get(t, 0) + 1
    if not scope:
        for item in load_item_tags(root)["items"].values():
            for t in normalize_tags(item.get("tags") or []):
                counts[t] = counts.get(t, 0) + 1
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))


def cmd_tags(a) -> int:
    """Without an id, every tag in use with its count; with one, the entry's tags, or change them.
    The user's removals are kept in `tags_off`; `--auto` (the background tagger) only adds, and never what is there."""
    root = kb_root()
    if not a.id:
        vocab = tag_vocabulary(root, a.project)
        if a.json:
            print(json.dumps([{"tag": t, "count": n} for t, n in vocab], ensure_ascii=False))
        else:
            print("\n".join(f"{t}\t{n}" for t, n in vocab))
        return 0
    e = find_entry(root, a.id)
    if not e:
        sys.exit(f"kb: no entry {a.id}")
    tags, off = entry_tags(e), entry_tags(e, "tags_off")
    if a.set is None and not a.add and not a.remove:
        print("\n".join(tags))
        return 0
    if a.auto:
        if a.set is not None or a.remove:
            sys.exit("kb: --auto only adds tags")
        new = tags + [t for t in normalize_tags(split_ids(a.add)) if t not in tags and t not in off]
    else:
        if a.set is not None:
            new = normalize_tags(split_ids(a.set))
        elif a.add:
            new = tags + [t for t in normalize_tags(split_ids(a.add)) if t not in tags]
        else:
            gone = set(normalize_tags(split_ids(a.remove)))
            new = [t for t in tags if t not in gone]
        off = normalize_tags([t for t in off if t not in new] + sorted(set(tags) - set(new)))
    if new != tags or off != entry_tags(e, "tags_off"):
        e.set("tags", new)
        e.set("tags_off", off)
        e.save()
    print("\n".join(new))
    return 0


def to_nested(root: Path) -> None:
    """Turns a v1 kb.json into v2: each v1 project becomes a project with one project-wide scope."""
    data = read_registry_file(root) or {"version": 1, "projects": []}
    if is_nested(data):
        return
    projects = []
    for p in data.get("projects", []):
        if p.get("id"):
            projects.append({"id": p["id"], "title": p.get("title") or p["id"], "scopes": [{**p, "wide": True}]})
    data["version"] = 2
    data["projects"] = projects
    write_atomic(home(root) / "kb.json", json.dumps(data, indent=2, ensure_ascii=False) + "\n")


HOME_FILES = ("kb.json", "people.json", "sources.json", "email.json", "README.md")
HOME_DIRS = ("daily", "reminders", "goals")


def layout_plan(root: Path, dest: Path) -> list[tuple[Path, Path]]:
    """Copies from a legacy KB at `root` to the split layout at `dest`: the files spanning projects into
    `shared/`, each scope's team sections into its repo's `knowledgebase/`, the rest into `<dest>/<scope>/`."""
    plan: list[tuple[Path, Path]] = []
    for name in HOME_FILES:
        if (root / name).is_file():
            plan.append((root / name, dest / "shared" / name))
    for name in HOME_DIRS:
        if (root / name).is_dir():
            plan += [(f, dest / "shared" / f.relative_to(root)) for f in sorted((root / name).rglob("*")) if f.is_file()]
    for sc in load_registry(root):
        src = root / "projects" / sc["id"]
        if not src.is_dir():
            continue
        checkout = scope_checkout(sc)
        for f in sorted(src.rglob("*")):
            if not f.is_file() or f.name.startswith("."):
                continue
            rel = f.relative_to(src)
            section = "overview" if rel == Path("overview.md") else rel.parts[0]
            team = checkout is not None and section in TEAM_SECTIONS and f.suffix == ".md"
            plan.append((f, (checkout / TEAM_FOLDER / rel) if team else dest / sc["id"] / rel))
    return plan


def cmd_layout(a) -> int:
    root = kb_root()
    if a.action == "show":
        print(f"root: {root}\nlayout: {'split' if is_split(root) else 'legacy (one folder)'}")
        if is_split(root):
            print(f"shared: {home(root)}")
            for sc in load_registry(root):
                team = team_dir(root, sc["id"])
                print(f"{sc['id']}: private {private_dir(root, sc['id'])}" + (f", team {team}" if team else ""))
        return 0
    if is_split(root):
        sys.exit(f"kb: {root} already uses the split layout")
    dest = Path(os.path.expanduser(a.to)).resolve()
    if dest == root or root in dest.parents:
        sys.exit("kb: --to must be a new folder outside the current KB")
    plan = layout_plan(root, dest)
    clash = [d for _, d in plan if d.exists()]
    by_place: dict[str, int] = {}
    for _, d in plan:
        if d.is_relative_to(dest):
            place = str(dest / d.relative_to(dest).parts[0]) + "/  (private)"
        else:
            place = str(Path(*d.parts[:d.parts.index(TEAM_FOLDER) + 1])) + "/  (team, in the repo)"
        by_place[place] = by_place.get(place, 0) + 1
    print(f"Copy {len(plan)} files from {root}:")
    for place, n in sorted(by_place.items()):
        print(f"  {n:4}  {place}")
    if clash:
        print(f"{len(clash)} already exist and are left as they are, e.g. {clash[0]}")
    if not a.yes:
        print("Nothing copied. Run again with --yes to copy; the old folder stays as it is.")
        return 0
    copied = 0
    for src, d in plan:
        if d.exists():
            continue
        d.parent.mkdir(parents=True, exist_ok=True)
        d.write_bytes(src.read_bytes())
        copied += 1
    registry = dest / "shared" / "kb.json"
    data = json.loads(registry.read_text())
    for proj in data.get("projects", []):
        for sc in proj.get("scopes") or []:
            if sc.get("wide") and sc.get("title") in ("Product-wide", "Project-wide", proj.get("title")):
                sc["title"] = "Overview"
    write_atomic(registry, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    cfg = load_config()
    cfg["root"] = str(dest)
    write_atomic(CONFIG_PATH, json.dumps(cfg, indent=2) + "\n")
    print(f"Copied {copied} files. KB now uses {dest}; {root} is untouched and can go once you've checked.")
    return 0


def make_scope_folder(root: Path, sid: str) -> None:
    """Legacy layout only: the split one makes folders when the first entry is written, so repos get no empty ones."""
    if is_split(root):
        return
    for sec in SECTIONS:
        (root / "projects" / sid / sec).mkdir(parents=True, exist_ok=True)


def cmd_project(a) -> int:
    root = kb_root()
    if a.action == "list":
        for p in load_projects(root):
            print(f"{p['id']}\t{p['title']}\t{','.join(p['scopes'])}")
        return 0
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", a.id):
        sys.exit("kb: project ids are lowercase kebab-case")
    to_nested(root)
    data = read_registry_file(root)
    if any(p.get("id") == a.id for p in data["projects"]):
        sys.exit(f"kb: project {a.id} exists")
    wide = a.wide_scope or a.id
    if wide in scope_map(root):
        sys.exit(f"kb: scope {wide} exists; pass --wide-scope with a new id")
    data["projects"].append({"id": a.id, "title": a.title, "scopes": [
        {"id": wide, "title": a.wide_title, "wide": True, "paths": [], "remotes": [], "related": []}]})
    write_atomic(home(root) / "kb.json", json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    make_scope_folder(root, wide)
    print(f"project {a.id} with project-wide scope {wide}")
    return 0


def cmd_scope(a) -> int:
    root = kb_root()
    scopes = load_registry(root)
    if a.action == "list":
        for sc in scopes:
            print(f"{sc['project']}\t{sc['id']}\t{sc.get('title', sc['id'])}\t{'wide' if sc.get('wide') else ''}\t"
                  f"{','.join(sc.get('paths', []))}")
        return 0
    if a.action == "remove":
        return remove_scope(root, a.id, a.move_to)
    if not is_nested(read_registry_file(root)):
        sys.exit("kb: kb.json has no projects yet; run `kb project add --id <id> --title <title>` first")
    proj = next((p for p in load_projects(root) if p["id"] == a.project), None)
    if not proj:
        sys.exit(f"kb: unknown project {a.project}; `kb project add` creates one")
    if a.action == "move":
        sc = next((x for x in scopes if x["id"] == a.id), None)
        if not sc:
            sys.exit(f"kb: unknown scope {a.id}")
        others = [x for x in scopes if x["id"] != a.id]
        moved = {**sc, "project": proj["id"], "project_title": proj["title"]}
        if moved.get("wide") and any(x["project"] == proj["id"] and x.get("wide") for x in others):
            moved["wide"] = False
        save_registry(root, others + [moved])
        print(f"moved {a.id} to {proj['id']}")
        return 0
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", a.id):
        sys.exit("kb: scope ids are lowercase kebab-case")
    if a.id in {x["id"] for x in scopes}:
        sys.exit(f"kb: scope {a.id} exists")
    if a.wide and any(x["project"] == proj["id"] and x.get("wide") for x in scopes):
        sys.exit(f"kb: project {proj['id']} already has a project-wide scope")
    paths = [str(Path(x).expanduser().resolve()).replace(str(Path.home()), "~", 1) for x in split_ids(a.paths)]
    new = {"id": a.id, "title": a.title, "paths": paths, "remotes": split_ids(a.remotes), "related": [],
           "project": proj["id"], "project_title": proj["title"]}
    includes = split_ids(a.includes)
    if includes:
        bad = [x for x in includes if x not in {y["id"] for y in scopes if y["project"] == proj["id"]}]
        if bad:
            sys.exit(f"kb: --includes names scopes not in {proj['id']}: {', '.join(bad)}")
        new["includes"] = includes
    if a.wide:
        new["wide"] = True
    save_registry(root, scopes + [new])
    make_scope_folder(root, a.id)
    print(f"scope {a.id} in {proj['id']}")
    return 0


def remove_scope(root: Path, sid: str, move_to: str | None) -> int:
    """Deletes a scope: its entries move to `move_to` (default: the project-wide scope), tags and includes naming it
    are dropped, and its folder goes."""
    import contextlib
    import io
    import shutil
    known = scope_map(root)
    sc = known.get(sid)
    if not sc:
        sys.exit(f"kb: unknown scope {sid}")
    if sc.get("wide"):
        sys.exit(f"kb: {sid} is the project-wide scope of {sc['project']}; make another scope project-wide first")
    target = move_to or next((x["id"] for x in known.values() if x["project"] == sc["project"] and x.get("wide")), None)
    if not target or target == sid or target not in known:
        sys.exit(f"kb: no scope to move {sid}'s entries to; pass --move-to")
    moved = 0
    for e in project_entries(root, sid, drafts=True):
        if e.section == "overview":
            continue
        with contextlib.redirect_stdout(io.StringIO()):
            cmd_move(argparse.Namespace(id=e.id, project=target))
        moved += 1
    overview = next((p for p in entry_paths(root, f"{sid}/overview") if p.exists()), private_dir(root, sid) / "overview.md")
    if overview.exists() and overview.read_text(encoding="utf-8").strip():
        dest = unique_path(entry_dir(root, target, "facts") / "facts" / f"{sid}-overview.md")
        dest.parent.mkdir(parents=True, exist_ok=True)
        fields, body = split_frontmatter(overview.read_text(encoding="utf-8"))
        title = next((v for k, v in fields if k == "title"), None) or f"{sc.get('title', sid)} overview"
        write_atomic(dest, render_entry([("title", f"{title} (from the removed scope {sc.get('title', sid)})")] +
                                        [(k, v) for k, v in fields if k != "title"], body))
    for e in all_entries(root):
        tags = entry_scopes(e)[1:]
        if sid in tags:
            e.fields = [(k, v) for k, v in e.fields if k != "scopes"] + scopes_field([e.project, *[x for x in tags if x != sid]])
            e.save()
    rest = []
    for x in load_registry(root):
        if x["id"] == sid:
            continue
        if sid in (x.get("includes") or []):
            x = {**x, "includes": [i for i in x["includes"] if i != sid]}
            if not x["includes"]:
                x.pop("includes")
        if sid in (x.get("related") or []):
            x = {**x, "related": [r for r in x["related"] if r != sid]}
        rest.append(x)
    save_registry(root, rest)
    # The private folder goes; a repo's knowledgebase folder only loses the folders the moves left empty.
    for d in scope_dirs(root, sid):
        if d == private_dir(root, sid):
            shutil.rmtree(d, ignore_errors=True)
        elif d.is_dir():
            for sub in sorted(d.rglob("*"), reverse=True):
                if sub.is_dir() and not any(sub.iterdir()):
                    sub.rmdir()
    print(f"removed scope {sid}; {moved} entr{'y' if moved == 1 else 'ies'} moved to {target}")
    return 0


def cmd_register(a) -> int:
    root = kb_root()
    projects = load_registry(root)
    existing = next((p for p in projects if p["id"] == a.id), None)
    path = str(Path(a.path).expanduser().resolve()).replace(str(Path.home()), "~", 1) if a.path else None
    if existing:
        if path and path not in existing.setdefault("paths", []):
            existing["paths"].append(path)
        if a.related:
            existing["related"] = sorted(set(existing.get("related", [])) | set(a.related.split(",")))
    else:
        new = {"id": a.id, "title": a.title or a.id, "paths": [path] if path else [],
               "remotes": [], "related": a.related.split(",") if a.related else []}
        if getattr(a, "project", None):
            if not is_nested(read_registry_file(root)):
                sys.exit("kb: kb.json has no projects yet; run `kb project add` first")
            proj = next((p for p in load_projects(root) if p["id"] == a.project), None)
            if not proj:
                sys.exit(f"kb: unknown project {a.project}")
            new.update(project=proj["id"], project_title=proj["title"])
        projects.append(new)
    save_registry(root, projects)
    make_scope_folder(root, a.id)
    print(f"registered {a.id}")
    return 0


def cmd_open(a) -> int:
    if a.id:
        url = "kb://open?id=" + urllib.parse.quote(a.id, safe="/")
    elif a.project:
        url = "kb://open?project=" + urllib.parse.quote(a.project)
    else:
        url = None
    args = ["open", url] if url else ["open", "-b", "dk.langkilde.kb"]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        print("kb: could not open the Mindmill app. Is it installed? (app/build.sh --install)", file=sys.stderr)
        print(r.stderr.strip(), file=sys.stderr)
    return r.returncode


def cmd_commit(a) -> int:
    root = kb_root()
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    r = subprocess.run(["git", "-C", str(root), "commit", "-q", "-m", a.message])
    return r.returncode


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="kb", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    h = sub.add_parser("hook")
    h.add_argument("event", choices=["session-start", "prompt", "post-tool"])

    c = sub.add_parser("context", help="print the session-start context")
    c.add_argument("--cwd")
    r = sub.add_parser("resolve", help="print the project id for a directory")
    r.add_argument("--cwd")

    ls = sub.add_parser("list")
    ls.add_argument("--project", "--scope", dest="project")
    ls.add_argument("--section", choices=[*SECTIONS, "overview"])
    ls.add_argument("--all-projects", action="store_true")
    ls.add_argument("--include-superseded", action="store_true")

    s = sub.add_parser("search")
    s.add_argument("query", nargs="+")
    s.add_argument("--project", "--scope", dest="project")

    sh = sub.add_parser("show")
    sh.add_argument("id")

    def entry_args(p, kinds=None):
        if kinds:
            p.add_argument("kind", choices=kinds)
        p.add_argument("--title", required=True)
        p.add_argument("--project", "--scope", dest="project")
        p.add_argument("--slug")
        p.add_argument("--date")
        p.add_argument("--summary")
        p.add_argument("--status")
        p.add_argument("--type", dest="kind_value",
                       help="followups: question|action; backlog: pbi|bug")
        p.add_argument("--supersedes", action="append")
        p.add_argument("--source", help="an id or URL; for backlog a comma-separated list")
        p.add_argument("--tags")
        p.add_argument("--attendees")
        p.add_argument("--field", action="append", metavar="KEY=VALUE",
                       help="any other frontmatter field; [a, b] makes a list")
        p.add_argument("--body")
        p.add_argument("--body-stdin", action="store_true", help="read the whole body from stdin")
        p.add_argument("--cross-project", action="store_true",
                       help="allow writing into a scope other than this directory's")
        p.add_argument("--scopes", help="other scopes of the project this entry is also in, comma-separated")

    n = sub.add_parser("new")
    entry_args(n, list(KIND_TO_SECTION))

    ib = sub.add_parser("inbox", help="Claude's proposals waiting for approval")
    ibs = ib.add_subparsers(dest="action", required=True)
    iba = ibs.add_parser("add")
    entry_args(iba)
    iba.add_argument("--section", required=True, choices=APPROVABLE)
    iba.add_argument("--proposed-by", required=True, help="meeting id, session:<id> or daily:<date>")
    iba.add_argument("--reason")
    ibl = ibs.add_parser("list")
    ibl.add_argument("--project", "--scope", dest="project")
    ibl.add_argument("--proposed-by")
    for name in ("approve", "reject"):
        ibs.add_parser(name).add_argument("id")

    fa = sub.add_parser("fact", help="pending changes to facts: flag, list, resolve; links between facts")
    fas = fa.add_subparsers(dest="action", required=True)
    fac = fas.add_parser("challenge", help="flag that a fact may have changed")
    fac.add_argument("id", help="the fact's id")
    fac.add_argument("--by", required=True, help="what showed it: an entry id, session:<id>, or a few words")
    fac.add_argument("--question", required=True, help="one line: what may have changed")
    fac.add_argument("--reason")
    fac.add_argument("--body-stdin", action="store_true", help="the corrected fact text on stdin")
    fal = fas.add_parser("link", help="link two related facts (read both ways), or --remove the link")
    fal.add_argument("id")
    fal.add_argument("other")
    fal.add_argument("--remove", action="store_true")
    fach = fas.add_parser("changes", help="list pending changes")
    fach.add_argument("--project", "--scope", dest="project")
    fach.add_argument("--fact")
    far = fas.add_parser("resolve")
    far.add_argument("id", help="the pending change's inbox id")
    farm = far.add_mutually_exclusive_group(required=True)
    farm.add_argument("--update", action="store_true", help="the fact changed: take the proposed text")
    farm.add_argument("--keep", action="store_true", help="still true: mark it verified today")
    farm.add_argument("--remove", action="store_true", help="no longer true: delete the fact")

    sy = sub.add_parser("sync", help="have the Mindmill app sync the calendar, email, tracker or pull requests now, and wait")
    sy.add_argument("what", nargs="*", help="calendar, email, tracker, prs or all (default: all but email)")
    sy.add_argument("--from", dest="date_from", help="calendar: first day, YYYY-MM-DD (with --to)")
    sy.add_argument("--to", dest="date_to", help="calendar: last day, YYYY-MM-DD")
    sy.add_argument("--no-wait", action="store_true")
    sy.add_argument("--timeout", type=int, default=250, help="seconds to wait for the app (default 250)")
    sh = sub.add_parser("share", help="private or shared entries: status, sync with the repositories, set")
    shs = sh.add_subparsers(dest="action", required=True)
    shst = shs.add_parser("status", help="where each shared entry stands: uncommitted, not pushed, pushed")
    shst.add_argument("--scope")
    shst.add_argument("--sync", action="store_true", help="sync the shared copies first")
    shst.add_argument("--json", action="store_true")
    shsy = shs.add_parser("sync", help="bring the private folders and the repositories' copies in line")
    shsy.add_argument("--scope")
    shsy.add_argument("--push", action="append", metavar="ID",
                      help="an entry changed here: copy it to this checkout's repository even if the copy differs")
    shsy.add_argument("--json", action="store_true")
    shd = shs.add_parser("defaults", help="whether each kind of entry is private or shared when it is made")
    shd.add_argument("--scope")
    shd.add_argument("--json", action="store_true")
    shdf = shs.add_parser("default", help="make a kind of entry private or shared when it is made (--apply: also the existing ones)")
    shdf.add_argument("section")
    shdf.add_argument("visibility", choices=("private", "shared"))
    shdf.add_argument("--scope")
    shdf.add_argument("--apply", action="store_true")
    shdf.add_argument("--json", action="store_true")
    shse = shs.add_parser("set", help="share an entry with the team or make it private")
    shse.add_argument("id")
    shse.add_argument("visibility", choices=["private", "shared"])
    shse.add_argument("--json", action="store_true")
    rp = sub.add_parser("repos", help="a scope's repositories (worked on and knowledge only): status, pull")
    rp.add_argument("action", nargs="?", choices=["status", "pull"], default="status")
    rp.add_argument("--scope")
    rp.add_argument("--repo", help="only this repository (its scope id or title)")
    rp.add_argument("--fetch", action="store_true", help="fetch first, so behind counts are current")
    rp.add_argument("--json", action="store_true")
    cr = sub.add_parser("crew", help="Build-mode sessions run by the Mindmill app: status, send, start, stop, archive")
    crs = cr.add_subparsers(dest="action", required=True)
    crs.add_parser("status").add_argument("--json", action="store_true")
    crm = crs.add_parser("send", help="message a session (id, id prefix, me, lead, overseer or title)")
    crm.add_argument("ref")
    crm.add_argument("message", nargs="*", help="the message; - or nothing reads stdin")
    crst = crs.add_parser("start", help="start a session, as a lead or under one")
    crst.add_argument("--title", required=True)
    crst.add_argument("--under", help="the lead to start it under; usually me")
    crst.add_argument("--lead", action="store_true", help="start it as a new lead")
    crst.add_argument("--project", "--scope", dest="project")
    crst.add_argument("--model")
    crst.add_argument("--strategy")
    crst.add_argument("--about", help="a KB entry id the session is about")
    crst.add_argument("message", nargs="*", help="its first message; - reads stdin")
    crs.add_parser("stop").add_argument("ref")
    crs.add_parser("archive", help="archive a finished session (and the sessions under it) once the user said so"
                   ).add_argument("ref", help="id, id prefix, me or title")

    fa = sub.add_parser("factory", help="from a session the Mindmill app's software factory started: ask the user, log progress")
    fas = fa.add_subparsers(dest="action", required=True)
    fak = fas.add_parser("ask", help="ask the user without blocking; the answer arrives as a message")
    fak.add_argument("question")
    fak.add_argument("--option", action="append", default=[], help="a suggested answer, recommended first; repeat")
    fak.add_argument("--checkpoint", help="the checkpoint that calls for it, e.g. beforePR")
    fas.add_parser("log", help="one line on what happened, for the Factory view").add_argument("text", nargs="+")
    fas.add_parser("status", help="what the factories are doing")

    te = sub.add_parser("test", help="testing in the Mindmill app: suggest a change to a project's test set-up")
    tes = te.add_subparsers(dest="action", required=True)
    tss = tes.add_parser("suggest", help="propose a test set-up change; the user accepts or dismisses it under Test")
    tss.add_argument("--scope", help="the project; defaults to KB_SCOPE")
    tss.add_argument("--text", required=True, help="what to change and why, in a sentence")
    tss.add_argument("--target", help="the test target's id, when the project has several")
    tss.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                     help="a setting to change: method, start, build, test, url, port, pages, scheme, serial, deliverWhen; repeat")

    sn = sub.add_parser("scan", help="project scans the Mindmill app runs: record findings for the user to review, apply them")
    sns = sn.add_subparsers(dest="action", required=True)
    snn = sns.add_parser("new", help="start a scan run (the app does this)")
    snn.add_argument("--scope", required=True)
    snn.add_argument("--kinds", help=f"comma-separated: {', '.join(SCAN_KINDS)} (default all)")
    snn.add_argument("--sources", help=f"comma-separated: {', '.join(SCAN_SOURCES)} (default all)")
    snn.add_argument("--focus")
    snf = sns.add_parser("found", help="record something the scan found; the user decides whether it goes in")
    snf.add_argument("--run", required=True)
    snf.add_argument("--kind", required=True, choices=SCAN_KINDS)
    snf.add_argument("--title")
    snf.add_argument("--summary")
    snf.add_argument("--body")
    snf.add_argument("--body-stdin", action="store_true")
    snf.add_argument("--source", help="where it was found: a repo-relative file:line, a commit, a work item, a doc")
    snf.add_argument("--scope", help="the scope it belongs in (default: the scanned scope)")
    snf.add_argument("--scopes", help="other scopes of the project to tag it with")
    snf.add_argument("--date", help="for decisions: the day it was made, when known")
    snf.add_argument("--status")
    snf.add_argument("--followup-kind", choices=("question", "action"))
    snf.add_argument("--updates", help="the id of an entry this replaces or corrects")
    snf.add_argument("--path", help="for docs: the repository-relative path")
    snf.add_argument("--confidence", choices=("high", "medium", "low"))
    sns.add_parser("progress", help="one line on what the scan looks at now").add_argument("text", nargs="+")
    for name in ("apply", "dismiss"):
        x = sns.add_parser(name)
        x.add_argument("--run", required=True)
        x.add_argument("ids", nargs="+")
    snd = sns.add_parser("done", help="the scan is finished")
    snd.add_argument("--note")
    snd.add_argument("--failed", action="store_true")
    sns.add_parser("list")
    snsh = sns.add_parser("show")
    snsh.add_argument("--json", action="store_true")
    for x in (snd, snsh, sns.choices["progress"]):
        x.add_argument("--run", required=True)

    sg = sub.add_parser("strategy", help="strategies for Build-mode sessions")
    sgs = sg.add_subparsers(dest="action", required=True)
    sgs.add_parser("list")
    sgs.add_parser("show").add_argument("slug")
    sgs.add_parser("delete").add_argument("slug")
    sgn = sgs.add_parser("new")
    sgn.add_argument("--title", required=True)
    sgn.add_argument("--summary")
    sgn.add_argument("--spawn", choices=SPAWN_MODES, default="none")
    sgn.add_argument("--max-sessions", type=int)
    sgn.add_argument("--model")
    sgn.add_argument("--slug")
    sgn.add_argument("--body")
    sgn.add_argument("--body-stdin", action="store_true")
    sgn.add_argument("--force", action="store_true")

    bl = sub.add_parser("backlog", help="create, link, check or reject proposed PBIs and bugs")
    bls = bl.add_subparsers(dest="action", required=True)
    blc = bls.add_parser("create", help="create proposals in the tracker, with their parent and related links")
    blc.add_argument("ids", nargs="+", metavar="id")
    blc.add_argument("--sprint", choices=["current", "next", "none"])
    blc.add_argument("--parent", help="the parent's work item number, or none; overrides the entry and its text")
    blc.add_argument("--yes", action="store_true", help="without it, only print what would be posted")
    bls.add_parser("reject").add_argument("id")
    bll = bls.add_parser("link", help="set the parent and related links of backlog entries or work items; several "
                                      "given together are linked as related to each other")
    bll.add_argument("targets", nargs="+", metavar="entry-or-number")
    bll.add_argument("--parent", help="the parent's work item number, or none to remove it")
    bll.add_argument("--related", action="append", help="a work item number or backlog entry id; repeat or comma-separate")
    bll.add_argument("--scope", help="the scope whose tracker holds bare work item numbers")
    bll.add_argument("--yes", action="store_true", help="without it, only print what would change")
    bld = bls.add_parser("duplicates", help="check proposals waiting to be created against the tracker and each other")
    bld.add_argument("--scope")
    bld.add_argument("--entry", action="append", help="only this proposal; repeatable")
    bld.add_argument("--offline", action="store_true", help="only the knowledge base and local trackers")
    bld.add_argument("--json", action="store_true")
    bldr = bls.add_parser("drop", help="drop a proposal that duplicates an existing item")
    bldr.add_argument("id")
    bldr.add_argument("--duplicate-of", required=True, help="the work item number or backlog entry it duplicates")
    bldr.add_argument("--comment", action="store_true", help="add the proposal's notes as a comment on that item")
    bldr.add_argument("--yes", action="store_true", help="without it, only print what would change")
    bln = bls.add_parser("not-duplicate", help="note that a proposal isn't a duplicate of these items")
    bln.add_argument("id")
    bln.add_argument("others", nargs="+", metavar="number-or-entry")

    tr = sub.add_parser("tracker", help="read the project's work-item tracker: sprints, areas, features, people")
    trs = tr.add_subparsers(dest="action", required=True)
    trs.add_parser("show").add_argument("--project", "--scope", dest="project")
    trm = trs.add_parser("mine", help="your open PBIs and bugs by stage, with their PRs, and PRs to review")
    trm.add_argument("--json", action="store_true")
    trb = trs.add_parser("backlog", help="every open PBI and bug in the trackers, with assignee, scope and task progress")
    trb.add_argument("--scope", help="only items of this scope and the scopes it shows")
    trb.add_argument("--sprint", help="every PBI and bug in this iteration path, finished or not")
    trb.add_argument("--search", help="PBIs and bugs whose title has every word, or this id; finished ones too")
    trb.add_argument("--json", action="store_true")
    trp = trs.add_parser("sprints")
    trp.add_argument("--project", "--scope", dest="project")
    trp.add_argument("--ahead", type=int, default=2, help="future sprints to list after the current one")
    trs.add_parser("areas").add_argument("--project", "--scope", dest="project")
    for name in ("features", "items"):
        trf = trs.add_parser(name)
        trf.add_argument("--project", "--scope", dest="project")
        trf.add_argument("--search", help="words the title has, each anywhere in it")
        trf.add_argument("--type", help="comma-separated work item types")
        trf.add_argument("--area", help="defaults to tracker.area_path")
        trf.add_argument("--limit", type=int, default=15)
    trfi = trs.add_parser("find", help="work items whose id is the query or whose title has its words, e.g. to pick a parent")
    trfi.add_argument("query")
    trfi.add_argument("--project", "--scope", dest="project")
    trfi.add_argument("--limit", type=int, default=10)
    trfi.add_argument("--json", action="store_true")
    tri = trs.add_parser("item")
    tri.add_argument("id")
    tri.add_argument("--project", "--scope", dest="project")
    tri.add_argument("--json", action="store_true", help="with the description, acceptance criteria and repro steps")
    trn = trs.add_parser("note", help="add Markdown to a PBI or bug: at the end of its description, or as a comment")
    trn.add_argument("id")
    trn.add_argument("--project", "--scope", dest="project", help="the scope whose tracker holds it")
    trn.add_argument("--text", help="the Markdown; - or leaving it out reads stdin")
    trn.add_argument("--heading", help="a heading over it, e.g. Research: <title>")
    trn.add_argument("--comment", action="store_true", help="post it as a comment instead (Azure DevOps only)")
    trt = trs.add_parser("task-state", help="move tasks to a state, e.g. Done, In Progress or To Do")
    trt.add_argument("ids", nargs="+")
    trt.add_argument("--state", required=True)
    trt.add_argument("--project", "--scope", dest="project", help="the scope whose tracker holds them")
    trst = trs.add_parser("state", help="move PBIs, bugs or tasks to a state, e.g. Done or Removed")
    trst.add_argument("ids", nargs="+")
    trst.add_argument("--state", required=True)
    trst.add_argument("--project", "--scope", dest="project", help="the scope whose tracker holds them")
    trtg = trs.add_parser("tag", help="add the item's aligned KB tags (item-tags.json) to its tracker tags; only after the user confirmed")
    trtg.add_argument("id")
    trtg.add_argument("--yes", action="store_true")
    trsa = trs.add_parser("start", help="move a PBI or bug nobody has started to the tracker's in-progress state")
    trsa.add_argument("id")
    trsa.add_argument("--project", "--scope", dest="project")
    trrs = trs.add_parser("resolve", help="move a PBI or bug whose work is finished to its Resolved state (or Done/Closed); only after the user said so")
    trrs.add_argument("id")
    trrs.add_argument("--project", "--scope", dest="project")
    trrs.add_argument("--yes", action="store_true")
    tras = trs.add_parser("assign", help="assign PBIs, bugs or tasks to someone (me for yourself)")
    tras.add_argument("ids", nargs="+")
    tras.add_argument("--to", required=True, help="me, a name from the people directory, or an email")
    tras.add_argument("--project", "--scope", dest="project", help="the scope whose tracker holds them")
    trmv = trs.add_parser("move", help="move PBIs or bugs to a sprint, or out of every sprint to the backlog")
    trmv.add_argument("ids", nargs="+")
    where = trmv.add_mutually_exclusive_group(required=True)
    where.add_argument("--sprint", help="an iteration path, or current or next")
    where.add_argument("--backlog", action="store_true",
                       help="no sprint: tracker.backlog_iteration, else the iteration root, else the project")
    trmv.add_argument("--project", "--scope", dest="project", help="whose sprints current and next mean")
    tru = trs.add_parser("people", help="people assigned to the area's work items in the last 90 days")
    tru.add_argument("search", nargs="?", default="")
    tru.add_argument("--area")
    tru.add_argument("--project", "--scope", dest="project")

    spr = sub.add_parser("sprint", help="sprints in every tracker: where each stands, the last sprint's leftovers, "
                                        "decisions on them, the next sprint")
    sprs = spr.add_subparsers(dest="action", required=True)

    def sprint_cmd(name, **kw):
        p = sprs.add_parser(name, **kw)
        p.add_argument("--scope", "--project", dest="scope")
        p.add_argument("--today", help=argparse.SUPPRESS)
        return p

    sprint_cmd("status", help="each tracker's previous, current and next sprint; --scope for one").add_argument("--json", action="store_true")
    sprv = sprint_cmd("review", help="what the previous sprint left unfinished, with tasks, states and the sprint to move to")
    sprv.add_argument("--sprint", help="another sprint's iteration path or name")
    sprv.add_argument("--json", action="store_true")
    spra = sprint_cmd("apply", help="decisions on unfinished items, JSON on stdin: "
                                    '[{"id": 5, "do": "state|move|backlog", "state": "Done", "sprint": "<path>", '
                                    '"tasks": [ids], "task_state": "Done"}]')
    spra.add_argument("--yes", action="store_true", help="without it, only print what would change")
    spra.add_argument("--json", action="store_true")
    sprc = sprint_cmd("create", help="add the next sprint (Mindmill's own tracker); defaults follow the last sprint")
    sprc.add_argument("--name")
    sprc.add_argument("--start", help="YYYY-MM-DD")
    sprc.add_argument("--finish", help="YYYY-MM-DD")
    sprc.add_argument("--json", action="store_true")

    wk = sub.add_parser("work", help="Mindmill's built-in work tracker: features, PBIs, bugs and tasks in the scope's work.json")
    wks = wk.add_subparsers(dest="action", required=True)

    def work_parser(name, **kw):
        p = wks.add_parser(name, **kw)
        p.add_argument("--scope", "--project", dest="scope")
        return p

    def item_args(p):
        p.add_argument("--state", help="New, Approved, Committed, Done, Removed; tasks: To Do, In Progress, Done, Removed")
        p.add_argument("--parent", help="a feature for a PBI or bug, a PBI or bug for a task; none for no parent")
        p.add_argument("--sprint", help="a sprint name, current, or none")
        for k in ("description", "acceptance", "repro"):
            p.add_argument(f"--{k}", help="Markdown; - reads stdin")
        p.add_argument("--assignee")
        p.add_argument("--tags", help="comma-separated")
        p.add_argument("--effort", help="a number, or none")

    wkl = work_parser("list", help="the backlog as a tree, without Done and Removed unless --all")
    wkl.add_argument("--type", help="feature, pbi, bug or task; comma-separated for several")
    wkl.add_argument("--state", help="comma-separated")
    wkl.add_argument("--sprint", help="a sprint name, current, or none")
    wkl.add_argument("--all", action="store_true")
    wkl.add_argument("--json", action="store_true")
    wksh = work_parser("show")
    wksh.add_argument("id")
    wksh.add_argument("--json", action="store_true")
    wka = work_parser("add", help="prints `created <id>`")
    wka.add_argument("type", choices=WORK_TYPES, type=str.lower)
    wka.add_argument("title")
    item_args(wka)
    wkst = work_parser("set")
    wkst.add_argument("ids", nargs="+")
    wkst.add_argument("--title")
    item_args(wkst)
    wkr = work_parser("remove", help="set Removed; --delete takes it out of the file")
    wkr.add_argument("ids", nargs="+")
    wkr.add_argument("--delete", action="store_true", help="fails when it has children")
    wksp = wks.add_parser("sprint", help="the scope's sprints")
    wksps = wksp.add_subparsers(dest="sprint_action", required=True)

    def sprint_parser(name):
        p = wksps.add_parser(name)
        p.add_argument("--scope", "--project", dest="scope")
        return p

    sprint_parser("list").add_argument("--json", action="store_true")
    wkspa = sprint_parser("add")
    wkspa.add_argument("name")
    wkspa.add_argument("--start", required=True, help="YYYY-MM-DD")
    wkspa.add_argument("--finish", required=True, help="YYYY-MM-DD")
    sprint_parser("use").add_argument("on_off", choices=["on", "off"], type=str.lower)
    wkb = work_parser("board", help="PBIs and bugs by state; the current sprint when sprints are on")
    wkb.add_argument("--sprint", help="a sprint name, current, or none")

    di = sub.add_parser("discussion", help="open discussions (email threads, chats): list, note a point, close")
    dis = di.add_subparsers(dest="action", required=True)
    dil = dis.add_parser("list", help="open discussions, newest activity first")
    dil.add_argument("--project", "--scope", dest="project")
    dil.add_argument("--all-projects", action="store_true")
    dil.add_argument("--all", action="store_true", help="also parked and concluded ones")
    dil.add_argument("--json", action="store_true")
    din = dis.add_parser("note", help="add a point raised, an open question or a finding (text from --text or stdin)")
    din.add_argument("id")
    din.add_argument("--kind", choices=["point", "question", "finding"], default="point")
    din.add_argument("--who", help="who raised it, by name")
    din.add_argument("--date", help="when it was said, YYYY-MM-DD")
    din.add_argument("--text")
    din.add_argument("--waiting-on", choices=WAITING_ON)
    dist = dis.add_parser("status", help="open, park or conclude a discussion")
    dist.add_argument("id")
    dist.add_argument("status", choices=STATUSES["discussions"])
    dist.add_argument("--outcome", help="what was settled, for the Outcome section")
    dist.add_argument("--waiting-on", choices=WAITING_ON)

    dc = sub.add_parser("docs", help="documentation files in a scope's repository: scan, add, drafts edited in the app")
    dcs = dc.add_subparsers(dest="action", required=True)
    for name, hlp in (("scan", "find documentation files in the repository (* = added)"),
                      ("list", "the added docs and drafts, with whether each draft is in the repository yet")):
        x = dcs.add_parser(name, help=hlp)
        x.add_argument("--project", "--scope", dest="project")
        x.add_argument("--json", action="store_true")
    for name, hlp in (("add", "add repository docs to the scope's Architecture"),
                      ("discard", "throw away the drafts of these docs"),
                      ("saved", "the drafts are in a pull request now: clear them"),
                      ("remove", "take docs off the list (the files stay)")):
        x = dcs.add_parser(name, help=hlp)
        x.add_argument("paths", nargs="+")
        x.add_argument("--project", "--scope", dest="project")
    for name, hlp in (("show", "a doc's text: the draft when there is one"),
                      ("draft", "save a draft of a doc from stdin (a new path makes a new doc)"),
                      ("diff", "the drafts against the repository, as a unified diff")):
        x = dcs.add_parser(name, help=hlp)
        x.add_argument("path", nargs="?" if name == "diff" else None)
        x.add_argument("--project", "--scope", dest="project")

    rs = sub.add_parser("research", help="research done with Claude: list, note findings, summarize, set status")
    rss = rs.add_subparsers(dest="action", required=True)
    rsl = rss.add_parser("list", help="open research and research waiting to be finished, newest activity first")
    rsl.add_argument("--project", "--scope", dest="project")
    rsl.add_argument("--all-projects", action="store_true")
    rsl.add_argument("--all", action="store_true", help="also done and parked research")
    rsl.add_argument("--for", dest="for_", help="only research for this: a work item id (#1234 or wi:1234) or an entry id")
    rsn = rss.add_parser("note", help="add to Findings, Open questions, Sources or Takeaways (text from --text or stdin)")
    rsn.add_argument("id")
    rsn.add_argument("--kind", choices=list(RESEARCH_NOTE), default="finding")
    rsn.add_argument("--text")
    rssu = rss.add_parser("summary", help="write the summary (from --text or stdin) and takeaways, and set it to review")
    rssu.add_argument("id")
    rssu.add_argument("--text")
    rssu.add_argument("--takeaway", action="append", default=[], help="one short line for the PBI; repeat")
    rsst = rss.add_parser("status", help="open, review, done or parked")
    rsst.add_argument("id")
    rsst.add_argument("status", choices=STATUSES["research"])
    rsst.add_argument("--transferred", help="what the takeaways were added to: wi:<id> or an entry id")

    nt = sub.add_parser("note", help="the user's notes that don't fit elsewhere yet: list, add, summary, filed, status")
    nts = nt.add_subparsers(dest="action", required=True)
    ntl = nts.add_parser("list", help="open notes, newest activity first")
    ntl.add_argument("--project", "--scope", dest="project")
    ntl.add_argument("--all", action="store_true", help="also filed ones")
    ntl.add_argument("--all-projects", action="store_true")
    nta = nts.add_parser("add", help="write a note down (text from --text or stdin), or add to one with --to")
    nta.add_argument("--text")
    nta.add_argument("--title")
    nta.add_argument("--to", help="an existing note's id")
    nta.add_argument("--project", "--scope", dest="project")
    ntsu = nts.add_parser("summary", help="write what the note comes to (from --text or stdin), as confirmed with the user")
    ntsu.add_argument("id")
    ntsu.add_argument("--text")
    ntf = nts.add_parser("filed", help="record where part of the note went: `<section>: <title>`")
    ntf.add_argument("id")
    ntf.add_argument("--text", required=True)
    ntst = nts.add_parser("status", help="open, or filed when everything in it went where it belongs")
    ntst.add_argument("id")
    ntst.add_argument("status", choices=STATUSES["notes"])

    ide = sub.add_parser("idea", help="ideas to brainstorm: list, add a thought, question, next step or what it turned into")
    ids_ = ide.add_subparsers(dest="action", required=True)
    idl = ids_.add_parser("list", help="new and exploring ideas, newest activity first")
    idl.add_argument("--project", "--scope", dest="project")
    idl.add_argument("--all-projects", action="store_true")
    idl.add_argument("--all", action="store_true", help="also shelved and done ones")
    idn = ids_.add_parser("note", help="add to Brainstorm, Open questions, Next steps or Turned into (text from --text or stdin)")
    idn.add_argument("id")
    idn.add_argument("--kind", choices=list(IDEA_NOTE), default="thought")
    idn.add_argument("--text")
    ids_.add_parser("status", help="new, exploring, shelved or done (turned into something)").add_argument("id")
    ids_.choices["status"].add_argument("status", choices=STATUSES["ideas"])

    pr = sub.add_parser("pr", help="your pull requests: list, comments, reply, resolve, complete")
    prs = pr.add_subparsers(dest="action", required=True)
    prs.add_parser("list", help="your active pull requests with comments, reviewers and what blocks completing").add_argument("--json", action="store_true")
    prd = prs.add_parser("done", help="your completed pull requests that left a worktree or branch behind")
    prd.add_argument("--days", type=int, default=45)
    prd.add_argument("--json", action="store_true")
    prcl = prs.add_parser("cleanup", help="remove what a completed pull request left behind")
    prcl.add_argument("id", type=int)
    prcl.add_argument("--worktree", action="store_true", help="remove the worktrees on its branch")
    prcl.add_argument("--branch", action="store_true", help="delete the local branch")
    prcl.add_argument("--remote", action="store_true", help="delete the branch on Azure DevOps")
    prcl.add_argument("--force", action="store_true", help="also with uncommitted changes or commits the PR didn't take")
    prck = prs.add_parser("checks", help="a pull request's build checks; failed steps with their log, and requeue")
    prck.add_argument("id")
    prck.add_argument("--log-lines", type=int, default=60, help="lines from the end of each failed step's log (0: none)")
    prck.add_argument("--requeue", action="store_true", help="run failed, expired or stuck builds again")
    prck.add_argument("--requeue-expired", action="store_true", help="run only expired builds again")
    prck.add_argument("--json", action="store_true")
    prsh = prs.add_parser("show", help="a pull request with its comment threads")
    prsh.add_argument("id", type=int)
    prsh.add_argument("--json", action="store_true")
    prsh.add_argument("--all", action="store_true", help="also resolved threads")
    prv = prs.add_parser("vote", help="cast your vote on a pull request; only when the user picked it")
    prv.add_argument("id", type=int)
    prv.add_argument("--vote", required=True, choices=list(VOTES), help="approve, approve-with-suggestions, wait-for-author, reject or reset")
    prr = prs.add_parser("reply", help="reply on a comment thread (text from --text or stdin)")
    prr.add_argument("id", type=int)
    prr.add_argument("thread", type=int)
    prr.add_argument("--text")
    prr.add_argument("--status", choices=["active", "fixed", "wontFix", "closed", "byDesign", "pending"],
                     help="also set the thread's status, e.g. fixed to resolve it")
    prcm = prs.add_parser("comment", help="start a new comment thread on a pull request (text from --text or stdin)")
    prcm.add_argument("id", type=int)
    prcm.add_argument("--text")
    prt = prs.add_parser("thread", help="set a comment thread's status: fixed resolves it")
    prt.add_argument("id", type=int)
    prt.add_argument("thread", type=int)
    prt.add_argument("--status", required=True, choices=["active", "fixed", "wontFix", "closed", "byDesign", "pending"])
    prc = prs.add_parser("complete", help="complete (merge) a pull request, or set it to auto-complete")
    prc.add_argument("id", type=int)
    prc.add_argument("--strategy", choices=[n for n, _ in MERGE_STRATEGIES], help="defaults to the first the branch policy allows")
    prc.add_argument("--delete-branch", dest="delete_branch", action="store_true", default=None)
    prc.add_argument("--keep-branch", dest="delete_branch", action="store_false")
    prc.add_argument("--complete-work-items", action="store_true", help="also move linked work items on (off by default)")
    prc.add_argument("--message", help="merge commit message")
    prc.add_argument("--auto", action="store_true", help="complete by itself when the policies pass")
    prc.add_argument("--cancel-auto", action="store_true")

    fu = sub.add_parser("followup", help="close a question or action")
    fus = fu.add_subparsers(dest="action", required=True)
    fuc = fus.add_parser("close")
    fuc.add_argument("id")
    fuc.add_argument("--status", required=True, choices=["done", "dropped", "open"])
    fuc.add_argument("--resolved-by", action="append",
                     help="decision id, work item URL or words; repeat (or comma-separate) for several")
    fuc.add_argument("--answer")
    fuc.add_argument("--auto", action="store_true", help="the app closed it by itself (closed_by: kb)")
    fub = fus.add_parser("to-backlog", help="turn a \"create a PBI\" follow-up into a suggested backlog item and close it")
    fub.add_argument("id")
    fum = fus.add_parser("merge", help="fold duplicate follow-ups into one; it keeps every source link (only after the user confirmed)")
    fum.add_argument("id", help="the follow-up to keep")
    fum.add_argument("others", nargs="+")
    fup = fus.add_parser("propose-merge", help="suggest that two follow-ups say the same; the user decides in the app")
    fup.add_argument("id", help="the one to keep")
    fup.add_argument("other")
    fup.add_argument("--why")
    fuls = fus.add_parser("merges", help="merges waiting for the user, or --dismiss two ids that aren't the same")
    fuls.add_argument("--json", action="store_true")
    fuls.add_argument("--dismiss", nargs=2)
    fun = fus.add_parser("note", help="add a dated line under ## Updates")
    fun.add_argument("id")
    fun.add_argument("--text", required=True)
    fun.add_argument("--by", help="what brought it, e.g. an entry id")

    st = sub.add_parser("settings", help="per-project settings.json")
    sts = st.add_subparsers(dest="action", required=True)
    sts.add_parser("show").add_argument("--project", "--scope", dest="project")
    stg = sts.add_parser("get")
    stg.add_argument("key", help="dotted, e.g. tracker.title_prefix")
    stg.add_argument("--project", "--scope", dest="project")
    sst = sts.add_parser("set")
    sst.add_argument("key")
    sst.add_argument("value", help="JSON, or a plain string")
    sst.add_argument("--project", "--scope", dest="project")

    so = sub.add_parser("sources", help="knowledge sources for Ask")
    sos = so.add_subparsers(dest="action", required=True)
    sol = sos.add_parser("list")
    sol.add_argument("--project", "--scope", dest="project")
    sol.add_argument("--json", action="store_true")
    soa = sos.add_parser("add")
    soa.add_argument("--kind", required=True, choices=SOURCE_KINDS)
    soa.add_argument("--title", required=True)
    soa.add_argument("--use-for", required=True, help="one line: which questions this source answers")
    soa.add_argument("--id")
    soa.add_argument("--config", action="append", metavar="KEY=VALUE")
    for p_ in (soa,):
        p_.add_argument("--project", "--scope", dest="project")
        p_.add_argument("--global", dest="globally", action="store_true")
    sor = sos.add_parser("remove")
    sor.add_argument("id")
    sor.add_argument("--project", "--scope", dest="project")
    sor.add_argument("--global", dest="globally", action="store_true")
    soe = sos.add_parser("enable")
    soe.add_argument("id")
    soe.add_argument("state", choices=["on", "off"])
    soe.add_argument("--project", "--scope", dest="project")
    soe.add_argument("--global", dest="globally", action="store_true")
    sot = sos.add_parser("test")
    sot.add_argument("id")
    sot.add_argument("--project", "--scope", dest="project")
    sot.add_argument("--query", required=True)
    for p_ in (sol, sot):
        p_.set_defaults(globally=False)

    mv = sub.add_parser("move", help="move an entry to another project and repoint references")
    mv.add_argument("id")
    mv.add_argument("--project", "--scope", dest="project", required=True)

    ca = sub.add_parser("calendar", help="mirror calendar events (JSON on stdin) as meeting files")
    cas = ca.add_subparsers(dest="calendar_cmd", required=True)
    cai = cas.add_parser("import")
    cai.add_argument("--from", dest="date_from")
    cai.add_argument("--to", dest="date_to")

    rm = sub.add_parser("reminder", help="personal reminders with a due date (reminders/ in the KB root)")
    rms = rm.add_subparsers(dest="reminder_cmd", required=True)
    rma = rms.add_parser("add")
    rma.add_argument("--title", required=True)
    rma.add_argument("--due", help="YYYY-MM-DD; leave out for no due date")
    rma.add_argument("--note")
    rma.add_argument("--body-stdin", action="store_true")
    rma.add_argument("--project", "--scope", dest="project")
    rma.add_argument("--source", help="email:<id>, session:<id>, daily:<date>; a second add with the same source is a no-op")
    rma.add_argument("--from", dest="sender", help="the sender's name, never an address")
    rma.add_argument("--from-domain")
    rma.add_argument("--link")
    rma.add_argument("--reason")
    rma.add_argument("--proposed", action="store_true", help="Claude's suggestion, waiting for the user")
    rml = rms.add_parser("list")
    rml.add_argument("--status", choices=REMINDER_STATUSES)
    rml.add_argument("--all", action="store_true")
    for name in ("done", "dismiss", "accept", "reopen"):
        rms.add_parser(name).add_argument("id")
    rmd = rms.add_parser("due")
    rmd.add_argument("id")
    rmd.add_argument("date", help="YYYY-MM-DD, or none to clear it")

    pe = sub.add_parser("people", help="colleagues from Azure DevOps and people added by name, for attendees and owners")
    pes = pe.add_subparsers(dest="people_cmd", required=True)
    pes.add_parser("sync", help="fetch every team member from the trackers' Azure DevOps organisations")
    pse = pes.add_parser("search")
    pse.add_argument("query")
    pse.add_argument("--limit", type=int, default=10)
    pse.add_argument("--json", action="store_true")
    pes.add_parser("list").add_argument("--json", action="store_true")
    pad = pes.add_parser("add", help="remember someone by name, with mail and initials when known")
    pad.add_argument("--name", required=True)
    pad.add_argument("--email")
    pad.add_argument("--initials")

    go = sub.add_parser("goal", help="personal long-term goals (goals/ in the KB root), a side agenda")
    gos = go.add_subparsers(dest="goal_cmd", required=True)
    goa = gos.add_parser("add")
    goa.add_argument("--title", required=True)
    goa.add_argument("--horizon", help="when, in the user's words: \"by end of 2027\", \"next review\"")
    goa.add_argument("--why")
    goa.add_argument("--why-stdin", action="store_true")
    gos.add_parser("list").add_argument("--all", action="store_true")
    gos.add_parser("show").add_argument("id")
    gol = gos.add_parser("log", help="add a dated line to ## Progress, newest first")
    gol.add_argument("id")
    gol.add_argument("text")
    gol.add_argument("--date")
    gop = gos.add_parser("propose", help="propose a line for ## Progress (under ## Proposed progress) for the user to add or dismiss")
    gop.add_argument("id")
    gop.add_argument("text")
    gop.add_argument("--date", help="when it happened (default today)")
    gos.add_parser("scanned", help="record that you looked for progress today and found nothing to propose").add_argument("id")
    gost = gos.add_parser("status")
    gost.add_argument("id")
    gost.add_argument("status", choices=GOAL_STATUSES)

    em = sub.add_parser("email", help="email scan state: last scan time and ignored senders (email.json)")
    ems = em.add_subparsers(dest="email_cmd", required=True)
    ems.add_parser("state")
    ems.add_parser("scanned").add_argument("--at")
    ems.add_parser("ignore").add_argument("sender", help="a domain, sender name or word")

    de = sub.add_parser("delete", help="delete an entry and unhook references to it")
    de.add_argument("id")
    de.add_argument("--dry-run", action="store_true", help="only list what would change")

    td = sub.add_parser("today", help="print the daily plan path, or tick a line in it")
    td.add_argument("--date")
    td.add_argument("--check", help="the checklist line's text, without the box")
    td.add_argument("--done", choices=["true", "false"], default="true")

    su = sub.add_parser("supersede")
    su.add_argument("old")
    su.add_argument("new")

    sub.add_parser("lint")

    rg = sub.add_parser("register")
    rg.add_argument("--id", required=True)
    rg.add_argument("--title")
    rg.add_argument("--path")
    rg.add_argument("--related")
    rg.add_argument("--project", help="the project (kb.json v2) the new scope belongs to")

    scs = sub.add_parser("scopes", help="an entry's scopes: print, or --set/--add/--remove")
    scs.add_argument("id")
    scg = scs.add_mutually_exclusive_group()
    scg.add_argument("--set")
    scg.add_argument("--add")
    scg.add_argument("--remove")

    tg = sub.add_parser("tags", help="tags in use, or an entry's tags: print, or --set/--add/--remove (--auto: only add, never what the user removed)")
    tg.add_argument("id", nargs="?")
    tgg = tg.add_mutually_exclusive_group()
    tgg.add_argument("--set")
    tgg.add_argument("--add")
    tgg.add_argument("--remove")
    tg.add_argument("--auto", action="store_true")
    tg.add_argument("--project", "--scope", dest="project")
    tg.add_argument("--json", action="store_true")

    sc = sub.add_parser("scope", help="the scopes of each project")
    scp = sc.add_subparsers(dest="action", required=True)
    scp.add_parser("list")
    sca = scp.add_parser("add")
    sca.add_argument("--project", required=True)
    sca.add_argument("--id", required=True)
    sca.add_argument("--title", required=True)
    sca.add_argument("--paths")
    sca.add_argument("--remotes")
    sca.add_argument("--wide", action="store_true", help="the project-wide scope")
    sca.add_argument("--includes", help="comma-separated scopes whose entries this one also shows, such as Mobile: android,ios")
    scm = scp.add_parser("move")
    scm.add_argument("id")
    scm.add_argument("--project", required=True)
    scr = scp.add_parser("remove", help="delete a scope, moving its entries to another scope")
    scr.add_argument("id")
    scr.add_argument("--move-to", help="defaults to the project-wide scope")

    ly = sub.add_parser("layout", help="where the KB keeps things: show it, or move to the split layout")
    lys = ly.add_subparsers(dest="action", required=True)
    lys.add_parser("show")
    lym = lys.add_parser("migrate", help="copy a one-folder KB to the split layout: team knowledge into each repo's "
                                         "knowledgebase/, the rest private")
    lym.add_argument("--to", default="~/knowledgebase")
    lym.add_argument("--yes", action="store_true", help="without it, only print what would be copied")

    pj = sub.add_parser("project", help="projects: groups of scopes")
    pjs = pj.add_subparsers(dest="action", required=True)
    pjs.add_parser("list")
    pja = pjs.add_parser("add")
    pja.add_argument("--id", required=True)
    pja.add_argument("--title", required=True)
    pja.add_argument("--wide-scope", help="id of its project-wide scope (default: the project id)")
    pja.add_argument("--wide-title", default="Project-wide")

    o = sub.add_parser("open")
    o.add_argument("id", nargs="?")
    o.add_argument("--project", "--scope", dest="project")

    cm = sub.add_parser("commit")
    cm.add_argument("-m", "--message", required=True)

    a = ap.parse_args(argv)
    if a.cmd == "hook":
        return run_hook(a.event)
    return {
        "context": cmd_context, "resolve": cmd_resolve, "list": cmd_list, "search": cmd_search,
        "show": cmd_show, "new": cmd_new, "supersede": cmd_supersede, "lint": cmd_lint,
        "register": cmd_register, "open": cmd_open, "commit": cmd_commit, "inbox": cmd_inbox,
        "backlog": cmd_backlog, "tracker": cmd_tracker, "sprint": cmd_sprint, "work": cmd_work, "layout": cmd_layout, "followup": cmd_followup, "settings": cmd_settings, "today": cmd_today,
        "sources": cmd_sources, "delete": cmd_delete, "move": cmd_move, "calendar": cmd_calendar,
        "reminder": cmd_reminder, "email": cmd_email, "goal": cmd_goal, "scopes": cmd_scopes, "tags": cmd_tags, "scope": cmd_scope, "project": cmd_project, "fact": cmd_fact, "crew": cmd_crew, "sync": cmd_sync, "share": cmd_share, "repos": cmd_repos, "factory": cmd_factory, "test": cmd_test, "scan": cmd_scan,
        "strategy": cmd_strategy, "people": cmd_people, "pr": cmd_pr, "discussion": cmd_discussion, "idea": cmd_idea, "note": cmd_note, "research": cmd_research, "docs": cmd_docs,
    }[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
