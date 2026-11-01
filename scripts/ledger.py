#!/usr/bin/env python3
"""patches/approved.txt and patches/changes.toml: parse and check them together.

approved.txt, one line per approved fork commit:
    <repo> <patch-id> <short-sha> <group> <subject>
changes.toml, one table per group: [groups.<group>] with order, title, what, why, optional
docs (file names under docs/) and notes ("<tree path>:<file path>" = text).

Checks: five fields per line, a valid group slug, no repo + patch-id twice, every group a line
names exists with a title, what and why, and every group is used.

    ledger.py check <approved.txt> <changes.toml>   FAIL: lines on stdout, exit 1 if any
    ledger.py has-group <changes.toml> <group>      exit 0 if the group exists
Used by verify-tree.sh, approve.sh and fork_report.py.
"""
import re
import sys
import tomllib
from dataclasses import dataclass, field

SLUG = re.compile(r"^[a-z0-9-]+$")


@dataclass(frozen=True)
class Approval:
    repo: str
    patch_id: str
    sha: str
    group: str
    subject: str


@dataclass
class Group:
    slug: str
    order: int
    title: str
    what: str
    why: str
    docs: list = field(default_factory=list)
    notes: dict = field(default_factory=dict)


def parse_approved(text):
    """(approvals, errors) from the text of approved.txt."""
    out, errors = [], []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split(" ", 4)
        if len(parts) < 5 or not all(parts):
            errors.append(f"approved.txt line {n}: needs <repo> <patch-id> <short-sha> <group> "
                          f"<subject>: {line}")
            continue
        if not SLUG.match(parts[3]):
            errors.append(f"approved.txt line {n}: group {parts[3]!r} isn't [a-z0-9-]+")
            continue
        out.append(Approval(*parts))
    return out, errors


def load_groups(data):
    """(groups by slug, errors) from the bytes of changes.toml."""
    try:
        doc = tomllib.loads(data.decode("utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        return {}, [f"changes.toml: {e}"]
    groups, errors = {}, []
    tables = doc.get("groups", {})
    if not isinstance(tables, dict):
        return {}, ["changes.toml: [groups] must hold one table per group"]
    for slug, t in tables.items():
        if not isinstance(t, dict):
            errors.append(f"changes.toml: groups.{slug} isn't a table")
            continue
        if not SLUG.match(slug):
            errors.append(f"changes.toml: group {slug!r} isn't [a-z0-9-]+")
            continue
        for k in ("title", "what", "why"):
            if not isinstance(t.get(k), str) or not t[k].strip():
                errors.append(f"changes.toml: group {slug} has no {k}")
        if not isinstance(t.get("order", 0), int):
            errors.append(f"changes.toml: group {slug}: order isn't a number")
        notes = t.get("notes", {})
        if not isinstance(notes, dict) or not all(isinstance(v, str) for v in notes.values()):
            errors.append(f"changes.toml: group {slug}: notes must be \"path\" = \"text\"")
            notes = {}
        groups[slug] = Group(slug, t.get("order", 0) if isinstance(t.get("order", 0), int) else 0,
                             str(t.get("title", "")).strip(), str(t.get("what", "")).strip(),
                             str(t.get("why", "")).strip(), list(t.get("docs", [])), dict(notes))
    return groups, errors


def check(approvals, groups):
    """Errors between the two files."""
    errors, seen = [], set()
    for a in approvals:
        if (a.repo, a.patch_id) in seen:
            errors.append(f"approved.txt: {a.repo} {a.patch_id} is listed twice")
        seen.add((a.repo, a.patch_id))
        if a.group not in groups:
            errors.append(f"approved.txt: {a.repo} {a.sha} {a.subject!r}: group {a.group} "
                          f"isn't in changes.toml")
    used = {a.group for a in approvals}
    for slug in sorted(set(groups) - used):
        errors.append(f"changes.toml: group {slug} has no approved commit")
    return errors


def main(argv):
    if len(argv) == 3 and argv[0] == "check":
        with open(argv[1], encoding="utf-8") as f:
            approvals, errors = parse_approved(f.read())
        with open(argv[2], "rb") as f:
            groups, gerr = load_groups(f.read())
        errors += gerr + check(approvals, groups)
        for e in errors:
            print(f"FAIL: {e}")
        return 1 if errors else 0
    if len(argv) == 3 and argv[0] == "has-group":
        with open(argv[1], "rb") as f:
            groups, _ = load_groups(f.read())
        return 0 if argv[2] in groups else 1
    print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:   # a crash must read as a failure, never as a clean check
        print(f"FAIL: ledger.py: {type(e).__name__}: {e}")
        sys.exit(1)
