#!/usr/bin/env python3
"""scripts/update_level.py, and the Publish question of scripts/release-models.sh, in a temp
directory: no network, nothing sent, nothing built.
Run:  python3 -I tests/update-level-test.py"""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPTS = HERE.parent / "scripts"
sys.dont_write_bytecode = True


def module(tmp):
    """update_level.py with every path inside tmp."""
    os.environ.update(EE1OS_WS=str(tmp / "ws"), EE1OS_ENVS=str(tmp / "os"), EE1OS_SITE=str(tmp / "site"),
                      EE1OS_BULLETINS="http://127.0.0.1:9/none")
    spec = importlib.util.spec_from_file_location("update_level", SCRIPTS / "update_level.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def review(level, topics="none", why="Because."):
    return f"# Summary\nVerdict: none\n\n# Safe\n- x\n\n# Importance\nLevel: {level}\nTopics: {topics}\nWhy: {why}\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self.dir.name)
        self.m = module(self.tmp)
        for d in ("ws/state/levels", "ws/grapheneos-17/releases", "os/patches", "site/changes"):
            (self.tmp / d).mkdir(parents=True)
        (self.tmp / "os/patches/approved.txt").write_text("")
        self.m.fetch = lambda url: (_ for _ in ()).throw(OSError("no network in tests"))

    def tearDown(self):
        self.dir.cleanup()

    def write(self, path, data):
        p = self.tmp / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data if isinstance(data, str) else json.dumps(data))
        return str(p)

    def report(self, tag, commits=(), src="1"):
        groups = {}
        for group, subject in commits:
            groups.setdefault(group, []).append({"repo": "r", "subject": subject, "sha": "0", "patch_id": "0"})
        return {"upstream": {"tag": tag}, "forks": [{"name": "r", "commit": src}],
                "groups": [{"slug": g, "commits": c} for g, c in groups.items()]}

    def published(self, *ups):
        """ups newest first: (tag, level, {model: bn}, report)."""
        doc = {"models": {"husky": "Pixel 8 Pro", "stallion": "Pixel 10a"}, "updates": []}
        for tag, level, builds, rep in ups:
            for bn in builds.values():
                self.write(f"site/changes/{bn}/report.json", rep)
            doc["updates"].append({"upstream": tag, "source": self.m.source_id(rep), "level": level,
                                   "reason": {"en": "e", "ru": "r"}, "builds": {
                                       m: {"build": b, "published": "2026-11-05T00:00:00Z"} for m, b in builds.items()}})
        self.write("site/updates.json", doc)

    def rec(self, base, tag, level, codes=(), own=(), pl=""):
        self.write(f"ws/state/levels/{base}-{tag}.json",
                   {"base": base, "tag": tag, "level": level, "codes": list(codes), "notes": ["n"],
                    "patch_level": pl, "own_reviewed": [["r", s] for s in own]})

    def built(self, bn, rep):
        self.write(f"ws/grapheneos-17/releases/{bn}/changes/report.json", rep)


