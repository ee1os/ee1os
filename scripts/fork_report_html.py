"""HTML for the changes pages (fork_report.py): one page per stable release and the list of
them, in the site's look (site/style.css, site.js), readable without JS. Pages are static files
in site/changes/; a published page is never regenerated."""
import hashlib
from html import escape
from urllib.parse import quote

ORG = "https://github.com/ee1os"
UPSTREAM = "https://github.com/GrapheneOS"
RELEASES = "https://github.com/ee1os/releases/releases"

HEAD = """<!doctype html>
<html lang="en" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · ee1os</title>
<meta name="description" content="{description}">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<script>
(function (d) {{
  d.classList.remove("no-js");
  try {{
    var t = localStorage.getItem("theme");
    if (t === "light" || t === "dark") d.setAttribute("data-theme", t);
  }} catch (e) {{}}
}})(document.documentElement);
</script>
<script src="/site.js" defer></script>
<style>
:root {{ --fr-add: #1a7f37; --fr-del: #b42318; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --fr-add: #56c271; --fr-del: #ff7b72; }} }}
:root[data-theme="dark"] {{ --fr-add: #56c271; --fr-del: #ff7b72; }}
.fr section {{ margin-top: 3rem; }}
.fr h2 {{ text-wrap: balance; }}
.fr .tally {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(13rem, 1fr)); gap: 1rem; margin-top: 1.5rem; }}
.fr .tally div {{ border: 1px solid var(--rule); border-radius: var(--radius); padding: .9rem 1rem; }}
.fr .tally b {{ display: block; font-size: 1.6rem; line-height: 1.2; }}
.fr .tally span {{ color: var(--ink-3); font-size: .9rem; }}
.fr .tally .ch b {{ color: var(--signal); }}
.fr .scroll {{ overflow-x: auto; border: 1px solid var(--rule); border-radius: var(--radius); }}
.fr table {{ border-collapse: collapse; width: 100%; font-size: .88rem; }}
.fr th, .fr td {{ text-align: left; padding: .5rem .75rem; border-bottom: 1px solid var(--rule); vertical-align: top; white-space: nowrap; }}
.fr th {{ font-weight: 600; color: var(--ink-3); font-size: .78rem; letter-spacing: .03em; text-transform: uppercase; background: var(--paper-raised); }}
.fr tr:last-child td {{ border-bottom: 0; }}
.fr td.path {{ white-space: normal; word-break: break-all; min-width: 16rem; font-family: var(--mono); font-size: .8rem; }}
.fr td.num {{ text-align: right; }}
.fr td.wrap {{ white-space: normal; min-width: 14rem; }}
.fr td a, .fr .meta a, .fr ul.commits a, .fr .note a {{ color: var(--signal); text-decoration-color: currentColor; }}
.fr .k {{ display: block; font-size: .72rem; color: var(--ink-3); margin-top: .35rem; }}
.fr .k:first-child {{ margin-top: 0; }}
.fr h3 {{ margin-top: 2rem; }}
.fr code {{ font-family: var(--mono); font-size: .86em; }}
.fr .h {{ display: block; font-family: var(--mono); font-size: .78rem; max-width: 9.5rem; overflow: hidden; text-overflow: ellipsis; }}
.fr .h.full {{ max-width: none; word-break: break-all; white-space: normal; }}
.fr .h + .h {{ color: var(--ink-3); }}
.fr button.h {{ border: 0; background: none; color: inherit; padding: 0; cursor: copy; text-align: left; }}
.fr button.h:hover {{ color: var(--signal); }}
.fr .st {{ font-size: .76rem; font-weight: 600; padding: .05rem .45rem; border-radius: 999px; border: 1px solid currentColor; }}
.fr .st.modified {{ color: var(--signal); }} .fr .st.added {{ color: var(--fr-add); }} .fr .st.deleted {{ color: var(--fr-del); }}
.fr .plus {{ color: var(--fr-add); }} .fr .minus {{ color: var(--fr-del); }}
.fr .muted {{ color: var(--ink-3); font-size: .92rem; }}
.fr .group {{ border: 1px solid var(--rule); border-radius: var(--radius-lg); padding: 1.25rem; display: grid; gap: .9rem; min-width: 0; margin-top: 1.25rem; }}
.fr .group > header {{ display: flex; justify-content: space-between; align-items: baseline; gap: .5rem 1rem; flex-wrap: wrap; }}
.fr .group h3 {{ margin: 0; font-size: 1.2rem; }}
.fr .twocol {{ display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }}
@media (max-width: 760px) {{ .fr .twocol {{ grid-template-columns: 1fr; }} }}
.fr .twocol p {{ margin: 0 0 .6rem; font-size: .98rem; }}
.fr .label {{ font-size: .76rem; font-weight: 650; letter-spacing: .06em; text-transform: uppercase; color: var(--ink-3); margin-bottom: .25rem; }}
.fr .meta {{ display: flex; flex-wrap: wrap; gap: .3rem 1.25rem; font-size: .9rem; color: var(--ink-2); }}
.fr ul.commits {{ margin: 0; padding: 0; list-style: none; font-size: .9rem; display: grid; gap: .2rem; }}
.fr ul.commits code {{ color: var(--ink-3); margin-right: .5rem; }}
.fr .note {{ font-size: .82rem; color: var(--ink-2); margin-top: .3rem; white-space: normal; }}
.fr details > summary {{ cursor: pointer; color: var(--ink-2); font-size: .92rem; }}
.fr details[open] > summary {{ margin-bottom: .6rem; }}
.fr pre {{ background: var(--paper-raised); border: 1px solid var(--rule); border-radius: var(--radius); padding: 1rem; overflow-x: auto; font-family: var(--mono); font-size: .8rem; line-height: 1.55; }}
.fr pre .c {{ color: var(--ink-3); }}
.fr .dl {{ display: flex; flex-wrap: wrap; gap: .75rem; }}
.fr .dl a {{ border: 1px solid var(--rule-strong); border-radius: var(--radius); padding: .5rem .9rem; text-decoration: none; }}
.fr .dl a:hover {{ border-color: var(--signal); color: var(--signal); }}
.fr ol.releases {{ list-style: none; padding: 0; display: grid; gap: .75rem; }}
.fr ol.releases li {{ border: 1px solid var(--rule); border-radius: var(--radius); padding: .8rem 1rem; }}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site">
  <div class="wrap">
    <a class="brand" href="/"><svg viewBox="0 0 48 48" aria-hidden="true"><rect class="frame" x="4" y="12" width="40" height="24" rx="12"/><circle class="dot" cx="16" cy="24" r="5.5"/><circle class="dot on" cx="32" cy="24" r="5.5"/></svg>ee1os<abbr class="stage" title="Beta">β</abbr></a>
    <nav class="primary" aria-label="Site">
      <a href="/devices">Devices</a>
      <a href="/install">Install</a>
      <a href="/guides">Guides</a>
      <a href="/report#contact">Help</a>
      <a href="https://github.com/ee1os">Source</a>
    </nav>
  </div>
</header>
<main id="main" class="wrap fr">
"""

