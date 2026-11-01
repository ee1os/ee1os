"""--check on the real tree (skipped where there is none): it rebuilds from what report.json
records, so live state that git doesn't hold (vendor modules) can't make it fail, and a wrong
hash in the record does."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "fork_report.py"))
TREE = "/mnt/flash/scratch/grapheneos/grapheneos-17"


@unittest.skipUnless(os.path.isdir(TREE + "/frameworks/base/.git") or os.path.isdir(TREE + "/frameworks/base"),
                     "no build tree")
class Check(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(dir="/mnt/flash/scratch/tmp")
        cls.out = os.path.join(cls.tmp, "r")
        r = subprocess.run([sys.executable, "-I", SCRIPT, "--preview", "--out", cls.out],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def check(self, edit):
        d = tempfile.mkdtemp(dir=self.tmp)
        shutil.copy(os.path.join(self.out, "report.json"), d)
        p = os.path.join(d, "report.json")
        with open(p) as f:
            rep = json.load(f)
        edit(rep)
        with open(p, "w") as f:
            f.write(json.dumps(rep, sort_keys=True, indent=2, ensure_ascii=False) + "\n")
        return subprocess.run([sys.executable, "-I", SCRIPT, "--check", d], capture_output=True, text=True)

    def test_check_passes_on_own_output(self):
        r = self.check(lambda rep: None)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_vendor_comes_from_the_record(self):
        def edit(rep):
            rep["vendor"] = [{"model": "old", "adevtool": "0" * 40, "image": "x.zip",
                              "image_sha256": "1" * 64, "module_hash": "2" * 64}]
        self.assertEqual(self.check(edit).returncode, 0)

    def test_wrong_hash_fails(self):
        def edit(rep):
            rep["groups"][0]["files"][0]["sha256_new"] = "0" * 64
        r = self.check(edit)
        self.assertEqual(r.returncode, 1)
        self.assertIn("differs", r.stdout)

    def test_check_bypasses_the_cache(self):
        rep = json.load(open(os.path.join(self.out, "report.json")))
        f = rep["groups"][0]["files"][0]
        oid = f["oid_new"]
        cache = f"/mnt/flash/scratch/grapheneos/state/sha256/{oid[:2]}/{oid}"
        good = open(cache).read()
        try:
            with open(cache, "w") as c:
                c.write("f" * 64 + "\n")
            self.assertEqual(self.check(lambda rep: None).returncode, 0)
        finally:
            with open(cache, "w") as c:
                c.write(good)


if __name__ == "__main__":
    unittest.main()


APPROVE = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "approve.sh"))


@unittest.skipUnless(os.path.isdir(TREE + "/frameworks/base"), "no build tree")
class Approve(unittest.TestCase):
    """approve.sh without changing approved.txt: --draft and refused arguments."""

    def test_draft_lines_have_a_group_field(self):
        r = subprocess.run(["bash", APPROVE, "--draft"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertTrue(lines)
        for l in lines:
            f = l.split(" ", 4)
            self.assertEqual(len(f), 5, l)
            self.assertEqual(f[3], "?", l)

    def test_unknown_group_refused(self):
        with open(os.path.join(HERE, "..", "..", "patches", "approved.txt"), "rb") as f:
            before = f.read()
        r = subprocess.run(["bash", APPROVE, "-g", "no-such-group", "platform_build", "HEAD"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn("no group no-such-group", r.stdout)
        with open(os.path.join(HERE, "..", "..", "patches", "approved.txt"), "rb") as f:
            self.assertEqual(f.read(), before)

    def test_missing_group_flag_is_usage(self):
        r = subprocess.run(["bash", APPROVE, "platform_build", "HEAD"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("-g <group>", r.stdout)