class Evidence(Base):
    def test_titles(self):
        t = self.m.title_codes
        self.assertEqual(t("Fix lock-screen bypass via default USB functions on timeout"), ["lock-screen", "usb"])
        self.assertEqual(t("Security bug fix: Prevent USB data changes for non-owner users during lockdown mode."), ["usb"])
        self.assertEqual(t("Fix PIN throttling bypass"), ["pin"])
        self.assertEqual(t("Fix verified boot bypass"), ["boot"])
        self.assertIn("remote", t("Fix remote code execution in Bluetooth"))
        for s in ("Fix RCS config credential leak via ISub", "Fix permission bypass with empty projection array",
                  "Fix BAL bypass in AddAccountSettings", 'Revert "Fix lock screen bypass"',
                  "fixup! Fix keyguard bypass", "Keyguard: fix clock position", "raise security patch level to 2026-11-05",
                  "backport fix for USB device disconnect", "Revert CredentialManager change", "spinning wheel bypass"):
            self.assertEqual(t(s), [], s)

    def test_exploited(self):
        e = self.m.exploited
        self.assertEqual(e("fix for CVE-1 which is being exploited in the wild"), "yes")
        self.assertEqual(e("may be under limited, targeted exploitation"), "yes")
        self.assertEqual(e("theoretically exploitable on other devices"), "maybe")
        self.assertEqual(e("there are no indications it is being exploited"), "maybe")
        self.assertEqual(e("fix crash"), "")

    ROWS = """<p>security patch levels of 2026-11-05 or later address all</p><h3>System</h3><table>
      <tr><th>CVE</th></tr>
      <tr><td>CVE-2026-1</td><td>A-1</td><td>RCE</td><td>Critical</td><td>Modem</td></tr>
      <tr><td>CVE-2026-1000</td><td>A-1</td><td>RCE</td><td>Critical</td><td>Modem</td></tr>
      <tr><td>CVE-2026-1001</td><td>A-1</td><td>EoP</td><td>Critical</td><td>Bootloader</td></tr>
      <tr><td>CVE-2026-1002</td><td>A-1</td><td>EoP</td><td>High</td><td>Bootloader</td></tr>
      <tr><td>CVE-2026-1003</td><td>A-1</td><td>ID</td><td>Critical</td><td>KeyMint</td></tr>
      <tr><td>CVE-2026-1004</td><td>A-1</td><td>EoP</td><td>Critical</td><td>Display</td></tr></table>"""

    def test_bulletin_rows(self):
        rows = self.m.bulletin_rows(self.ROWS, True, "2026-11-01", "2026-11-05")
        self.assertEqual([self.m.row_code(r, True) for r in rows], ["remote", "boot", None, "encryption", None])
        # a page that names a level outside the range can't be used: unread, not "nothing in it"
        with self.assertRaises(ValueError):
            self.m.bulletin_rows(self.ROWS, True, "2026-11-05", "2026-12-01")
        android = """<h2>2026-11-01 security patch level vulnerability details</h2><h3>System</h3>
          <tr><td>CVE-2026-2000</td><td>A</td><td>RCE</td><td>Critical</td><td>17</td></tr>
          <h2>2026-11-05 security patch level vulnerability details</h2><h3>MediaTek components</h3>
          <tr><td>CVE-2026-2001</td><td>A</td><td>RCE</td><td>Critical</td><td>Modem</td></tr>"""
        a = self.m.bulletin_rows(android, False, "2026-10-05", "2026-11-01")
        self.assertEqual([(r[0], self.m.row_code(r, False)) for r in a], [("CVE-2026-2000", "remote")])
        b = self.m.bulletin_rows(android, False, "2026-11-01", "2026-11-05")
        self.assertEqual([(r[0], self.m.row_code(r, False)) for r in b], [("CVE-2026-2001", None)])
        for page in ("<html>moved</html>", ""):
            with self.assertRaises(ValueError):
                self.m.bulletin_rows(page, False, "2026-11-01", "2026-11-05")
            with self.assertRaises(ValueError):
                self.m.bulletin_rows(page, True, "2026-11-01", "2026-11-05")

    def test_bulletins_asked_for(self):
        asked = []
        self.m.fetch = lambda u: asked.append(u.split("none/")[1]) or self.ROWS
        self.m.bulletins("2026-10-05", "2026-11-01")
        self.assertEqual(asked, ["2026/2026-11-01"])
        asked.clear()
        self.m.bulletins("2026-11-01", "2026-11-05")
        self.assertEqual(asked, ["2026/2026-11-01", "pixel/2026/2026-11-01"])
        asked.clear()
        self.m.bulletins("2026-11-05", "2027-01-05")
        self.assertEqual(len(asked), 4)
        self.assertEqual(self.m.bulletins("2026-11-05", "2026-11-05"), ([], [], []))

    def test_unreadable_bulletin_is_said(self):
        found, unread, _ = self.m.bulletins("2026-11-01", "2026-11-05")
        self.assertEqual((found, len(unread)), ([], 2))

    def test_review(self):
        p = self.m.parse_review
        self.assertEqual(p(review("important", "usb, lock-screen"))["codes"], ["usb", "lock-screen"])
        self.assertEqual(p(review("routine"))["level"], "routine")
        self.assertIsNone(p("# Summary\nLevel: routine\n"))
        self.assertIsNone(p(review("urgent")))
        self.assertIsNone(p(review("important")))                        # nothing named
        self.assertIsNone(p(review("important", "<script>")))
        self.assertIsNone(p(review("routine") + review("routine")))      # two sections
        self.assertIsNone(p(review("routine") + "Level: important\n"))   # said twice
        self.assertNotIn("\x1b", p(review("routine", why="a\x1b[31mb"))["why"])


