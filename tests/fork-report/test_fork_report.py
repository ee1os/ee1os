import gzip
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fixtures  # noqa: E402
from fixtures import git, TAG  # noqa: E402

sys.path.insert(0, fixtures.SCRIPTS)
import fork_report  # noqa: E402

BIN = bytes(range(256)) * 4
ODD = ["a b.txt", "tab\tname.txt", "ünï.txt", "<x>.txt"]


class Base(unittest.TestCase):
    """Two forks. base: modify, add, delete, mode-only, binary, a file in two groups, a change
    that is reverted. app: odd paths."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", self.tmp])
        fixtures.signing_key(self.tmp)
        b = fixtures.Fork(self.tmp, "frameworks/base", "platform_frameworks_base",
                          {"keep.txt": "same\n", "mod.java": "a\nb\n", "gone.txt": "bye\n",
                           "run.sh": "echo\n", "img.bin": BIN, "two.mk": "x\n", "back.txt": "v1\n"})
        b.change("reboot", "Change mod and two", {"mod.java": "a\nB\nc\n", "two.mk": "x\ny\n"})
        b.change("look", "Add and delete", {"new.txt": "new\n", "two.mk": "x\ny\nz\n"},
                 delete=["gone.txt"])
        b.change("look", "Make run executable", chmod=["run.sh"])
        b.change("look", "New image", {"img.bin": BIN[::-1]})
        b.change("reboot", "Touch back", {"back.txt": "v2\n"})
        b.change("reboot", "Restore back", {"back.txt": "v1\n"})
        a = fixtures.Fork(self.tmp, "packages/apps/Settings", "platform_packages_apps_Settings",
                          {"res/a.xml": "<a/>\n"})
        a.change("look", "Odd names", {p: p + "\n" for p in ODD})
        self.base, self.app = b, a
        self.groups = fixtures.toml("reboot", "look")

    def forks(self):
        return [fork_report.Fork(f.path, f.name, f.dir, f.head()) for f in (self.base, self.app)]

    def build(self, approved=None, groups=None, signers=None, cache=None):
        approved = self.base.approved() + self.app.approved() if approved is None else approved
        return fork_report.build_report(
            forks=self.forks(), tag=TAG, release="2026103010", approved_text=approved,
            changes_toml=self.groups if groups is None else groups, os_commit="0" * 40,
            allowed_signers=signers or os.path.join(self.tmp, "allowed_signers"),
            sha_cache=cache or os.path.join(self.tmp, "cache"), forks_sh=fixtures.FORKS_SH,
            extras={"manifest": {"commit": "1" * 40, "default_xml_sha256": "2" * 64},
                    "envs_xml_sha256": "3" * 64, "vendor": [], "other_projects": 7})

    def files(self, report):
        out = {}
        for g in report["groups"]:
            for f in g["files"]:
                out.setdefault((f["repo"], f["path"]), f)
        return out


class Report(Base):
    def test_counts_and_status(self):
        r, _ = self.build()
        t = r["totals"]
        # base: mod.java two.mk run.sh img.bin modified, new.txt added, gone.txt deleted; app: 4 added
        self.assertEqual((t["modified"], t["added"], t["deleted"], t["changed"]), (4, 5, 1, 10))
        self.assertEqual(t["files"], 7 + 5)   # files on our side: base 7, app 5
        self.assertEqual(t["identical"], 2 + 1)   # keep.txt back.txt, res/a.xml
        self.assertEqual(t["other_projects"], 7)
        st = {k[1]: f["status"] for k, f in self.files(r).items()}
        self.assertEqual(st["gone.txt"], "deleted")
        self.assertEqual(st["new.txt"], "added")
        self.assertEqual(st["mod.java"], "modified")
        fb = r["forks"][0]
        self.assertEqual(fb["tree"], git(self.base.dir, "rev-parse", "HEAD^{tree}").strip())
        self.assertEqual(fb["upstream_tree"], git(self.base.dir, "rev-parse", TAG + "^{tree}").strip())
        self.assertEqual((fb["files"], fb["changed"]), (7, 6))

    def test_hashes(self):
        r, _ = self.build()
        f = self.files(r)[("platform_frameworks_base", "mod.java")]
        self.assertEqual(f["oid_new"], git(self.base.dir, "rev-parse", "HEAD:mod.java").strip())
        self.assertEqual(f["oid_old"], git(self.base.dir, "rev-parse", TAG + ":mod.java").strip())
        self.assertEqual(f["sha256_new"], hashlib.sha256(b"a\nB\nc\n").hexdigest())
        self.assertEqual(f["sha256_old"], hashlib.sha256(b"a\nb\n").hexdigest())
        self.assertEqual((f["size_old"], f["size_new"], f["added"], f["deleted"]), (4, 6, 2, 1))
        g = self.files(r)[("platform_frameworks_base", "gone.txt")]
        self.assertEqual((g["oid_new"], g["sha256_new"], g["size_new"]), (None, None, None))

    def test_mode_only(self):
        r, _ = self.build()
        f = self.files(r)[("platform_frameworks_base", "run.sh")]
        self.assertEqual((f["status"], f["mode_old"], f["mode_new"]), ("modified", "100644", "100755"))
        self.assertEqual(f["oid_old"], f["oid_new"])
        self.assertEqual((f["added"], f["deleted"]), (0, 0))

    def test_binary(self):
        r, _ = self.build()
        f = self.files(r)[("platform_frameworks_base", "img.bin")]
        self.assertEqual((f["added"], f["deleted"]), (None, None))
        self.assertEqual((f["size_old"], f["size_new"]), (1024, 1024))

    def test_revert_is_no_net_change(self):
        r, _ = self.build()
        self.assertNotIn(("platform_frameworks_base", "back.txt"), self.files(r))
        reboot = next(g for g in r["groups"] if g["slug"] == "reboot")
        self.assertIn({"repo": "platform_frameworks_base", "path": "back.txt"}, reboot["touched"])

    def test_file_in_two_groups(self):
        r, _ = self.build()
        by = {g["slug"]: g for g in r["groups"]}
        two = [f for g in by.values() for f in g["files"] if f["path"] == "two.mk"]
        self.assertEqual(len(two), 2)
        self.assertEqual(sorted(f["also_in"] for f in two), [["look"], ["reboot"]])
        self.assertEqual(r["totals"]["changed"], 10)
        self.assertEqual([g["slug"] for g in r["groups"]], ["reboot", "look"])   # by order
        self.assertEqual([c["subject"] for c in by["reboot"]["commits"]],
                         ["Change mod and two", "Touch back", "Restore back"])

    def test_note_attached_and_stale_note_fails(self):
        g = self.groups + b'\n[groups.look.notes]\n"frameworks/base:new.txt" = "Explained."\n'
        r, _ = self.build(groups=g)
        self.assertEqual(self.files(r)[("platform_frameworks_base", "new.txt")]["notes"], ["Explained."])
        bad = self.groups + b'\n[groups.look.notes]\n"frameworks/base:keep.txt" = "Stale."\n'
        with self.assertRaisesRegex(fork_report.ReportError, "keep.txt"):
            self.build(groups=bad)

    def test_unapproved_commit_fails(self):
        skip = {self.base.commits[2][0]}
        with self.assertRaisesRegex(fork_report.ReportError, "not approved.*Make run executable"):
            self.build(approved=self.base.approved(skip) + self.app.approved())

    def test_missing_prose_fails(self):
        with self.assertRaisesRegex(fork_report.ReportError, "look"):
            self.build(groups=fixtures.toml("reboot"))

    def test_unsigned_tag_fails(self):
        u = fixtures.Fork(self.tmp, "system/sepolicy", "platform_system_sepolicy", {"a": "a\n"},
                          signed=False)
        u.change("look", "x", {"a": "b\n"})
        with self.assertRaisesRegex(fork_report.ReportError, "system/sepolicy.*sign"):
            fork_report.build_report(
                forks=[fork_report.Fork(u.path, u.name, u.dir, u.head())], tag=TAG, release="1",
                approved_text=u.approved(), changes_toml=fixtures.toml("look"), os_commit="0" * 40,
                allowed_signers=os.path.join(self.tmp, "allowed_signers"),
                sha_cache=os.path.join(self.tmp, "cache"), forks_sh=fixtures.FORKS_SH,
                extras={"manifest": {}, "envs_xml_sha256": "", "vendor": [], "other_projects": 0})

    def test_fork_not_on_tag_fails(self):
        git(self.base.dir, "checkout", "-q", "--orphan", "other")
        fixtures.commit(self.base.dir, "unrelated")
        with self.assertRaisesRegex(fork_report.ReportError, "isn't on"):
            self.build()


class ManyBlobs(unittest.TestCase):
    def test_many_blobs_no_deadlock(self):
        import signal
        tmp = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", tmp])
        fixtures.signing_key(tmp)
        f = fixtures.Fork(tmp, "build/make", "platform_build",
                          {f"d/{i}.txt": f"{i}\n" * 50 for i in range(4000)})
        f.change("look", "One", {"d/1.txt": "x\n"})
        signal.signal(signal.SIGALRM, lambda *a: (_ for _ in ()).throw(TimeoutError("hung")))
        signal.alarm(60)
        try:
            r, rows = fork_report.build_report(
                forks=[fork_report.Fork(f.path, f.name, f.dir, f.head())], tag=TAG, release="1",
                approved_text=f.approved(), changes_toml=fixtures.toml("look"), os_commit="0" * 40,
                allowed_signers=os.path.join(tmp, "allowed_signers"),
                sha_cache=os.path.join(tmp, "cache"), forks_sh=fixtures.FORKS_SH,
                extras={"manifest": {}, "envs_xml_sha256": "", "vendor": [], "other_projects": 0})
        finally:
            signal.alarm(0)
        self.assertEqual(r["totals"]["files"], 4000)


class Outputs(Base):
    def write(self, out, cache=None):
        r, rows = self.build(cache=cache)
        fork_report.write_outputs(r, rows, out)
        with open(os.path.join(out, "report.json"), "rb") as f:
            j = f.read()
        with open(os.path.join(out, "files-2026103010.tsv.gz"), "rb") as f:
            t = f.read()
        return j, t

    def test_tsv_rows_and_sha(self):
        out = os.path.join(self.tmp, "out")
        j, t = self.write(out)
        rep = json.loads(j)
        self.assertEqual(rep["downloads"]["tsv_sha256"], hashlib.sha256(t).hexdigest())
        lines = gzip.decompress(t).decode().splitlines()
        self.assertEqual(lines[0].split("\t"), ["repo", "path", "mode", "oid", "sha256", "status",
                                                "upstream_oid", "upstream_sha256"])
        rows = {tuple(l.split("\t")[:2]): l.split("\t") for l in lines[1:]}
        keep = rows[("platform_frameworks_base", "keep.txt")]
        self.assertEqual(keep[5:], ["identical", "=", "="])
        self.assertEqual(keep[4], hashlib.sha256(b"same\n").hexdigest())
        gone = rows[("platform_frameworks_base", "gone.txt")]
        self.assertEqual(gone[2:6], ["-", "-", "-", "deleted"])
        self.assertEqual(len(lines) - 1, 13)   # 12 files on our side + 1 deleted

    def test_odd_paths(self):
        out = os.path.join(self.tmp, "out")
        _, t = self.write(out)
        paths = {fork_report.c_unquote(l.split("\t")[1])
                 for l in gzip.decompress(t).decode().splitlines()[1:]}
        for p in ODD:
            self.assertIn(p, paths)
        self.assertEqual(fork_report.c_quote("tab\tname.txt"), '"tab\\tname.txt"')
        self.assertEqual(fork_report.c_quote("a b.txt"), "a b.txt")
        self.assertEqual(fork_report.c_quote("ünï.txt"), '"\\303\\274n\\303\\257.txt"')

    def test_deterministic(self):
        a = self.write(os.path.join(self.tmp, "o1"))
        b = self.write(os.path.join(self.tmp, "o2"))
        self.assertEqual(a, b)

    def test_sha_cache_used(self):
        cache = os.path.join(self.tmp, "c")
        self.write(os.path.join(self.tmp, "o1"), cache)
        before = sorted(os.path.join(d, f) for d, _, fs in os.walk(cache) for f in fs)
        self.assertTrue(before)
        # a poisoned cache entry shows the second run read the cache instead of hashing
        oid = git(self.base.dir, "rev-parse", "HEAD:keep.txt").strip()
        with open(os.path.join(cache, oid[:2], oid), "w") as f:
            f.write("f" * 64)
        r, _ = self.build(cache=cache)
        _, t = self.write(os.path.join(self.tmp, "o2"), cache)
        keep = [l for l in gzip.decompress(t).decode().splitlines() if "\tkeep.txt\t" in l][0]
        self.assertEqual(keep.split("\t")[4], "f" * 64)


if __name__ == "__main__":
    unittest.main()