FOOT = """</main>
<footer class="site">
  <div class="wrap">
    <p>Personal research and test project, provided as is, with no warranty and no liability. <a href="/terms">Terms</a>.</p>
    <p>An independent fork, not affiliated with or endorsed by the GrapheneOS project. Please don't
    ask GrapheneOS for help with it. GrapheneOS is a trademark of the GrapheneOS Foundation; Android
    and Pixel are trademarks of Google LLC.</p>
    <div class="prefs">
      <div class="theme" role="group" aria-label="Colour theme">
        <button type="button" value="system" aria-pressed="true" title="Match the system"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="9" rx="1"/><path d="M5.5 14h5M8 11.5V14"/></svg><span class="sr">System</span></button>
        <button type="button" value="light" aria-pressed="false" title="Light"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><circle cx="8" cy="8" r="3"/><path d="M8 1v1.6M8 13.4V15M1 8h1.6M13.4 8H15M3 3l1.1 1.1M11.9 11.9 13 13M3 13l1.1-1.1M11.9 4.1 13 3"/></svg><span class="sr">Light</span></button>
        <button type="button" value="dark" aria-pressed="false" title="Dark"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M13.5 9.8A5.8 5.8 0 0 1 6.2 2.5a5.8 5.8 0 1 0 7.3 7.3Z"/></svg><span class="sr">Dark</span></button>
      </div>
    </div>
  </div>
</footer>
<script>
document.querySelectorAll("button.h").forEach(function (b) {
  b.addEventListener("click", function () {
    var t = b.getAttribute("data-h"), old = b.textContent;
    try {
      navigator.clipboard.writeText(t).then(function () {
        b.textContent = "copied";
        setTimeout(function () { b.textContent = old; }, 1200);
      }, function () {});
    } catch (e) {}
  });
});
</script>
</body>
</html>
"""