class Decide(Base):
    S = [{"code": "lock-screen", "where": "x"}]
    F = {"strong": [], "unread": [], "exploited": ""}
    R = {"level": "routine", "codes": [], "why": ""}
    I = {"level": "important", "codes": ["usb"], "why": ""}

    def lv(self, facts, rev, found=(), unread=()):
        return self.m.decide(facts, rev, list(found), list(unread))[:2]

    def test_table(self):
        F, R, I, S = self.F, self.R, self.I, self.S
        self.assertEqual(self.lv(F, R), ("routine", []))
        self.assertEqual(self.lv(F, None), ("undecided", []))
        self.assertEqual(self.lv(F, {"level": "unsure", "codes": [], "why": ""}), ("undecided", []))
        self.assertEqual(self.lv(F, I), ("important", ["usb"]))
        self.assertEqual(self.lv(F, None, S), ("important", ["lock-screen"]))
        self.assertEqual(self.lv({**F, "strong": S}, I), ("important", ["lock-screen", "usb"]))
        self.assertEqual(self.lv(F, R, S)[0], "undecided")               # they disagree
        self.assertEqual(self.lv({**F, "unread": ["x"]}, R)[0], "undecided")
        self.assertEqual(self.lv(F, R, (), ["bulletin"])[0], "undecided")
        self.assertEqual(self.lv({**F, "exploited": "maybe"}, R)[0], "undecided")
        self.assertEqual(self.lv({**F, "exploited": "yes"}, None), ("important", ["exploited"]))
        self.assertEqual(self.lv(None, R)[0], "undecided")
        self.assertEqual(self.lv(None, I), ("important", ["usb"]))

    def test_combine(self):
        c = self.m.combine
        self.assertEqual(c(["routine", "important", "undecided"]), "important")
        self.assertEqual(c(["routine", "undecided"]), "undecided")
        self.assertEqual(c(["routine", "routine"]), "routine")
        self.assertEqual(c([]), "undecided")

    def test_reasons_are_ours(self):
        for code, (en, ru) in self.m.CODES.items():
            r = self.m.reason("important", [code], "2026120100", "", True)
            self.assertIn(en, r["en"])
            self.assertIn(ru, r["ru"])
        self.assertEqual(self.m.reason("undecided", ["usb"], "2026120100", "", True), {"en": "", "ru": ""})
        longest = self.m.reason("important", list(self.m.CODES), "2026120100", "", True)
        self.assertLess(max(map(len, longest.values())), 300)


class Record(Base):
    def facts(self, **kw):
        return self.write("f.json", {"base": "2026110200", "target": "2026111800", "strong": [], "unread": [],
                                     "exploited": "", "patch_level": ["2026-11-01", "2026-11-01"], **kw})

    def record(self, facts, rev=None):
        self.write("ws/state/upstream-tag", "2026110200\n")
        r = self.write("x-review.md", rev) if rev else None
        self.assertEqual(self.m.record("2026111800", facts, r), 0)
        return self.m.load(str(self.tmp / "ws/state/levels/2026110200-2026111800.json"))

    def test_decided_is_kept_undecided_isnt(self):
        self.assertEqual(self.record(self.facts())["level"], "undecided")
        self.assertEqual(self.record(self.facts(), review("routine"))["level"], "routine")
        self.assertEqual(self.record(self.facts(), review("important", "usb"))["level"], "routine")

    def test_missing_or_foreign_facts(self):
        self.assertEqual(self.record(None, review("routine"))["level"], "undecided")
        self.assertEqual(self.record(self.facts(base="2026100600"), review("routine"))["level"], "undecided")
        self.assertEqual(self.record(self.write("f.json", "{"), review("routine"))["level"], "undecided")

    def test_unreadable_bulletins(self):
        r = self.record(self.facts(patch_level=["2026-11-01", "2026-11-05"]), review("routine"))
        self.assertEqual(r["level"], "undecided")
        self.assertIn("bulletin", " ".join(r["notes"]))

    def test_own_only_when_the_report_showed_it(self):
        self.published(("2026110200", "routine", {"husky": "2026110508"}, self.report("2026110200", [("duress", "Old")])))
        self.write("os/patches/approved.txt", "r 1 abc duress Old\nr 2 abc duress New one\nr 3 abc duress Not shown\n")
        self.write("x.md", "- `r` (duress) New one\n")
        self.assertEqual(self.record(self.facts(), review("routine"))["own_reviewed"], [["r", "New one"]])


