import copy
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))
import fork_report_html as H  # noqa: E402

F = {"repo": "platform_frameworks_base", "project": "frameworks/base", "path": "core/<x>.txt",
     "status": "modified", "mode_old": "100644", "mode_new": "100644",
     "oid_old": "a" * 40, "oid_new": "b" * 40, "sha256_old": "c" * 64, "sha256_new": "d" * 64,
     "size_old": 3, "size_new": 4, "added": 1, "deleted": 0, "notes": ["Only <b>this</b>."],
     "also_in": ["look"]}
REPORT = {
    "generator": "1", "release": "2026103010",
    "upstream": {"tag": "2026102100", "signer_checked": True},
    "manifest": {"commit": "1" * 40, "default_xml_sha256": "2" * 64}, "envs_xml_sha256": "3" * 64,
    "vendor": [{"model": "husky", "adevtool": "4" * 40, "image": "husky-factory.zip",
                "image_sha256": "5" * 64, "module_hash": "6" * 64}],
    "os_commit": "7" * 40,
    "forks": [{"path": "frameworks/base", "name": "platform_frameworks_base", "upstream_commit": "8" * 40,
               "upstream_tree": "9" * 40, "commit": "e" * 40, "tree": "f" * 40, "files": 10,
               "changed": 1, "modified": 1, "added": 0, "deleted": 0}],
    "totals": {"files": 10, "changed": 1, "modified": 1, "added": 0, "deleted": 0, "identical": 9,
               "other_projects": 1050},
    "groups": [
        {"slug": "reboot", "order": 10, "title": "Reboot credential", "what": "Restarts.\n\nTwo.",
         "why": "Keys.", "docs": ["04-alternate-credential-actions.md#x"],
         "commits": [{"repo": "platform_frameworks_base", "sha": "e" * 40, "patch_id": "0" * 40,
                      "subject": "Add reboot credential"}],
         "files": [F], "touched": [{"repo": "platform_frameworks_base", "path": "back.txt"}]},
        {"slug": "look", "order": 20, "title": "Look", "what": "W.", "why": "Y.", "docs": [],
         "commits": [], "files": [dict(F, also_in=["reboot"], notes=[])], "touched": []}],
    "downloads": {"tsv": "files-2026103010.tsv.gz", "tsv_sha256": "a1" * 32}}


class Release(unittest.TestCase):
    def setUp(self):
        self.html = H.render_release(copy.deepcopy(REPORT))

    def test_sections_present(self):
        for i in ("compared", "reboot", "look", "unchanged", "verify", "downloads"):
            self.assertIn(f'id="{i}"', self.html)
        self.assertIn("<title>2026103010 compared with GrapheneOS · ee1os</title>", self.html)
        self.assertIn("ee1os 2026103010 compared with GrapheneOS 2026102100", self.html)

    def test_hashes_full_in_page(self):
        for h in ("b" * 40, "d" * 64, "a" * 40, "c" * 64, "f" * 40, "6" * 64, "a1" * 32):
            self.assertIn(h, self.html)

    def test_escapes(self):
        self.assertNotIn("<x>", self.html)
        self.assertIn("core/&lt;x&gt;.txt", self.html)
        self.assertNotIn("<b>this</b>", self.html)

    def test_commands_filled(self):
        verify = self.html[self.html.index('id="verify"'):]
        self.assertIn("ee1os-2026103010", verify)
        self.assertIn("refs/tags/2026102100", verify)
        self.assertIn("f" * 40, verify)

    def test_links(self):
        self.assertIn("https://github.com/ee1os/platform_frameworks_base/compare/" + "8" * 40
                      + "..." + "e" * 40, self.html)
        self.assertIn("https://github.com/ee1os/ee1os/blob/" + "7" * 40
                      + "/docs/04-alternate-credential-actions.md#x", self.html)
        self.assertIn("https://github.com/ee1os/releases/releases/download/2026103010/"
                      "files-2026103010.tsv.gz", self.html)

    def test_file_anchor_and_url_encoding(self):
        import hashlib
        anchor = hashlib.sha256(b"core/<x>.txt").hexdigest()
        self.assertIn("#diff-" + anchor, self.html)
        self.assertIn("/blob/", H.render_release(dict(REPORT, groups=[dict(REPORT["groups"][0], files=[
            dict(F, status="added", path="a#b?c%.txt", also_in=[], notes=[])])])).replace("&amp;", "&"))
        added = H.render_release(dict(REPORT, groups=[dict(REPORT["groups"][0], files=[
            dict(F, status="added", path="a#b?c%.txt", also_in=[], notes=[])])]))
        self.assertIn("a%23b%3Fc%25.txt", added)

    def test_doc_labels_keep_section(self):
        g = dict(REPORT["groups"][0], docs=["07-roadmap.md#stage-3--environment-b", "07-roadmap.md#stage-5--b-before-a"])
        html = H.render_release(dict(REPORT, groups=[g]))
        self.assertIn(">07 Roadmap, stage 3 environment b<", html)
        self.assertIn(">07 Roadmap, stage 5 b before a<", html)

    def test_signature_wording(self):
        self.assertIn("in each of these projects", self.html)
        self.assertNotIn("in every project", self.html)

    def test_section_order(self):
        pos = [self.html.index(f'id="{i}"') for i in ("verify", "compared", "unchanged", "changes", "downloads")]
        self.assertEqual(pos, sorted(pos))

    def test_also_in_build_is_a_table(self):
        part = self.html[self.html.index('id="also-in-build"'):]
        part = part[:part.index("</table>")]
        for v in ("1" * 40, "2" * 64, "3" * 64, "5" * 64, "6" * 64, "husky-factory.zip"):
            self.assertIn(v, part)
        # no hash buttons inside running text
        for para in re.findall(r"<p[ >].*?</p>", self.html, flags=re.S):
            self.assertNotIn('class="h"', para, para[:120])

    def test_links_in_tables_look_like_links(self):
        self.assertRegex(self.html, r"\.fr td a[^{]*\{[^}]*color: var\(--signal\)")

    def test_verify_explains_no_build_needed(self):
        verify = self.html[self.html.index('id="verify"'):self.html.index('id="compared"')]
        self.assertIn("without building", verify)
        self.assertIn("byte for byte", verify)

    def test_paragraphs_and_cross_links(self):
        self.assertIn("<p>Restarts.</p>", self.html)
        self.assertIn('href="#look"', self.html)
        self.assertIn("back.txt", self.html)

    def test_no_js_needed(self):
        no_js = re.sub(r"<script.*?</script>", "", self.html, flags=re.S)
        self.assertIn("b" * 40, no_js)
        self.assertIn("1050", no_js.replace(" ", "").replace(" ", ""))

    def test_no_banned_words(self):
        low = self.html.lower()
        for w in ("mockup", "claude", "assistant", " ai ", "model "):
            self.assertNotIn(w, low)


class Index(unittest.TestCase):
    def test_index_empty(self):
        self.assertIn("No stable release has a page yet", H.render_index([]))

    def test_index_order(self):
        older = copy.deepcopy(REPORT)
        older["release"] = "2026102112"
        html = H.render_index([older, copy.deepcopy(REPORT)])
        self.assertLess(html.index("2026103010"), html.index("2026102112"))
        self.assertIn('href="/changes/2026103010/"', html)


if __name__ == "__main__":
    unittest.main()