def e(s):
    return escape("" if s is None else str(s), quote=True)


def n(x):
    """1 234 with a thin space, like the rest of the site's numbers"""
    return f"{x:,}".replace(",", " ")


def h(value):
    """A hash: the full value is in the page text (selectable, searchable), shortened by CSS;
    a click copies it."""
    if not value:
        return '<span class="h muted">—</span>'
    return f'<button type="button" class="h" data-h="{e(value)}" title="{e(value)}">{e(value)}</button>'


def paras(text):
    return "".join(f"<p>{e(p.strip())}</p>" for p in text.split("\n\n") if p.strip())


def doc_link(os_commit, doc):
    """'07-roadmap.md#stage-3--environment-b' -> '07 Roadmap, stage 3 environment b'"""
    name, _, anchor = doc.partition("#")
    words = name.removesuffix(".md").split("-")
    label = (words[0] + " " + " ".join(words[1:]).capitalize()) if words[0].isdigit() else " ".join(words)
    if anchor:
        label += ", " + " ".join(w for w in anchor.split("-") if w)
    return f'<a href="{ORG}/ee1os/blob/{e(os_commit)}/docs/{e(doc)}">{e(label)}</a>'


def file_row(r, f, titles):
    commit = next(x["commit"] for x in r["forks"] if x["name"] == f["repo"])
    base = next(x["upstream_commit"] for x in r["forks"] if x["name"] == f["repo"])
    path_url = quote(f["path"].encode("utf-8", "surrogateescape"))
    anchor = hashlib.sha256(f["path"].encode("utf-8", "surrogateescape")).hexdigest()
    if f["status"] == "deleted":
        link = f'<a href="{ORG}/{e(f["repo"])}/blob/{e(base)}/{e(path_url)}">file</a>'
    elif f["status"] == "added":
        link = f'<a href="{ORG}/{e(f["repo"])}/blob/{e(commit)}/{e(path_url)}">file</a>'
    else:
        link = (f'<a href="{ORG}/{e(f["repo"])}/compare/{e(base)}...{e(commit)}#diff-{anchor}">'
                f'diff</a>')
    if f["added"] is None:
        lines = f'<span class="muted">binary, {n(f["size_old"] or 0)} → {n(f["size_new"] or 0)} bytes</span>'
    else:
        lines = f'<span class="plus">+{n(f["added"])}</span> <span class="minus">−{n(f["deleted"])}</span>'
        if f["mode_old"] and f["mode_new"] and f["mode_old"] != f["mode_new"]:
            lines += f' <span class="muted">mode {e(f["mode_old"])} → {e(f["mode_new"])}</span>'
    notes = "".join(f'<div class="note">{e(x)}</div>' for x in f["notes"])
    if f["also_in"]:
        notes += '<div class="note">Also in ' + ", ".join(
            f'<a href="#{e(s)}">{e(titles.get(s, s))}</a>' for s in f["also_in"]) + ".</div>"
    return (f'<tr><td class="path">{e(f["project"])}/{e(f["path"])}{notes}</td>'
            f'<td><span class="st {e(f["status"])}">{e(f["status"])}</span></td>'
            f'<td>{h(f["oid_old"])}{h(f["sha256_old"]) if f["oid_old"] else ""}</td>'
            f'<td>{h(f["oid_new"])}{h(f["sha256_new"]) if f["oid_new"] else ""}</td>'
            f'<td class="num">{lines}</td><td>{link}</td></tr>')