class Build(Base):
    def level(self, bn="2026112100", model="husky"):
        self.assertEqual(self.m.build(bn, model), 0)
        return self.m.load(self.m.level_path(bn, model))

    def base(self, *own):
        self.published(("2026110200", "important", {"husky": "2026110508", "stallion": "2026110519"},
                        self.report("2026110200", [("duress", "Old")])))
        self.built("2026112100", self.report("2026111800", [("duress", "Old"), *own], "2"))

    def test_routine(self):
        self.base()
        self.rec("2026110200", "2026111800", "routine", pl="2026-11-05")
        d = self.level()
        self.assertEqual(d["level"], "routine")
        self.assertIn("2026-11-05", d["reason"]["en"])

    def test_every_taken_release_since_the_published_one_counts(self):
        self.base()
        self.rec("2026110200", "2026111000", "important", ["usb"])     # taken, never published
        self.rec("2026111000", "2026111800", "routine")
        d = self.level()
        self.assertEqual((d["level"], d["codes"]), ("important", ["usb"]))
        self.assertIn("USB", d["reason"]["ru"])

    def test_gap_is_undecided(self):
        self.base()
        self.rec("2026111000", "2026111800", "routine")
        d = self.level()
        self.assertEqual(d["level"], "undecided")
        self.assertIn("no record", d["notes"][0])

    def test_undecided_link(self):
        self.base()
        self.rec("2026110200", "2026111000", "undecided")
        self.rec("2026111000", "2026111800", "routine")
        self.assertEqual(self.level()["level"], "undecided")

    def test_own_changes(self):
        self.base(("look", "New wallpaper"))
        self.rec("2026110200", "2026111800", "routine")
        self.assertEqual(self.level()["level"], "routine")

    def test_own_changes_not_judged(self):
        self.base(("duress", "Keep the PIN safe"))
        self.rec("2026110200", "2026111800", "routine")
        d = self.level()
        self.assertEqual(d["level"], "undecided")
        self.assertIn("Keep the PIN safe", " ".join(d["notes"]))

    def test_own_changes_judged_by_the_review(self):
        self.base(("duress", "Keep the PIN safe"))
        self.rec("2026110200", "2026111800", "routine", own=["Keep the PIN safe"])
        self.assertEqual(self.level()["level"], "routine")

    def test_second_model_gets_the_same_range(self):
        self.base()
        self.rec("2026110200", "2026111800", "important", ["boot"])
        rep = self.report("2026111800", [("duress", "Old")], "2")
        self.published(("2026111800", "important", {"husky": "2026112100"}, rep),
                       ("2026110200", "important", {"husky": "2026110508"}, self.report("2026110200", [("duress", "Old")])))
        self.built("2026112103", rep)
        self.assertEqual(self.level("2026112103", "stallion")["level"], "important")

    def test_same_source_built_again_is_routine(self):
        rep = self.report("2026110200", [("duress", "Old")])
        self.published(("2026110200", "important", {"husky": "2026110508"}, rep))
        self.built("2026110912", rep)
        self.assertEqual(self.level("2026110912")["level"], "routine")

    def test_never_rewritten(self):
        self.base()
        self.rec("2026110200", "2026111800", "important", ["boot"])
        self.level()
        self.rec("2026110200", "2026111800", "routine")
        self.assertEqual(self.level()["level"], "important")

    def test_no_site_file(self):
        self.built("2026112100", self.report("2026111800"))
        self.assertEqual(self.level()["level"], "undecided")


class Chain(Base):
    def test_every_way_counts(self):
        a, b, c = "2026110200", "2026111000", "2026111800"
        for f, t in ((a, b), (b, c), (a, c)):
            self.write(f"ws/state/levels/{f}-{t}.json", {"base": f, "tag": t})
        self.assertEqual(len(self.m.chain(a, c)), 3)
        self.assertEqual([r["tag"] for r in self.m.chain(b, c)], [c])
        self.assertEqual(self.m.chain(a, a), [])
        self.assertIsNone(self.m.chain("2026102100", c))


