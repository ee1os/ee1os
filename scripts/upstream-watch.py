#!/usr/bin/env python3
"""Flag GrapheneOS changes that need a decision before we take them.

  upstream-watch.py preview      our release tag -> upstream branch 17 (nightly: what's coming)
  upstream-watch.py check <tag>  our release tag -> <tag> (track-upstream.sh, before pushing)

Compares GrapheneOS's manifests and every GitHub-hosted GrapheneOS project between the two
points and flags what is strategic: projects added or removed, a new AOSP base, upstream
commits touching files our forks change, and commits in the areas this project depends on
(lock settings, keyguard, duress, boot animation and branding, Updater, ...). Routine changes
(security patch level, time zone data, unrelated fixes) are listed but not flagged.

Writes a report to $WS/upstream-watch/. If anything is flagged and the executable
$WS/state/review-hook exists, it is run with the report path and its output is saved next to
the report as <report>-review.md. preview notifies klava hq only about flags not seen before.
check exits 10 when anything is flagged, 0 when not, 1 on errors. DRY_RUN=1: no notification.
"""
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import date

WS = "/mnt/flash/scratch/grapheneos"
TREE = f"{WS}/grapheneos-17"
STATE = f"{WS}/state"
OUT = f"{WS}/upstream-watch"
NOTIFY = "/mnt/tank/scripts/notify-telegram.sh"
GH_ORG = "GrapheneOS"

# tree path -> repo name, for every project we change (as in track-upstream.sh)
FORKS = {
    "build/make": "platform_build",
    "frameworks/base": "platform_frameworks_base",
    "packages/apps/Settings": "platform_packages_apps_Settings",
    "packages/apps/SetupWizard2": "platform_packages_apps_SetupWizard2",
    "packages/apps/Updater": "platform_packages_apps_Updater",
    "system/sepolicy": "platform_system_sepolicy",
}

# file paths (project path + "/" + file) in the areas the design depends on
AREAS = [
    (r"locksettings|LockSettings|LockPattern|Weaver|SyntheticPassword", "credentials"),
    (r"[Dd]uress", "duress"),
    (r"[Kk]eyguard|com/android/keyguard/|bouncer", "keyguard"),
    (r"bootanimation|BootAnimation|android-logo|^branding/", "boot animation / branding"),
    (r"^build/make/target/product/", "product packages"),
    (r"^packages/apps/Updater/", "Updater"),
    (r"^packages/apps/SetupWizard2/", "setup wizard"),
    (r"UserManagerService|UserController|pm/UserManager|UserRestrictions", "users"),
    (r"RecoverySystem|StorageManagerService|vold", "storage / recovery"),
    (r"[Pp]rivateSpace|private_space|PrivateProfile", "private space"),
]
KEYWORDS = re.compile(
    r"brand|logo|boot ?animation|duress|second factor|2fa|pinning|update server|"
    r"private space|keyguard|lock ?screen|locksettings|weaver|setup wizard|"
    r"multi-?user|secondary user|user switch",
    re.I,
)
ROUTINE = re.compile(r"security patch level|time ?zone|tzdb|gradle|vendor-specs|"
                     r"build-index|gservices", re.I)
MAX_PATCH = 4000        # characters of each flagged file's patch in the report
MAX_REPORT = 250_000    # characters of patches in the whole report


def run(*cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check).stdout


def gh_json(path):
    return json.loads(run("gh", "api", path))


def gh_raw(path):
    return run("gh", "api", path, "-H", "Accept: application/vnd.github.raw")


def manifest(ref):
    """{name: (path, revision, remote)} and the default AOSP revision of the manifest at ref."""
    root = ET.fromstring(gh_raw(f"repos/{GH_ORG}/platform_manifest/contents/default.xml?ref={ref}"))
    remotes = {r.get("name"): r.get("revision") for r in root.iter("remote")}
    d = root.find("default")
    dremote, drev = d.get("remote"), d.get("revision")
    projects = {}
    for p in root.iter("project"):
        remote = p.get("remote", dremote)
        rev = p.get("revision") or remotes.get(remote) or drev
        projects[p.get("name")] = (p.get("path", p.get("name")), rev, remote)
    return projects, drev