def group_card(r, g, titles):
    projects = sorted({f["project"] for f in g["files"]})
    count = f'{", ".join(e(p) for p in projects)} · {n(len(g["files"]))} file{"s" * (len(g["files"]) != 1)}'
    docs = "".join(f"<span>{doc_link(r['os_commit'], d)}</span>" for d in g["docs"])
    commits = "".join(
        f'<li><code><a href="{ORG}/{e(c["repo"])}/commit/{e(c["sha"])}">{e(c["sha"][:12])}</a></code>'
        f'{e(c["subject"])} <span class="muted">({e(c["repo"].removeprefix("platform_"))})</span></li>'
        for c in g["commits"])
    rows = "".join(file_row(r, f, titles) for f in g["files"])
    touched = ""
    if g["touched"]:
        items = "".join(f'<li><code>{e(t["path"])}</code> <span class="muted">({e(t["repo"].removeprefix("platform_"))})</span></li>'
                        for t in g["touched"])
        touched = (f'<details><summary>Touched, no net change: {n(len(g["touched"]))} '
                   f'file{"s" * (len(g["touched"]) != 1)}</summary><p class="muted">Commits of this group '
                   f'changed these files, and later ones put them back as GrapheneOS has them.</p>'
                   f'<ul class="commits">{items}</ul></details>')
    return f"""<article class="group" id="{e(g['slug'])}">
<header><h3>{e(g['title'])}</h3><span class="muted">{count}</span></header>
<div class="twocol"><div><div class="label">What</div>{paras(g['what'])}</div><div><div class="label">Why</div>{paras(g['why'])}</div></div>
{f'<div class="meta"><span>Design:</span>{docs}</div>' if docs else ''}
<details><summary>{n(len(g['commits']))} commit{'s' * (len(g['commits']) != 1)}</summary><ul class="commits">{commits}</ul></details>
<div class="scroll"><table>
<thead><tr><th>File</th><th>Status</th><th>GrapheneOS</th><th>ee1os</th><th>Lines</th><th></th></tr></thead>
<tbody>{rows}</tbody></table></div>
{touched}
</article>
"""