class Add(Base):
    def setUp(self):
        super().setUp()
        self.old = ("2026110200", "routine", {"husky": "2026110508"}, self.report("2026110200"))
        self.published(self.old)
        self.rep = self.report("2026111800", src="2")
        for bn, model in (("2026112100", "husky"), ("2026112103", "stallion")):
            self.built(bn, self.rep)

    def set(self, bn, model, level, codes=()):
        self.write(f"ws/grapheneos-17/releases/{bn}/update-{model}.json", {
            "build": bn, "model": model, "level": level, "codes": list(codes), "notes": [],
            "reason": self.m.reason(level, list(codes), "2026111800", "", True)})

    def add(self, bn, model, owner=""):
        self.assertEqual(self.m.add(bn, model, owner), 0)
        return self.m.site_updates()["updates"]

    def test_models_join_one_update(self):
        self.set("2026112100", "husky", "important", ["usb"])
        self.set("2026112103", "stallion", "important", ["usb"])
        self.add("2026112100", "husky")
        doc = self.m.site_updates()
        doc["updates"][0]["reason"]["en"] = "Edited."
        self.m.save(os.path.join(self.m.SITE, "updates.json"), doc)
        ups = self.add("2026112103", "stallion")
        self.assertEqual(len(ups), 2)
        self.assertEqual(set(ups[0]["builds"]), {"husky", "stallion"})
        self.assertEqual(ups[0]["reason"]["en"], "Edited.")
        self.assertEqual(len(self.add("2026112103", "stallion")), 2)     # twice is once

    def test_nothing_recorded_is_undecided(self):
        self.assertEqual(self.add("2026112100", "husky")[0]["level"], "undecided")

    def test_owner_decides(self):
        self.set("2026112100", "husky", "undecided")
        u = self.add("2026112100", "husky", "important")[0]
        self.assertEqual((u["level"], bool(u["reason"]["en"]), bool(u["reason"]["ru"])), ("important", True, True))

    def test_owner_says_routine(self):
        self.set("2026112100", "husky", "important", ["boot"])
        u = self.add("2026112100", "husky", "routine")[0]
        self.assertEqual(u["level"], "routine")
        self.assertNotIn("Fixes", u["reason"]["en"])
        # the next model's proposal doesn't undo that
        self.set("2026112103", "stallion", "important", ["boot"])
        self.assertEqual(self.add("2026112103", "stallion")[0]["level"], "routine")

    def test_more_serious_model_raises_it(self):
        for level, want in (("important", "important"), ("undecided", "undecided"), ("routine", "routine")):
            with self.subTest(level):
                self.published(self.old)
                self.set("2026112100", "husky", "routine")
                self.assertEqual(self.add("2026112100", "husky")[0]["level"], "routine")
                self.set("2026112103", "stallion", level, ["boot"] if level == "important" else [])
                u = self.add("2026112103", "stallion")[0]
                self.assertEqual(u["level"], want)
                self.assertEqual("Fixes" in u["reason"]["en"], want == "important")

    def test_owner_routine_over_undecided_then_important(self):
        self.set("2026112100", "husky", "undecided")
        self.add("2026112100", "husky", "routine")
        self.set("2026112103", "stallion", "important", ["boot"])
        self.assertEqual(self.add("2026112103", "stallion")[0]["level"], "important")

    def test_less_serious_model_keeps_it(self):
        self.set("2026112100", "husky", "important", ["boot"])
        self.add("2026112100", "husky")
        self.set("2026112103", "stallion", "routine")
        self.assertEqual(self.add("2026112103", "stallion")[0]["level"], "important")

    def test_bad_level_refused(self):
        r = subprocess.run([sys.executable, "-I", str(SCRIPTS / "update_level.py"), "add", "2026112100", "husky",
                            "urgent"], capture_output=True, env=dict(os.environ))
        self.assertEqual(r.returncode, 2)


