import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "..", "scripts")
sys.path.insert(0, SCRIPTS)
import ledger  # noqa: E402

TOML = b'''
[groups.reboot]
order = 10
title = "Reboot credential"
what = "A PIN that restarts the phone."
why = "Keys leave memory."
docs = ["04-alternate-credential-actions.md"]

[groups.reboot.notes]
"frameworks/base:a.java" = "Only one line."

[groups.look]
order = 20
title = "Look"
what = "Wallpapers."
why = "Ours."
'''

LINES = (
    "platform_frameworks_base aaaa 111111111111 reboot Add reboot credential\n"
    "platform_build bbbb 222222222222 look Add the wallpaper collections\n"
)


class Parse(unittest.TestCase):
    def test_parse_five_fields(self):
        a, err = ledger.parse_approved(LINES)
        self.assertEqual(err, [])
        self.assertEqual(a[0], ledger.Approval("platform_frameworks_base", "aaaa", "111111111111",
                                               "reboot", "Add reboot credential"))
        self.assertEqual(a[1].subject, "Add the wallpaper collections")

    def test_blank_and_comment_lines(self):
        a, err = ledger.parse_approved("# note\n\n" + LINES)
        self.assertEqual(err, [])
        self.assertEqual(len(a), 2)

    def test_duplicate_and_old_format(self):
        text = LINES + "platform_build cccc 333333333333 Leave out Auditor\n" \
            + "platform_build bbbb 444444444444 look Again\n"
        a, err = ledger.parse_approved(text)
        g, gerr = ledger.load_groups(TOML)
        errs = err + ledger.check(a, g)
        self.assertTrue(any("line 3" in e for e in errs), errs)
        self.assertTrue(any("platform_build bbbb" in e and "twice" in e for e in errs), errs)

    def test_bad_slug(self):
        a, err = ledger.parse_approved("platform_build bbbb 222222222222 Reboot_Cred Subject\n")
        self.assertTrue(any("Reboot_Cred" in e for e in err), err)


class Groups(unittest.TestCase):
    def test_load(self):
        g, err = ledger.load_groups(TOML)
        self.assertEqual(err, [])
        self.assertEqual(g["reboot"].title, "Reboot credential")
        self.assertEqual(g["reboot"].notes, {"frameworks/base:a.java": "Only one line."})
        self.assertEqual(g["look"].docs, [])

    def test_unknown_group(self):
        a, _ = ledger.parse_approved(LINES + "platform_build cccc 333333333333 nope Subject\n")
        g, _ = ledger.load_groups(TOML)
        errs = ledger.check(a, g)
        self.assertTrue(any("nope" in e for e in errs), errs)

    def test_unused_group(self):
        a, _ = ledger.parse_approved(LINES.splitlines(True)[0])
        g, _ = ledger.load_groups(TOML)
        errs = ledger.check(a, g)
        self.assertTrue(any("look" in e and "no approved commit" in e for e in errs), errs)

    def test_empty_why(self):
        g, err = ledger.load_groups(TOML.replace(b'why = "Ours."', b'why = "  "'))
        self.assertTrue(any("look" in e and "why" in e for e in err), err)

    def test_bad_toml(self):
        g, err = ledger.load_groups(b"[groups.x\n")
        self.assertTrue(err)


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(SCRIPTS, "ledger.py"), *args],
                              capture_output=True, text=True)

    def test_cli_check_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            ap, ch = os.path.join(d, "approved.txt"), os.path.join(d, "changes.toml")
            with open(ch, "wb") as f:
                f.write(TOML)
            with open(ap, "w") as f:
                f.write(LINES)
            r = self.run_cli("check", ap, ch)
            self.assertEqual((r.returncode, r.stdout), (0, ""))
            with open(ap, "a") as f:
                f.write("platform_build cccc 3 nope S\n")
            r = self.run_cli("check", ap, ch)
            self.assertEqual(r.returncode, 1)
            self.assertTrue(r.stdout.startswith("FAIL: "), r.stdout)
            self.assertEqual(self.run_cli("has-group", ch, "look").returncode, 0)
            self.assertEqual(self.run_cli("has-group", ch, "nope").returncode, 1)

    def test_cli_crash_is_a_fail_line(self):
        with tempfile.TemporaryDirectory() as d:
            ap, ch = os.path.join(d, "approved.txt"), os.path.join(d, "changes.toml")
            with open(ch, "wb") as f:
                f.write(b'[groups]\nx = "str"\n')
            with open(ap, "wb") as f:
                f.write(b"platform_build bbbb 222222222222 look \xff\n")
            r = self.run_cli("check", ap, ch)
            self.assertEqual(r.returncode, 1)
            self.assertTrue(r.stdout.startswith("FAIL: "), (r.stdout, r.stderr))

    def test_verify_tree_checks_ledger_exit_code(self):
        with open(os.path.join(SCRIPTS, "verify-tree.sh")) as f:
            vt = f.read()
        block = vt[vt.index("# ledger:"):vt.index("if [ -e \"$SIGNERS\" ]")]
        self.assertIn("rc=$?", block)
        self.assertIn("ledger.py failed", block)


if __name__ == "__main__":
    unittest.main()