def render_release(r):
    bn, tag, t = r["release"], r["upstream"]["tag"], r["totals"]
    tagname = f"ee1os-{bn}"
    titles = {g["slug"]: g["title"] for g in r["groups"]}
    fk_rows = "".join(
        f'<tr><td><code>{e(f["path"])}</code></td><td class="num">{n(f["files"])}</td>'
        f'<td class="num">{n(f["changed"])}</td>'
        f'<td>{h(f["upstream_commit"])}{h(f["upstream_tree"])}</td><td>{h(f["commit"])}{h(f["tree"])}</td>'
        f'<td><a href="{ORG}/{e(f["name"])}/compare/{e(f["upstream_commit"])}...{e(f["commit"])}">compare</a></td></tr>'
        for f in r["forks"])
    m = r["manifest"]

    def kv(label, value):
        return f'<span class="k">{e(label)}</span>{h(value)}'

    extra_rows = (
        f'<tr><td>Release manifest</td><td class="wrap">GrapheneOS\'s signed '
        f'<a href="{UPSTREAM}/platform_manifest/tree/{e(tag)}">platform_manifest {e(tag)}</a>. '
        f'It pins the revision of every other project.</td>'
        f'<td>{kv("commit", m.get("commit"))}{kv("default.xml SHA-256", m.get("default_xml_sha256"))}</td></tr>'
        f'<tr><td>Local manifest</td><td class="wrap">A few lines that point the {len(r["forks"])} '
        f'projects above at the ee1os forks; nothing else.</td>'
        f'<td>{kv("SHA-256", r.get("envs_xml_sha256"))}</td></tr>')
    extra_rows += "".join(
        f'<tr><td>Device files, {e(v["model"])}</td><td class="wrap">Generated by GrapheneOS\'s adevtool '
        f'(<code>{e((v["adevtool"] or "")[:12])}</code>) from Google\'s factory image '
        f'<code>{e(v["image"])}</code>.</td>'
        f'<td>{kv("factory image SHA-256", v["image_sha256"])}{kv("content hash", v["module_hash"])}</td></tr>'
        for v in r["vendor"])
    groups = "".join(group_card(r, g, titles) for g in r["groups"])
    first = r["forks"][0] if r["forks"] else {"name": "", "tree": ""}
    np = len(r["forks"])
    lead = (f"ee1os is GrapheneOS with changes in {np} of its source projects. This page "
            f"lists every file in those projects: which ones are exactly GrapheneOS's, which ones "
            f"ee1os changed, and why. Every other project in the build is the signed GrapheneOS "
            f"release, unchanged.")
    body = f"""<header class="page-head">
<p class="muted"><a href="/changes/">All releases</a></p>
<h1>ee1os {e(bn)} compared with GrapheneOS {e(tag)}</h1>
<p class="lead">{e(lead)}</p>
<div class="tally">
<div class="ch"><b>{n(t['changed'])}</b><span>files changed in {np} projects<br>{n(t['modified'])} modified · {n(t['added'])} added · {n(t['deleted'])} deleted</span></div>
<div><b>{n(t['identical'])}</b><span>other files in these projects, identical to GrapheneOS</span></div>
<div><b>{n(t['other_projects'])}</b><span>other projects, at exactly the revisions of the signed release</span></div>
</div>
</header>

<section id="verify">
<h2>Check it yourself</h2>
<p>Everything on this page can be checked with git alone, without building anything. Below it
are, in order: the projects that were compared, with their commits and hashes; what else goes
into the build; the files that are GrapheneOS's own; and every change, grouped, with the reason
for it.</p>
<p>Building the OS yourself isn't needed for this, and wouldn't settle it. A full build needs a
powerful machine, with tens of gigabytes of memory and hundreds of gigabytes of disk, and takes
hours. Even then its images wouldn't match ee1os's byte for byte, because ee1os signs with its
own keys and every build carries its own number and time. Comparing the source is the check
that works.</p>
<p>For any of the projects (here {e(first['name'])}), in a terminal with git:</p>
<pre><span class="c"># 1. the ee1os fork, and the GrapheneOS release it is based on</span>
git clone {ORG}/{e(first['name'])} &amp;&amp; cd {e(first['name'])}
git fetch {UPSTREAM}/{e(first['name'])} refs/tags/{e(tag)}:refs/tags/{e(tag)}

<span class="c"># 2. the tag is GrapheneOS's (allowed signers: scripts/grapheneos-allowed-signers in {ORG}/ee1os)</span>
git -c gpg.ssh.allowedSignersFile=grapheneos-allowed-signers verify-tag {e(tag)}

<span class="c"># 3. the files this page lists as changed, with the same line counts</span>
git diff --stat --no-renames {e(tag)} {e(tagname)}

<span class="c"># 4. the git tree id in the table below: one hash over every file of the project</span>
git rev-parse {e(tagname)}^{{tree}}     <span class="c"># {e(first['tree'])}</span>

<span class="c"># 5. one file: its git blob id, then the SHA-256 of its bytes</span>
git rev-parse {e(tagname)}:&lt;path&gt;
git show {e(tagname)}:&lt;path&gt; | sha256sum</pre>
</section>

<section id="compared">
<h2>What was compared</h2>
<p>GrapheneOS release tag <code>{e(tag)}</code>, its signature checked against GrapheneOS's
signing key in each of these projects and in the release manifest, against tag
<code>{e(tagname)}</code> in each <a href="{ORG}">ee1os fork</a>. That tag is never moved. Click
a hash to copy it.</p>
<div class="scroll"><table>
<thead><tr><th>Project</th><th>Files</th><th>Changed</th><th>GrapheneOS commit · git tree id</th><th>ee1os commit · git tree id</th><th>Diff</th></tr></thead>
<tbody>{fk_rows}</tbody></table></div>

<h3 id="also-in-build">Also in the build</h3>
<div class="scroll"><table>
<thead><tr><th>What</th><th>Where it comes from</th><th>Hashes</th></tr></thead>
<tbody>{extra_rows}</tbody></table></div>
<p class="muted">Device files aren't kept in a source project: for each phone model, adevtool
extracts them from Google's factory image. The content hash covers every file of the generated
directory.</p>
</section>

<section id="unchanged">
<h2>Unchanged</h2>
<p>Of the {n(t['files'])} files in the {np} projects, {n(t['identical'])} are byte for byte
GrapheneOS's; the full list, with each file's git blob id and SHA-256, is in the downloads at the
end. The other {n(t['other_projects'])} projects of the build are at exactly the revisions pinned
by GrapheneOS's signed release manifest; the build checks this before every release and stops
otherwise.</p>
</section>

<section id="changes">
<h2>What ee1os changed, and why</h2>
<p>The changes are grouped by what they do. Each group says what changed and why, then lists its
commits and the files they changed. Hashes on the left are GrapheneOS's file, on the right
ee1os's: the git blob id first, then the SHA-256 of the file's bytes. A file in more than one
group is shown in each and counted once. Line counts are for the whole file, GrapheneOS's
version against ee1os's.</p>
{groups}
</section>

<section id="downloads">
<h2>Downloads</h2>
<div class="scroll"><table>
<thead><tr><th>File</th><th>What</th><th>SHA-256</th></tr></thead>
<tbody>
<tr><td><a href="report.json">report.json</a></td><td class="wrap">This page as data.</td><td><span class="muted">—</span></td></tr>
<tr><td><a href="{RELEASES}/download/{e(bn)}/{e(r['downloads']['tsv'])}">{e(r['downloads']['tsv'])}</a></td><td class="wrap">Every file of the {np} projects with its git blob id and SHA-256, on both sides.</td><td>{h(r['downloads'].get('tsv_sha256'))}</td></tr>
</tbody></table></div>
<p class="muted">Made from ee1os commit <a href="{ORG}/ee1os/commit/{e(r['os_commit'])}"><code>{e(r['os_commit'][:12])}</code></a>,
which holds the list of approved commits and the texts on this page.</p>
</section>
"""
    title = f"{bn} compared with GrapheneOS"
    desc = f"ee1os {bn} against GrapheneOS {tag}, file by file, and why each change was made."
    return HEAD.format(title=e(title), description=e(desc)) + body + FOOT


def render_index(reports):
    items = "".join(
        f'<li><a href="/changes/{e(r["release"])}/"><b>ee1os {e(r["release"])}</b></a> '
        f'<span class="muted">· GrapheneOS {e(r["upstream"]["tag"])} · {n(r["totals"]["changed"])} '
        f'files changed in {len(r["forks"])} projects</span></li>'
        for r in sorted(reports, key=lambda r: r["release"], reverse=True))
    body = f"""<header class="page-head">
<h1>What differs from GrapheneOS</h1>
<p class="lead">For each stable release: every file ee1os changed in GrapheneOS's source, with
hashes on both sides, and why. Newest first.</p>
</header>
{f'<ol class="releases">{items}</ol>' if items else '<p>No stable release has a page yet.</p>'}
"""
    return HEAD.format(title="Changes", description="ee1os against GrapheneOS, file by file, per release.") + body + FOOT