class Question(Base):
    """release-models.sh with its paths in tmp, and stand-ins for everything it starts."""

    def setUp(self):
        super().setUp()
        sh = (SCRIPTS / "release-models.sh").read_text()
        for a, b in (("WS=/mnt/flash/scratch/grapheneos", f"WS={self.tmp}/ws"),
                     ("ENVS=/mnt/flash/home/faeton/work/ee1os/os", f"ENVS={self.tmp}/os"),
                     ("/mnt/tank/scripts/notify-telegram.sh", f"{self.tmp}/notify")):
            self.assertIn(a, sh)
            sh = sh.replace(a, b)
        self.assertNotIn("/mnt/", sh.replace(str(self.tmp), ""))
        d = self.tmp / "os/scripts"
        d.mkdir()
        shutil.copy(SCRIPTS / "update_level.py", d)
        self.script("os/scripts/release-models.sh", sh)
        self.script("notify", f'#!/bin/sh\necho "notify $*" >> {self.tmp}/said\n')
        self.script("os/scripts/press.py", f'#!/bin/sh\ncat > {self.tmp}/text\nfor a; do echo "$a"; done > {self.tmp}/buttons\n')
        self.script("os/scripts/publish-release.sh", f'#!/bin/sh\necho "$DEVICE $1 $2 level=$LEVEL" >> {self.tmp}/published\n')
        for dev, bn in (("husky", "2026112100"), ("stallion", "2026112103")):
            self.built(bn, self.report("2026111800", src="2"))
            self.write(f"ws/grapheneos-17/releases/{bn}/release-{dev}-{bn}/{dev}-ota_update-{bn}.zip", "x")
            (self.tmp / "ws/grapheneos-17/keys" / dev).mkdir(parents=True)
        self.script("os/scripts/release.sh", '#!/bin/sh\n[ "$DEVICE" = husky ] && b=2026112100 || b=2026112103\n'
                                             'echo "== release $b $DEVICE (user)"\n')
        self.write("ws/state/upstream-tag", "2026111800\n")
        self.write("ws/.secrets/key-passphrase", "x")

    def script(self, path, text):
        p = self.tmp / path
        p.write_text(text)
        p.chmod(0o755)

    def run_sh(self, *a):
        return subprocess.run([str(self.tmp / "os/scripts/release-models.sh"), *a], capture_output=True, text=True,
                              env=dict(os.environ))

    def ask(self, *levels):
        for (dev, bn), level in zip((("husky", "2026112100"), ("stallion", "2026112103")), levels):
            if level:
                self.write(f"ws/grapheneos-17/releases/{bn}/update-{dev}.json", {
                    "build": bn, "model": dev, "level": level, "codes": ["usb"], "notes": ["because $(touch x) `y`"],
                    "reason": self.m.reason(level, ["usb"], "2026111800", "", True)})
        r = self.run_sh("build")
        self.assertEqual(r.returncode, 0, r.stderr)
        return (self.tmp / "text").read_text(), (self.tmp / "buttons").read_text().split("\n")[2:-1]

    def test_important(self):
        text, b = self.ask("important", "important")
        self.assertIn("IMPORTANT", text)
        self.assertIn("USB access to a locked phone", text)
        self.assertIn("$(touch x) `y`", text)                       # shown, not run
        self.assertEqual([x.split("=")[0] for x in b], ["publish", "publish-routine", "keep"])

    def test_routine(self):
        _, b = self.ask("routine", "routine")
        self.assertEqual([x.split("=")[0] for x in b], ["publish", "publish-important", "keep"])

    def test_undecided(self):
        for levels in (("routine", ""), ("", ""), ("undecided", "routine")):
            for f in self.tmp.glob("ws/grapheneos-17/releases/*/update-*.json"):
                f.unlink()
            text, b = self.ask(*levels)
            self.assertIn("NOT DECIDED", text)
            self.assertEqual([x.split("=")[0] for x in b], ["publish-important", "publish-routine", "keep"])

    def test_broken_level_script(self):
        self.script("os/scripts/update_level.py", "raise SystemExit(1)\n")
        text, b = self.ask("routine", "routine")
        self.assertIn("decide it here", text)
        self.assertEqual(b[0].split("=")[0], "publish-important")

    def test_publish_passes_the_level(self):
        for level in ("", "important", "routine"):
            self.ask("routine", "routine")
            (self.tmp / "published").unlink(missing_ok=True)
            r = self.run_sh("publish", "2026111800", *([level] if level else []))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((self.tmp / "published").read_text(),
                             f"husky 2026112100 user level={level}\nstallion 2026112103 user level={level}\n")
        self.ask("routine", "routine")
        self.assertEqual(self.run_sh("publish", "2026111800", "urgent").returncode, 2)
        self.assertTrue((self.tmp / "ws/state/ready").exists())


if __name__ == "__main__":
    unittest.main()
