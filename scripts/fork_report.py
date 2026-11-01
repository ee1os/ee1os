#!/usr/bin/env python3
"""The changes page of a stable release: each fork against the signed GrapheneOS tag, file by
file, every change explained by its group (patches/approved.txt + patches/changes.toml).

    fork_report.py --release <bn> --out <dir>   report of the tree as it is (each fork's HEAD,
                                                which must be envs-17): report.json,
                                                files-<bn>.tsv.gz, index.html
    fork_report.py --preview --out <dir>        the same, release "preview", for a look; the
                                                ee1os commit needn't be pushed
    fork_report.py --check <dir>                rebuild <dir>/report.json from the commits it
                                                records and compare byte for byte
    fork_report.py --index <site>/changes       write <site>/changes/index.html from */report.json

Status of a file comes from the two trees (path, mode, object id), never from adding up
commits; commits only say which groups changed a file. Fails, writing nothing, if a commit
isn't approved, a group has no text, a changed file has no commit, a note names a file its
group didn't change, the tag isn't signed by GrapheneOS or a fork isn't on the tag.
Python stdlib only; run with python3 -I. Doc 08, Fork report.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402

GENERATOR = "1"
WS = "/mnt/flash/scratch/grapheneos"
TREE = WS + "/grapheneos-17"
ENVS = "/mnt/flash/home/faeton/work/ee1os/os"
GIT_ENV = {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C"}


class ReportError(Exception):
    pass


@dataclass(frozen=True)
class Fork:
    path: str     # path in the tree, e.g. frameworks/base
    name: str     # repo name, e.g. platform_frameworks_base
    gitdir: str   # the checkout
    commit: str   # the release commit


def run(args, cwd=None, input=None, check=True):
    env = dict(os.environ, **GIT_ENV)
    p = subprocess.run(args, cwd=cwd, env=env, input=input, capture_output=True)
    if check and p.returncode:
        raise ReportError(f"{' '.join(args[:4])}: {p.stderr.decode(errors='replace').strip()}")
    return p


def git(d, *args, **kw):
    return run(["git", "-C", d, *args], **kw).stdout


def decode(b):
    return b.decode("utf-8", errors="surrogateescape")


def c_quote(path):
    """A path the way git prints it with core.quotePath: as is, or in double quotes with C
    escapes and octal for control and non-ASCII bytes."""
    raw = path.encode("utf-8", errors="surrogateescape")
    if all(0x20 <= b < 0x7f and b not in (0x22, 0x5c) for b in raw):
        return path
    esc = {0x07: "\\a", 0x08: "\\b", 0x09: "\\t", 0x0a: "\\n", 0x0b: "\\v", 0x0c: "\\f",
           0x0d: "\\r", 0x22: '\\"', 0x5c: "\\\\"}
    return '"' + "".join(esc.get(b) or (chr(b) if 0x20 <= b < 0x7f else f"\\{b:03o}")
                         for b in raw) + '"'


def c_unquote(s):
    if not (len(s) >= 2 and s[0] == s[-1] == '"'):
        return s
    out, i, s = bytearray(), 0, s[1:-1]
    simple = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}
    while i < len(s):
        if s[i] == "\\":
            if s[i + 1] in simple:
                out.append(simple[s[i + 1]]); i += 2
            else:
                out.append(int(s[i + 1:i + 4], 8)); i += 4
        else:
            out += s[i].encode(); i += 1
    return decode(bytes(out))


def ls_tree(d, rev):
    """{path: (mode, type, oid)}"""
    out = {}
    for e in git(d, "ls-tree", "-r", "-z", "--full-tree", rev).split(b"\0"):
        if e:
            meta, path = e.split(b"\t", 1)
            mode, typ, oid = meta.decode().split()
            out[decode(path)] = (mode, typ, oid)
    return out


def numstat(d, a, b):
    """{path: (added, deleted)}, None for a binary file"""
    out = {}
    for e in git(d, "diff", "--numstat", "-z", "--no-renames", a, b).split(b"\0"):
        if e:
            ad, de, path = e.split(b"\t", 2)
            out[decode(path)] = (None, None) if ad == b"-" else (int(ad), int(de))
    return out


class Blobs:
    """Sizes and SHA-256 of blobs, the SHA-256 cached by object id (it never changes)."""

    def __init__(self, d, cache):
        self.d, self.cache = d, cache

    def _cache_path(self, oid):
        return os.path.join(self.cache, oid[:2], oid)

    def sizes(self, oids):
        if not oids:
            return {}
        out = git(self.d, "cat-file", "--batch-check=%(objectname) %(objectsize)",
                  input="".join(o + "\n" for o in oids).encode())
        return {o: int(s) for o, s in (l.split() for l in out.decode().splitlines())}

    def sha256(self, oids):
        res, todo = {}, []
        for o in sorted(set(oids)):
            try:
                with open(self._cache_path(o)) as f:
                    res[o] = f.read().strip()
            except OSError:
                todo.append(o)
        if todo:
            p = subprocess.Popen(["git", "-C", self.d, "cat-file", "--batch"], env=dict(os.environ, **GIT_ENV),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            # requests from a thread: cat-file stops reading while its output isn't read
            def feed():
                p.stdin.write("".join(o + "\n" for o in todo).encode())
                p.stdin.close()
            import threading
            feeder = threading.Thread(target=feed, daemon=True)
            feeder.start()
            for o in todo:
                head = p.stdout.readline().split()
                if len(head) != 3 or head[1] != b"blob":
                    p.kill()
                    raise ReportError(f"{self.d}: can't read object {o}")
                size = int(head[2])
                h, left = hashlib.sha256(), size
                while left:
                    chunk = p.stdout.read(min(left, 1 << 20))
                    h.update(chunk); left -= len(chunk)
                p.stdout.read(1)
                res[o] = h.hexdigest()
                os.makedirs(os.path.dirname(self._cache_path(o)), exist_ok=True)
                tmp = self._cache_path(o) + ".tmp"
                with open(tmp, "w") as f:
                    f.write(res[o] + "\n")
                os.replace(tmp, self._cache_path(o))
            feeder.join()
            p.stdout.close()
            if p.wait():
                raise ReportError(f"{self.d}: git cat-file --batch failed")
        return res


def patch_id(forks_sh, d, c):
    return run(["bash", "-c", 'source "$1"; patch_id "$2" "$3"', "_", forks_sh, d, c]).stdout.decode().strip()


def build_report(*, forks, tag, release, approved_text, changes_toml, os_commit, allowed_signers,
                 sha_cache, forks_sh, extras):
    """(report dict, TSV rows) for these forks against the upstream tag."""
    approvals, errors = ledger.parse_approved(approved_text)
    groups, gerr = ledger.load_groups(changes_toml)
    errors += gerr + ledger.check(approvals, groups)
    if errors:
        raise ReportError("; ".join(errors))
    by_id = {(a.repo, a.patch_id): a for a in approvals}

    rep_forks, rows, file_groups, touched, commits_of = [], [], {}, {}, {}
    totals = dict(files=0, changed=0, modified=0, added=0, deleted=0, identical=0)
    changed_files = {}   # (repo, path) -> file record
    for fk in forks:
        d = fk.gitdir
        r = run(["git", "-C", d, "-c", f"gpg.ssh.allowedSignersFile={allowed_signers}",
                 "verify-tag", f"refs/tags/{tag}"], check=False)
        if r.returncode:
            raise ReportError(f"{fk.path}: tag {tag} missing or not signed by GrapheneOS")
        base = git(d, "rev-parse", f"refs/tags/{tag}^{{commit}}").decode().strip()
        commit = git(d, "rev-parse", f"{fk.commit}^{{commit}}").decode().strip()
        if run(["git", "-C", d, "merge-base", "--is-ancestor", base, commit], check=False).returncode:
            raise ReportError(f"{fk.path}: {commit[:12]} isn't on {tag}")
        old, new = ls_tree(d, base), ls_tree(d, commit)
        stats = numstat(d, base, commit)
        changed = sorted(p for p in set(old) | set(new) if old.get(p, (None,) * 3)[0::2] != new.get(p, (None,) * 3)[0::2])
        changed_set = set(changed)

        # commits -> approvals -> groups; files each commit touched
        by_path = {}
        for c in git(d, "rev-list", "--reverse", f"{base}..{commit}").decode().split():
            pid = patch_id(forks_sh, d, c)
            subject = git(d, "log", "-1", "--format=%s", c).decode().strip()
            a = by_id.get((fk.name, pid))
            if a is None:
                raise ReportError(f"{fk.path}: commit {c[:12]} not approved: {subject}")
            commits_of.setdefault(a.group, []).append(
                {"repo": fk.name, "sha": c, "patch_id": pid, "subject": subject})
            names = git(d, "diff-tree", "-r", "-z", "--root", "--no-commit-id", "--name-only",
                        "--no-renames", c).split(b"\0")
            for p in (decode(n) for n in names if n):
                by_path.setdefault(p, [])
                if a.group not in by_path[p]:
                    by_path[p].append(a.group)

        blobs = Blobs(d, sha_cache)
        all_oids = [v[2] for v in list(old.values()) + list(new.values()) if v[1] == "blob"]
        sha = blobs.sha256(all_oids)
        sizes = blobs.sizes(sorted({v[2] for p in changed for v in (old.get(p), new.get(p))
                                    if v and v[1] == "blob"}))
        counts = dict(modified=0, added=0, deleted=0)
        for p in changed:
            o, n = old.get(p), new.get(p)
            status = "added" if o is None else "deleted" if n is None else "modified"
            counts[status] += 1
            gs = by_path.get(p)
            if not gs:
                raise ReportError(f"{fk.path}: {p} differs from {tag} but no commit changed it")
            ad, de = stats.get(p, (0, 0))
            changed_files[(fk.name, p)] = rec = {
                "repo": fk.name, "project": fk.path, "path": p, "status": status,
                "mode_old": o and o[0], "mode_new": n and n[0],
                "oid_old": o and o[2], "oid_new": n and n[2],
                "sha256_old": o and sha.get(o[2]), "sha256_new": n and sha.get(n[2]),
                "size_old": o and sizes.get(o[2]), "size_new": n and sizes.get(n[2]),
                "added": ad, "deleted": de, "notes": []}
            file_groups[(fk.name, p)] = gs
        for p, gs in by_path.items():
            if p not in changed_set:
                for g in gs:
                    touched.setdefault(g, []).append({"repo": fk.name, "path": p})

        for p in sorted(set(old) | set(new)):
            o, n = old.get(p), new.get(p)
            if p not in changed_set:
                rows.append([fk.name, c_quote(p), n[0], n[2], sha.get(n[2], "-"), "identical", "=", "="])
            else:
                st = changed_files[(fk.name, p)]["status"]
                rows.append([fk.name, c_quote(p), n[0] if n else "-", n[2] if n else "-",
                             sha.get(n[2], "-") if n else "-", st,
                             o[2] if o else "-", sha.get(o[2], "-") if o else "-"])
        n_files = len(new)
        totals["files"] += n_files
        totals["changed"] += len(changed)
        totals["identical"] += n_files - counts["modified"] - counts["added"]
        for k in counts:
            totals[k] += counts[k]
        rep_forks.append({
            "path": fk.path, "name": fk.name, "upstream_commit": base,
            "upstream_tree": git(d, "rev-parse", f"{base}^{{tree}}").decode().strip(),
            "commit": commit, "tree": git(d, "rev-parse", f"{commit}^{{tree}}").decode().strip(),
            "files": n_files, "changed": len(changed), **counts})
    totals["other_projects"] = extras.get("other_projects", 0)

    # groups, by order; notes onto files
    out_groups = []
    for slug, g in sorted(groups.items(), key=lambda kv: (kv[1].order, kv[0])):
        files = []
        for key in sorted(k for k, gs in file_groups.items() if slug in gs):
            rec = dict(changed_files[key])
            rec["also_in"] = [x for x in file_groups[key] if x != slug]
            files.append(rec)
        for spec, text in sorted(g.notes.items()):
            proj, _, path = spec.partition(":")
            hit = [f for f in files if f["project"] == proj and f["path"] == path]
            if not hit:
                raise ReportError(f"changes.toml: note on {spec} in group {slug}, but the group "
                                  f"didn't change that file")
            hit[0]["notes"] = [text]
        out_groups.append({
            "slug": slug, "order": g.order, "title": g.title, "what": g.what, "why": g.why,
            "docs": g.docs, "commits": commits_of.get(slug, []), "files": files,
            "touched": sorted(touched.get(slug, []), key=lambda t: (t["repo"], t["path"]))})

    report = {
        "generator": GENERATOR, "release": release,
        "upstream": {"tag": tag, "signer_checked": True},
        "manifest": extras.get("manifest", {}), "envs_xml_sha256": extras.get("envs_xml_sha256"),
        "vendor": extras.get("vendor", []), "os_commit": os_commit,
        "forks": rep_forks, "totals": totals, "groups": out_groups,
        "downloads": {"tsv": f"files-{release}.tsv.gz"}}
    return report, rows


def write_outputs(report, rows, out):
    """report.json, index.html and files-<release>.tsv.gz into out."""
    buf = io.StringIO()
    buf.write("repo\tpath\tmode\toid\tsha256\tstatus\tupstream_oid\tupstream_sha256\n")
    for r in sorted(rows, key=lambda r: (r[0], c_unquote(r[1]).encode("utf-8", "surrogateescape"))):
        buf.write("\t".join(r) + "\n")
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="", compresslevel=9) as z:
        z.write(buf.getvalue().encode("utf-8", errors="surrogateescape"))
    tsv = raw.getvalue()
    report["downloads"]["tsv_sha256"] = hashlib.sha256(tsv).hexdigest()
    os.makedirs(out, exist_ok=True)
    files = {report["downloads"]["tsv"]: tsv,
             "report.json": (json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False)
                             + "\n").encode("utf-8", errors="surrogateescape")}
    import fork_report_html
    files["index.html"] = fork_report_html.render_release(report).encode("utf-8", errors="surrogateescape")
    for name, data in files.items():
        tmp = os.path.join(out, name + ".tmp")
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, os.path.join(out, name))


# ---- the real tree ----

def tree_forks(forks_sh):
    out = run(["bash", "-c", 'source "$1"; printf "%s\\n" "${FORKS[@]}"', "_", forks_sh]).stdout
    return [tuple(l.split(":", 1)) for l in out.decode().split()]


def tree_inputs(tag, os_commit):
    """extras for the real tree: manifest, envs.xml (as at os_commit), vendor modules, other
    projects."""
    m = TREE + "/.repo/manifests"
    default = git(m, "show", f"refs/tags/{tag}:default.xml")
    import xml.etree.ElementTree as ET
    n_projects = sum(1 for _ in ET.fromstring(default).iter("project"))
    envs = hashlib.sha256(git(ENVS, "show", f"{os_commit}:scripts/envs-local-manifest.xml")).hexdigest()
    vendor = []
    vd = WS + "/state/vendor"
    for model in sorted(os.listdir(TREE + "/vendor/google_devices")):
        kv = {}
        with open(os.path.join(vd, model)) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                kv[k] = v
        image, _, image_sha = kv.get("image", "").partition(" ")
        vendor.append({"model": model, "adevtool": kv.get("adevtool"), "image": image,
                       "image_sha256": image_sha, "module_hash": kv.get("tree")})
    return {"manifest": {"commit": git(m, "rev-parse", f"refs/tags/{tag}^{{commit}}").decode().strip(),
                         "default_xml_sha256": hashlib.sha256(default).hexdigest()},
            "envs_xml_sha256": envs, "vendor": vendor, "n_projects": n_projects}


def report_for(release, *, os_commit, commits=None, need_pushed=True, tag=None, record=None):
    """record: a published report.json being checked. Its vendor lines are taken as recorded
    (the modules aren't in git; they are regenerated for later tags), and every blob is hashed
    afresh instead of read from the cache."""
    forks_sh = ENVS + "/scripts/forks.sh"
    tag = tag or open(WS + "/state/upstream-tag").read().strip()
    if need_pushed:
        git(ENVS, "fetch", "-q", "origin")
        if run(["git", "-C", ENVS, "merge-base", "--is-ancestor", os_commit, "origin/main"],
               check=False).returncode:
            raise ReportError(f"ee1os commit {os_commit[:12]} isn't on github.com/ee1os/ee1os "
                              f"(origin/main); push it first")
    forks = []
    for path, name in tree_forks(forks_sh):
        d = os.path.join(TREE, path)
        if commits:
            c = commits[name]
        else:
            if git(d, "symbolic-ref", "-q", "HEAD").decode().strip() != "refs/heads/envs-17":
                raise ReportError(f"{path}: HEAD isn't the envs-17 branch")
            c = git(d, "rev-parse", "HEAD").decode().strip()
        forks.append(Fork(path, name, d, c))
    extras = tree_inputs(tag, os_commit)
    extras["other_projects"] = extras.pop("n_projects") - len(forks)
    cache = WS + "/state/sha256"
    if record is not None:
        extras["vendor"] = record.get("vendor", [])
        cache = tempfile.mkdtemp(prefix="fork-report-check-", dir=WS + "/state")
    try:
        return build_report(
            forks=forks, tag=tag, release=release,
            approved_text=git(ENVS, "show", f"{os_commit}:patches/approved.txt").decode(),
            changes_toml=git(ENVS, "show", f"{os_commit}:patches/changes.toml"),
            os_commit=os_commit, allowed_signers=ENVS + "/scripts/grapheneos-allowed-signers",
            sha_cache=cache, forks_sh=forks_sh, extras=extras)
    finally:
        if record is not None:
            shutil.rmtree(cache, ignore_errors=True)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--release")
    g.add_argument("--preview", action="store_true")
    g.add_argument("--check", metavar="DIR")
    g.add_argument("--index", metavar="DIR")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    try:
        if a.index:
            import fork_report_html
            reports = []
            for d in sorted(os.listdir(a.index)):
                p = os.path.join(a.index, d, "report.json")
                if os.path.isfile(p):
                    with open(p, encoding="utf-8") as f:
                        reports.append(json.load(f))
            with open(os.path.join(a.index, "index.html"), "w", encoding="utf-8") as f:
                f.write(fork_report_html.render_index(reports))
            return 0
        if a.check:
            with open(os.path.join(a.check, "report.json"), "rb") as f:
                old = f.read()
            rec = json.loads(old)
            if rec.get("generator") != GENERATOR:
                raise ReportError(f"made by generator {rec.get('generator')}, this is {GENERATOR}")
            report, rows = report_for(rec["release"], os_commit=rec["os_commit"], need_pushed=False,
                                      commits={f["name"]: f["commit"] for f in rec["forks"]},
                                      tag=rec["upstream"]["tag"], record=rec)
            tmp = os.path.join(a.check, ".check")
            write_outputs(report, rows, tmp)
            with open(os.path.join(tmp, "report.json"), "rb") as f:
                new = f.read()
            subprocess.run(["rm", "-rf", tmp])
            if new != old:
                print("FAIL: report.json differs from a rebuild")
                return 1
            print("report.json matches a rebuild")
            return 0
        if not a.out:
            ap.error("--out is required")
        os_commit = git(ENVS, "rev-parse", "HEAD").decode().strip()
        if a.release and run(["git", "-C", ENVS, "status", "--porcelain", "--", "patches", "scripts"]).stdout:
            raise ReportError("ee1os has uncommitted changes in patches/ or scripts/")
        report, rows = report_for(a.release or "preview", os_commit=os_commit,
                                  need_pushed=not a.preview)
        write_outputs(report, rows, a.out)
        t = report["totals"]
        print(f"{report['release']}: {t['changed']} files changed ({t['modified']} modified, "
              f"{t['added']} added, {t['deleted']} deleted) of {t['files']} in "
              f"{len(report['forks'])} projects -> {a.out}")
        return 0
    except ReportError as e:
        print(f"FAIL: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
