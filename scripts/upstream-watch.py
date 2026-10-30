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
the report as <report>-review.md. preview notifies klava hq (OS topic) only about flags not seen before.
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
TOPIC = "890"     # klava hq, "OS" topic
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
    # a release held for the owner is already on envs-17: preview from there, not from the last push
    try:
        held = open(f"{STATE}/held-tag").read().strip()
    except OSError:
        held = ""
    if mode == "preview" and held:
        base = held
    target = "17" if mode == "preview" else sys.argv[2]

    old, old_aosp = manifest(base)
    new, new_aosp = manifest(target)

    flags = []      # (key, text, short) strategic findings; key identifies it across runs,
                    # short is the line for the notification
    report = []     # markdown lines
    patches = []    # (heading, patch) for flagged files
    routine = []

    if old_aosp != new_aosp:
        flags.append((f"aosp:{new_aosp}", f"AOSP base changes: {old_aosp} -> {new_aosp}",
                      f"new AOSP base {new_aosp}"))
    for n in sorted(set(new) - set(old)):
        flags.append((f"added:{n}", f"new project {new[n][0]} ({n}, {new[n][2]})",
                      f"new project {new[n][0]}"))
    for n in sorted(set(old) - set(new)):
        flags.append((f"removed:{n}", f"project removed: {old[n][0]} ({n})",
                      f"project removed: {old[n][0]}"))

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
                          f"`{path}` can't be compared with our base (history rewritten?)",
                          f"{short(path)}: can't be compared, history rewritten?"))
            continue
        status = c.get("status")
        if status == "identical":
            continue
        if status in ("behind", "diverged"):
            # upstream went back or rewrote history: whatever it dropped isn't in the commit list
            flags.append((f"{status}:{n}:{rev}",
                          f"`{path}` is {status} our base ({c.get('behind_by', 0)} commit(s) gone)",
                          f"{short(path)}: upstream rewrote history, "
                          f"{c.get('behind_by', 0)} commit(s) dropped"))
            if c.get("ahead_by", 0) == 0:
                continue
        if c.get("total_commits", 0) > len(c.get("commits", [])) or len(c.get("files", [])) >= 300:
            # past GitHub's compare limits (250 commits, 300 files) a flagged file can hide
            flags.append((f"toolarge:{n}:{rev}",
                          f"`{path}`: {c.get('total_commits')} commits, {len(c.get('files', []))} "
                          f"files, too large to check here",
                          f"{short(path)}: {c.get('total_commits')} commits, too many to check"))
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
                flags.append((f"commit:{cm['sha']}", f"{line} — {', '.join(why)}",
                              f"{short(path)}: {subject} [{', '.join(why)}]"))
            else:
                routine.append(line)
        for f, why in file_reasons.items():
            patches.append((f"{path}/{f} ({', '.join(why)})", files[f][:MAX_PATCH]))

    seen_path = f"{STATE}/watch-seen"
    try:
        seen = set(open(seen_path).read().split())
    except OSError:
        seen = set()
    fresh = [f for f in flags if f[0] not in seen]

    stamp = date.today().isoformat()
    name = f"{stamp}-{mode}-{base}-to-{target}"
    rpath = f"{OUT}/{name}.md"
    report.append(f"# GrapheneOS {base} -> {target} ({mode}, {stamp})\n")
    if mode == "preview" and held:
        report.append(f"Base {held} is a release held for the owner's approval; it is already on "
                      f"envs-17 in the forks, not pushed yet.\n")
    report.append(f"Flagged: {len(flags)} ({len(fresh)} new since the last report). "
                  f"Routine: {len(routine)}.\n")
    report.append("## Flagged\n")
    report += [f"- {'**new** ' if f in fresh else ''}{f[1]}" for f in flags] or ["- none"]
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
            msg = notification(fresh, base, held, review, rpath)
            if subprocess.run([NOTIFY, msg, TOPIC]).returncode == 0:
                with open(seen_path, "a") as f:
                    f.writelines(k + "\n" for k, _, _ in fresh)
        return 0
    return 10 if flags else 0


def short(path):
    return path.removeprefix("packages/apps/")


VERDICTS = {
    "decision": "⚠️ Your decision needed before the next release",
    "test": "🧪 Safe to take, but test before the next release",
    "none": "✅ Nothing to do",
}


def notification(fresh, base, held, review, rpath):
    """Plain-text Telegram message: verdict first, then what to do, then what changed."""
    verdict, todo, notes = None, [], []
    if review:
        # the review's summary: "Verdict: ..." and "To do: ..." lines, then a few notes
        text = open(review).read().replace("`", "")
        heads = [m.start() for m in re.finditer(r"^#{1,3} ", text, re.M)]
        for line in text[:heads[1] if len(heads) > 1 else len(text)].splitlines()[1:]:
            line = line.strip().lstrip("-• ").strip()
            if m := re.match(r"verdict:\s*(\w+)", line, re.I):
                verdict = m.group(1).lower()
            elif m := re.match(r"to ?do:\s*(.+)", line, re.I):
                todo.append(m.group(1))
            elif line:
                notes.append(line)
    head = VERDICTS.get(verdict, "👀 New upstream changes, not reviewed yet: please look")
    msg = [f"ee1os · upstream watch", head, "",
           f"GrapheneOS's dev branch moved past {base}: {len(fresh)} new change(s) "
           f"in areas we care about."]
    if todo:
        msg += ["", "To do:"] + [f"• {t}" for t in todo]
    msg += ["", "What changed:"] + [f"• {sh}" for _, _, sh in fresh[:10]]
    if len(fresh) > 10:
        msg.append(f"• … and {len(fresh) - 10} more")
    if notes:
        msg += ["", "Review:"] + [f"• {n}" for n in notes[:6]]
    if held:
        msg += ["", f"⏸ Release {held} is still waiting for you. In ~/work/ee1os/os on n5:",
                f"APPROVE={held} scripts/track-upstream.sh  (push it)",
                f"SKIP={held} scripts/track-upstream.sh  (drop it)"]
    msg += ["", f"Details: {review or rpath}"]
    out = "\n".join(msg)
    return out if len(out) <= 3900 else out[:3890] + "\n…"


if __name__ == "__main__":
    sys.exit(main())