def fork_files(path, base):
    """Files our fork's envs-17 changes against the upstream base revision."""
    try:
        mb = run("git", "-C", f"{TREE}/{path}", "merge-base", base, "envs-17").strip()
        return set(run("git", "-C", f"{TREE}/{path}", "diff", "--name-only", mb, "envs-17").split())
    except subprocess.CalledProcessError:
        return set()


def compare(name, frm, to):
    """Commits and files of a GitHub compare; None if GitHub can't compare them."""
    try:
        c = gh_json(f"repos/{GH_ORG}/{name}/compare/{frm}...{to}")
    except subprocess.CalledProcessError:
        return None
    return c


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("preview", "check") or \
            (sys.argv[1] == "check" and len(sys.argv) != 3):
        print("\n".join(__doc__.strip().splitlines()[2:4]), file=sys.stderr)
        return 1
    mode = sys.argv[1]
    os.environ["PATH"] = "/mnt/flash/home/faeton/.local/bin:/usr/local/bin:/usr/bin:/bin:" \
        + os.environ.get("PATH", "")
    os.environ.setdefault("HOME", "/mnt/flash/home/faeton")
    os.makedirs(OUT, exist_ok=True)
    try:
        base = open(f"{STATE}/upstream-tag").read().strip()
    except OSError:
        print("no $STATE/upstream-tag: the release tag we are on", file=sys.stderr)
        return 1
    target = "17" if mode == "preview" else sys.argv[2]

    old, old_aosp = manifest(base)
    new, new_aosp = manifest(target)

    flags = []      # (key, text) strategic findings; key identifies it across runs
    report = []     # markdown lines
    patches = []    # (heading, patch) for flagged files
    routine = []

    if old_aosp != new_aosp:
        flags.append((f"aosp:{new_aosp}", f"AOSP base changes: {old_aosp} -> {new_aosp}"))
    for n in sorted(set(new) - set(old)):
        flags.append((f"added:{n}", f"new project {new[n][0]} ({n}, {new[n][2]})"))
    for n in sorted(set(old) - set(new)):
        flags.append((f"removed:{n}", f"project removed: {old[n][0]} ({n})"))

    unchecked = []
    for n in sorted(new):
        path, rev, remote = new[n]
        if remote != "grapheneos" or n not in old:
            if remote == "grapheneos-gitlab" and n in old and old[n][1] != rev:
                unchecked.append(path)
            continue
        frm = old[n][1]
        if frm == rev:
            continue
        c = compare(n, frm, rev)
        if c is None:
            # GitHub can't relate the two revisions: history rewritten or the repo replaced
            flags.append((f"nocompare:{n}:{rev}",
                          f"`{path}` can't be compared with our base (history rewritten?)"))
            continue
        if c.get("ahead_by", 0) == 0:
            continue
        ours = fork_files(path, frm) if path in FORKS else set()
        files = {f["filename"]: f.get("patch", "") for f in c.get("files", [])}
        file_reasons = {}
        for f in files:
            full = f"{path}/{f}"
            why = []
            if f in ours:
                why.append("changed in our fork")
            why += [label for rx, label in AREAS if re.search(rx, full)]
            if why:
                file_reasons[f] = why
        for cm in c.get("commits", []):
            subject = cm["commit"]["message"].splitlines()[0]
            line = f"`{path}` {cm['sha'][:10]} {cm['commit']['committer']['date'][:10]} {subject}"
            kw = KEYWORDS.search(cm["commit"]["message"])
            if ROUTINE.search(subject) and not file_reasons and not kw:
                routine.append(line)
                continue
            # which flagged files this commit touches (one call per commit, only in projects
            # where the change touches a flagged file at all)
            why = set()
            if file_reasons:
                try:
                    touched = [f["filename"] for f in
                               gh_json(f"repos/{GH_ORG}/{n}/commits/{cm['sha']}").get("files", [])]
                except subprocess.CalledProcessError:
                    touched = list(file_reasons)
                why = {w for f in touched for w in file_reasons.get(f, [])}
            why = sorted(why)
            if kw:
                why.append(f"keyword '{kw.group(0)}'")
            if why:
                flags.append((f"commit:{cm['sha']}", f"{line} — {', '.join(why)}"))
            else:
                routine.append(line)
        for f, why in file_reasons.items():
            patches.append((f"{path}/{f} ({', '.join(why)})", files[f][:MAX_PATCH]))

    seen_path = f"{STATE}/watch-seen"
    try:
        seen = set(open(seen_path).read().split())
    except OSError:
        seen = set()
    fresh = [(k, t) for k, t in flags if k not in seen]

    stamp = date.today().isoformat()
    name = f"{stamp}-{mode}-{base}-to-{target}"
    rpath = f"{OUT}/{name}.md"
    report.append(f"# GrapheneOS {base} -> {target} ({mode}, {stamp})\n")
    report.append(f"Flagged: {len(flags)} ({len(fresh)} new since the last report). "
                  f"Routine: {len(routine)}.\n")
    report.append("## Flagged\n")
    report += [f"- {'**new** ' if (k, t) in fresh else ''}{t}" for k, t in flags] or ["- none"]
    report.append("\n## Routine\n")
    report += [f"- {t}" for t in routine] or ["- none"]
    if unchecked:
        report.append("\n## Not checked (not on GitHub or not comparable)\n")
        report += [f"- `{p}`" for p in unchecked]
    report.append("\n## Patches of flagged files\n")
    size = 0
    for head, patch in patches:
        if size > MAX_REPORT:
            report.append(f"\n(further patches left out; the report is capped)\n")
            break
        report.append(f"### {head}\n\n```diff\n{patch}\n```\n")
        size += len(patch)
    with open(rpath, "w") as f:
        f.write("\n".join(report) + "\n")

    review = None
    hook = f"{STATE}/review-hook"
    if flags and os.access(hook, os.X_OK) and (fresh or mode == "check"):
        try:
            out = subprocess.run([hook, rpath], capture_output=True, text=True, timeout=1800).stdout
            if out.strip():
                review = f"{OUT}/{name}-review.md"
                with open(review, "w") as f:
                    f.write(out)
        except subprocess.TimeoutExpired:
            pass

    print(rpath)
    if review:
        print(review)

    if mode == "preview":
        if fresh and os.environ.get("DRY_RUN") == "1":
            print(f"DRY_RUN: would notify about {len(fresh)} item(s)")
        elif fresh:
            msg = [f"os.ivan.gg: upstream preview, GrapheneOS {base} -> branch 17: "
                   f"{len(fresh)} new item(s) need a look before the next release."]
            msg += [f"- {t}" for _, t in fresh[:15]]
            if len(fresh) > 15:
                msg.append(f"... and {len(fresh) - 15} more")
            if review:
                msg.append("\n" + summary(review))
            msg.append(f"\nReport: {rpath}")
            if subprocess.run([NOTIFY, "\n".join(msg)[:3900]]).returncode == 0:
                with open(seen_path, "a") as f:
                    f.writelines(k + "\n" for k, _ in fresh)
        return 0
    return 10 if flags else 0


def summary(path):
    """The review up to its second heading (its summary section), for the notification."""
    text = open(path).read().strip()
    heads = [m.start() for m in re.finditer(r"^#{1,3} ", text, re.M)]
    return text[:heads[1] if len(heads) > 1 else len(text)][:2000].strip()


if __name__ == "__main__":
    sys.exit(main())
