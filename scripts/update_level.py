#!/usr/bin/env python3
"""Is an update important, i.e. should a phone that is kept switched off be updated now?
(doc 08, *Important updates*; the site shows it on its home page and /updates.)

  update_level.py record <tag> [--facts F] [--review R]
                        what a GrapheneOS release we take brings, written once to
                        $WS/state/levels/<base>-<tag>.json (track-upstream.sh, when it is taken)
  update_level.py build <bn> <model>
                        the level of a release build, from everything since the last published
                        update: releases/<bn>/update-<model>.json, never rewritten (release.sh)
  update_level.py ask <model>:<bn>...
                        the proposal in words for the Publish question; the first line is
                        the level alone (release-models.sh)
  update_level.py add <bn> <model> [important|routine]
                        put a published build into the site's updates.json; a level given here
                        is the owner's and wins over the proposal (publish-release.sh)

Levels: important, routine, undecided. Important: a bypass of the lock screen, USB protection,
PINs, encryption or verified boot, a compromise over the network or radio without the user
doing anything, a hole that is being exploited, or an important fix of our own. A higher
security patch level alone is routine. What can't be decided is undecided, never routine.

Evidence (record):
  facts   upstream-watch.py classify: commit titles that name such a bypass, exploitation in the
          release notes, projects whose commits can't be read, the patch level
  bulletins  Google's Android and Pixel bulletins between the two patch levels: critical
          entries for the bootloader, key storage and radios, and exploited ones
  review  the "# Importance" section of the review of the check report, if there is one
A single word like "credential" in a title proves nothing; it only counts through the review.
Routine needs a review that says so and nothing against it.

Upstream text never reaches the site: the reasons there are made of our own phrases (CODES).
"""
import datetime
import fcntl
import hashlib
import html
import json
import os
import re
import subprocess
import sys

WS = os.environ.get("EE1OS_WS", "/mnt/flash/scratch/grapheneos")
ENVS = os.environ.get("EE1OS_ENVS", "/mnt/flash/home/faeton/work/ee1os/os")
SITE = os.environ.get("EE1OS_SITE", "/mnt/flash/home/faeton/work/ee1os/site")
STATE = os.path.join(WS, "state")
LEVELS = os.path.join(STATE, "levels")
RELEASES = os.path.join(WS, "grapheneos-17", "releases")
BULLETINS = os.environ.get("EE1OS_BULLETINS", "https://source.android.com/docs/security/bulletin")

TAG = re.compile(r"[0-9]{10}")
MODEL = re.compile(r"[a-z0-9]{1,30}")
DAY = re.compile(r"20[0-9]{2}-[0-9]{2}-[0-9]{2}")

# what an important update fixes, in the order the site names them: English, Russian
CODES = {
    "exploited": ("a vulnerability that is being exploited", "уязвимость, которую уже используют"),
    "lock-screen": ("a lock screen bypass", "обход экрана блокировки"),
    "usb": ("USB access to a locked phone", "доступ по USB к заблокированному телефону"),
    "pin": ("PIN and password protection", "защита PIN-кода и пароля"),
    "encryption": ("encryption and key storage", "шифрование и хранение ключей"),
    "boot": ("the bootloader and verified boot", "загрузчик и проверка при загрузке"),
    "remote": ("attacks over the network or radio", "атаки через сеть или радиомодуль"),
    "own": ("a fault in ee1os itself", "ошибка в самой ee1os"),
}
# groups of patches/changes.toml whose commits can't make an update important
PLAIN_GROUPS = {"branding", "look", "apps", "tests"}

_LOCK = re.compile(r"lock.?screen|keyguard|bouncer", re.I)
_PIN = re.compile(r"locksettings|lock settings|weaver|gatekeeper|duress|synthetic password|"
                  r"\bPINs?\b", re.I)
_USB = re.compile(r"\busb\b", re.I)
_CRYPT = re.compile(r"fscrypt|file.based encryption|metadata encryption|\bkeymint\b|keystore2?\b",
                    re.I)
_BOOT = re.compile(r"verified boot|\bavb\b|bootloader|rollback (protection|index)", re.I)
_BYPASS = re.compile(r"bypass|circumvent", re.I)
_LOCKED = re.compile(r"lockdown|while (the (phone|device) is )?locked|when locked", re.I)
_REMOTE = re.compile(r"remote code execution|\bRCE\b|zero.click", re.I)
_EXPLOITED = re.compile(r"(actively|being|been|limited, targeted)\W.{0,20}exploit|in the wild", re.I)
_MAYBE = re.compile(r"exploited|exploitable|in the wild", re.I)
_NOT = re.compile(r"\b(no|not|never|without|isn't|aren't|wasn't)\b.{0,40}$", re.I)


def title_codes(subject):
    """The kinds of hole a commit title says it fixes. Reverts and fixups don't count."""
    if subject.startswith(("Revert", "fixup!")):
        return []
    out = []
    if _BYPASS.search(subject):
        out += [c for c, rx in (("lock-screen", _LOCK), ("usb", _USB), ("pin", _PIN),
                                ("encryption", _CRYPT), ("boot", _BOOT)) if rx.search(subject)]
    if _USB.search(subject) and _LOCKED.search(subject) and "usb" not in out:
        out.append("usb")
    if _REMOTE.search(subject):
        out.append("remote")
    return out


def exploited(text):
    """'yes' when the text says a hole is being exploited, 'maybe' when it only has the word."""
    for m in _EXPLOITED.finditer(text):
        if not _NOT.search(text[max(0, m.start() - 60):m.start()]):
            return "yes"
    return "maybe" if _MAYBE.search(text) else ""


# ---- Google's bulletins ----

def _text(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()


def bulletin_rows(page, pixel, lo, hi):
    """[(cve, type, severity, section, component)] of the entries between two patch levels."""
    part = None
    if pixel:
        m = re.search(r"security patch\s+levels of\s+(20\d\d-\d\d-\d\d)\s+or later", _text(page))
        if not m:
            raise ValueError("the Pixel bulletin doesn't name its patch level")
        part = m.group(1)
        # asked for because its level should be in the range: if the page says otherwise it can't be
        # used, rather than counting as a bulletin with nothing in it
        if not lo < part <= hi:
            raise ValueError(f"the Pixel bulletin names {part}")
    rows, section, parts = [], "", {part} if part else set()
    for m in re.finditer(r"(?s)<h([23])\b[^>]*>(.*?)</h\1>|<tr\b[^>]*>(.*?)</tr>", page):
        if m.group(2) is not None:
            section = _text(m.group(2))
            d = re.match(r"(20\d\d-\d\d-\d\d) security patch level", section)
            if d and not pixel:
                part = d.group(1)
                parts.add(part)
            continue
        cells = [_text(c) for c in re.findall(r"(?s)<td\b[^>]*>(.*?)</td>", m.group(3))]
        cve = re.match(r"CVE-\d{4}-\d{3,7}\b", cells[0]) if cells else None
        if cve and len(cells) >= 4 and part and lo < part <= hi:
            rows.append((cve.group(0), cells[-3], cells[-2], section, cells[-1]))
    if not parts:
        raise ValueError("no patch level in the bulletin")
    return rows


def row_code(row, pixel):
    """What a critical entry is about, or None. Component names of other vendors don't count."""
    _, kind, severity, section, comp = row
    if severity != "Critical":
        return None
    if pixel:
        if re.search(r"\bbootloader\b|^LK$", comp, re.I):
            return "boot"
        if re.search(r"keymint|secure element|weaver|gatekeeper|titan", comp, re.I):
            return "encryption"
        if kind == "RCE" and re.search(r"modem|baseband|bluetooth|wi-?fi|wlan|ims", comp, re.I):
            return "remote"
        return None
    if kind == "RCE" and re.match(r"framework|system|kernel", section, re.I):
        return "remote"
    return None


def fetch(url):
    return subprocess.run(["curl", "-fsSL", "-m", "30", url], capture_output=True, text=True,
                          check=True).stdout


def months(lo, hi):
    """YYYY-MM of every bulletin between two patch levels."""
    y, m = int(lo[:4]), int(lo[5:7])
    out = []
    while f"{y:04d}-{m:02d}" <= hi[:7]:
        out.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
        if len(out) > 24:
            raise ValueError(f"patch levels too far apart: {lo}, {hi}")
    return out


def bulletins(lo, hi):
    """(evidence, unread, lines for the report) of the bulletins between two patch levels."""
    found, unread, lines = [], [], []
    if not (DAY.fullmatch(lo) and DAY.fullmatch(hi)):
        return [], [f"patch levels {lo!r}, {hi!r}"], []
    if hi <= lo:
        return [], [], []
    for ym in months(lo, hi):
        for name, path in (("Android", ""), ("Pixel", "pixel/")):
            # each bulletin only if one of its patch levels is in the range
            if name == "Pixel" and not lo < f"{ym}-05" <= hi:
                continue
            if name == "Android" and not (lo < f"{ym}-01" <= hi or lo < f"{ym}-05" <= hi):
                continue
            label = f"{name} bulletin {ym}"
            try:
                page = fetch(f"{BULLETINS}/{path}{ym[:4]}/{ym}-01")
                rows = bulletin_rows(page, name == "Pixel", lo, hi)
            except Exception as e:
                unread.append(f"{label}: {type(e).__name__}")
                continue
            for r in rows:
                if r[2] == "Critical":
                    lines.append(f"{label}: {r[0]} {r[1]} critical, {r[3]} / {r[4]}")
                code = row_code(r, name == "Pixel")
                if code:
                    found.append({"code": code, "where": f"{label}: {r[0]} {r[1]}, {clean(r[4], 40)}"})
            if exploited(_text(page)) == "yes":
                found.append({"code": "exploited", "where": f"{label}: says a hole is exploited"})
                lines.append(f"{label}: says a vulnerability may be exploited")
    return found, unread, lines


# ---- the review ----

def clean(s, n):
    """One printable line: for messages and logs, never for the site."""
    return re.sub(r"[^\x20-\x7eА-Яа-яЁё–—’“”]+", " ", s).strip()[:n]


def parse_review(text):
    """{"level", "codes", "why"} from the one "# Importance" section, or None."""
    heads = [(m.start(), m.end(), m.group(1).strip()) for m in re.finditer(r"^#{1,3} (.+)$", text, re.M)]
    mine = [i for i, h in enumerate(heads) if h[2].lower() == "importance"]
    if len(mine) != 1:
        return None
    i = mine[0]
    body = text[heads[i][1]:heads[i + 1][0] if i + 1 < len(heads) else len(text)]
    got = {}
    for line in body.splitlines():
        m = re.match(r"\s*[-*]?\s*(Level|Topics|Why):\s*(.*)$", line)
        if m:
            if m.group(1) in got:
                return None
            got[m.group(1)] = m.group(2).strip()
    level = got.get("Level", "").strip("`* ").lower()
    codes = [c for c in re.split(r"[,\s]+", got.get("Topics", "").strip("`* ").lower())
             if c and c != "none"]
    if level not in ("important", "routine", "unsure") or any(c not in CODES for c in codes):
        return None
    if level == "important" and not codes:
        return None
    return {"level": level, "codes": codes if level == "important" else [],
            "why": clean(got.get("Why", ""), 300)}


# ---- deciding ----

def order(codes):
    return [c for c in CODES if c in codes]


def decide(facts, review, found, unread):
    """(level, codes, notes) for one upstream release."""
    notes = []
    strong = list(found)
    unread = list(unread)
    maybe = False
    if facts is None:
        unread.append("what changed could not be read")
    else:
        strong += facts.get("strong", [])
        unread += facts.get("unread", [])
        if facts.get("exploited") == "yes":
            strong.append({"code": "exploited", "where": "the release notes say a hole is exploited"})
        maybe = facts.get("exploited") == "maybe"
    codes = order({s["code"] for s in strong})
    # at most two of a kind, with how many more there are
    for c in codes:
        w = [clean(s["where"], 160) for s in strong if s["code"] == c]
        notes += w[:2] + ([f"{len(w) - 2} more like these ({c})"] if len(w) > 2 else [])
    if review and review["why"]:
        notes.append("review: " + review["why"])
    if unread:
        notes.append("not read: " + clean("; ".join(unread), 300))
    said = review["level"] if review else None
    if said == "important":
        return "important", order(set(codes) | set(review["codes"])), notes
    if codes and said == "routine":
        return "undecided", codes, ["the review says routine, but:"] + notes
    if codes:
        return "important", codes, notes
    if said == "routine" and not unread and not maybe:
        return "routine", [], notes
    if maybe:
        notes.append('the release notes have the word "exploited" or "exploitable"')
    if said is None:
        notes.append("no review that says how important it is")
    elif said == "unsure":
        notes.append("the review couldn't tell")
    return "undecided", [], notes


def combine(levels):
    if "important" in levels:
        return "important"
    if not levels or any(l != "routine" for l in levels):
        return "undecided"
    return "routine"


def reason(level, codes, tag, patch_level, upstream_moved):
    """The draft for the site, in English and Russian."""
    if level == "undecided":
        return {"en": "", "ru": ""}
    if level == "important":
        if not codes:
            return {"en": "Important security fixes.", "ru": "Важные исправления безопасности."}
        return {"en": "Fixes: " + "; ".join(CODES[c][0] for c in codes) + ".",
                "ru": "Исправлено: " + "; ".join(CODES[c][1] for c in codes) + "."}
    if not upstream_moved:
        return {"en": "Changes in ee1os itself.", "ru": "Изменения в самой ee1os."}
    if patch_level:
        return {"en": f"GrapheneOS {tag}, security patch level {patch_level}.",
                "ru": f"GrapheneOS {tag}, уровень исправлений безопасности {patch_level}."}
    return {"en": f"GrapheneOS {tag}.", "ru": f"GrapheneOS {tag}."}


# ---- files ----

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.rename(tmp, path)


def site_updates():
    """The site's updates.json; its updates are newest first."""
    return load(os.path.join(SITE, "updates.json"))


def builds_of(update):
    return {m: b["build"] for m, b in update["builds"].items()}


def published_report(update):
    """The changes report of one build of a published update."""
    for bn in sorted(builds_of(update).values()):
        p = os.path.join(SITE, "changes", bn, "report.json")
        if os.path.isfile(p):
            return load(p)
    return None


def commits(report):
    """{(repo, subject): group} of a changes report. A rebase changes ids, not subjects."""
    return {(c["repo"], c["subject"]): g["slug"] for g in report["groups"] for c in g["commits"]}


def source_id(report):
    """Names the fork commits a build was made from: builds of one update share it."""
    s = "\n".join(sorted(f"{f['name']} {f['commit']}" for f in report["forks"]))
    return hashlib.sha256(s.encode()).hexdigest()[:12]


def own_line(repo, group, subject):
    return f"- `{repo}` ({group}) {subject}"


def own_waiting():
    """Approved fork commits that no published update has yet: [(repo, group, subject)]."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ledger
    with open(os.path.join(ENVS, "patches", "approved.txt"), encoding="utf-8") as f:
        approvals, errors = ledger.parse_approved(f.read())
    if errors:
        raise ValueError(errors[0])
    ups = site_updates()["updates"]
    have = commits(published_report(ups[0]) or {"groups": []}) if ups else {}
    return [(a.repo, a.group, a.subject) for a in approvals if (a.repo, a.subject) not in have]


# ---- commands ----

def record(tag, facts_path, review_path):
    with open(os.path.join(STATE, "upstream-tag")) as f:
        base = f.read().strip()
    if not (TAG.fullmatch(tag) and TAG.fullmatch(base)):
        raise ValueError("no release tags")
    if tag <= base:
        print(f"{tag} isn't newer than {base}: nothing to record")
        return 0
    path = os.path.join(LEVELS, f"{base}-{tag}.json")
    if os.path.exists(path) and load(path)["level"] != "undecided":
        print(f"{path}: already decided, kept")
        return 0
    facts = review = None
    problems = []
    try:
        facts = load(facts_path) if facts_path else None
        if facts is not None and (facts["base"], facts["target"]) != (base, tag):
            facts, problems = None, ["the facts are of another release"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        facts, problems = None, [f"facts: {type(e).__name__}"]
    try:
        if review_path:
            with open(review_path, encoding="utf-8", errors="replace") as f:
                review = parse_review(f.read())
    except OSError:
        pass
    found, unread = [], []
    lo = hi = ""
    if facts:
        try:
            lo, hi = facts["patch_level"]
            found, unread, _ = bulletins(lo, hi)
        except (KeyError, ValueError, TypeError) as e:
            unread = [f"bulletins: {type(e).__name__}"]
    try:
        # what the review had in front of it: only the lines its report really has
        with open(re.sub(r"-review\.md$", ".md", review_path), encoding="utf-8", errors="replace") as f:
            shown = set(f.read().splitlines())
        own = [[r, s] for r, g, s in own_waiting() if own_line(r, g, s) in shown]
    except Exception:
        own = []
    level, codes, notes = decide(facts, review, found, unread + problems)
    save(path, {"base": base, "tag": tag, "level": level, "codes": codes, "notes": notes,
                "patch_level": hi if DAY.fullmatch(hi or "") and hi > lo else "",
                "own_reviewed": own if review and review["level"] in ("important", "routine") else [],
                "time": now()})
    print(f"{tag}: {level} {' '.join(codes)} ({path})")
    return 0


def chain(frm, to):
    """The records between one upstream release and another, or None when they don't connect.
    Every record that lies on some way from one to the other counts, not just one way's."""
    recs = []
    for n in os.listdir(LEVELS) if os.path.isdir(LEVELS) else []:
        if re.fullmatch(r"[0-9]{10}-[0-9]{10}\.json", n):
            try:
                r = load(os.path.join(LEVELS, n))
                if n == f"{r['base']}-{r['tag']}.json" and r["base"] < r["tag"]:
                    recs.append(r)
            except (OSError, ValueError, KeyError, TypeError):
                pass

    def reach(start, a, b):
        got, new = {start}, [start]
        while new:
            t = new.pop()
            for r in recs:
                if r[a] == t and r[b] not in got and frm <= r["base"] and r["tag"] <= to:
                    got.add(r[b])
                    new.append(r[b])
        return got
    after, before = reach(frm, "base", "tag"), reach(to, "tag", "base")
    if to not in after:
        return None
    return sorted((r for r in recs if r["base"] in after and r["tag"] in before), key=lambda r: (r["base"], r["tag"]))


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def level_path(bn, model):
    return os.path.join(RELEASES, bn, f"update-{model}.json")


def work_out(bn, model):
    rep = load(os.path.join(RELEASES, bn, "changes", "report.json"))
    tag, src = rep["upstream"]["tag"], source_id(rep)
    out = {"build": bn, "model": model, "upstream": tag, "source": src, "time": now()}
    try:
        ups = site_updates()["updates"]
        # the same update as one already published for another model: the range before it
        # (or this model's own build of it, when the same source is built again)
        prev = next((u for u in ups if (u["upstream"], u["source"]) != (tag, src)
                     or model in u["builds"]), None)
        if prev is None:
            raise ValueError("no published update to compare with")
        prep = published_report(prev)
        recs = chain(prev["upstream"], tag)
        if recs is None:
            raise ValueError(f"no record of what is between GrapheneOS {prev['upstream']} and {tag}")
        levels, codes, notes = [r["level"] for r in recs], set(), []
        for r in recs:
            codes |= set(r["codes"])
            notes += [f"{r['tag']}: {n}" for n in r["notes"]]
        if prep is None:
            raise ValueError("no changes report of the last published update")
        have, mine = commits(prep), commits(rep)
        seen = {tuple(x) for r in recs for x in r["own_reviewed"]}
        fresh = [k for k, g in mine.items() if k not in have and g not in PLAIN_GROUPS]
        unseen = [s for r, s in fresh if (r, s) not in seen]
        if unseen:
            levels.append("undecided")
            notes.append("our own changes not judged yet: " + "; ".join(clean(s, 100) for s in unseen[:5])
                         + (f" and {len(unseen) - 5} more" if len(unseen) > 5 else ""))
        elif not recs:
            levels.append("routine")
        level = combine(levels)
        pl = max([r["patch_level"] for r in recs] or [""])
        out.update(level=level, codes=order(codes), notes=notes, since=prev["upstream"],
                   reason=reason(level, order(codes), tag, pl, tag != prev["upstream"]))
    except Exception as e:
        out.update(level="undecided", codes=[], notes=[clean(str(e) or type(e).__name__, 200)],
                   reason={"en": "", "ru": ""})
    return out


def build(bn, model):
    path = level_path(bn, model)
    if os.path.exists(path):
        print(f"{path}: already there, kept")
        return 0
    out = work_out(bn, model)
    save(path, out)
    print(f"{model} {bn}: {out['level']} {' '.join(out['codes'])}")
    return 0


def build_level(bn, model):
    try:
        d = load(level_path(bn, model))
        if d["level"] in ("important", "routine", "undecided") and d["build"] == bn and d["model"] == model:
            return d
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {"level": "undecided", "codes": [], "notes": ["no level recorded with the build"],
            "reason": {"en": "", "ru": ""}}


def ask(pairs):
    got = [build_level(bn, model) for model, bn in pairs]
    level = combine([d["level"] for d in got])
    top = next((d for d in got if d["level"] == level), got[0])
    print(level)
    print({"important": "For the site: IMPORTANT update.", "routine": "For the site: routine update.",
           "undecided": "For the site: NOT DECIDED whether it is important; the site can't be "
                        "deployed until it is."}[level])
    if top["reason"]["en"]:
        print(top["reason"]["en"])
    for n in top["notes"][:8]:
        print(f"- {clean(n, 220)}")
    if len(top["notes"]) > 8:
        print(f"- and {len(top['notes']) - 8} more")
    return 0


def add(bn, model, owner):
    # one at a time: two models may be published at once
    lock = os.open(SITE, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return add_locked(bn, model, owner)
    finally:
        os.close(lock)


def add_locked(bn, model, owner):
    d = build_level(bn, model)
    rep = load(os.path.join(RELEASES, bn, "changes", "report.json"))
    tag, src = rep["upstream"]["tag"], source_id(rep)
    doc = site_updates()
    ups = doc["updates"]
    if any(b["build"] == bn and m == model for u in ups for m, b in u["builds"].items()):
        print(f"{model} {bn} is already in updates.json")
        return 0
    entry = {"build": bn, "published": now()}
    u = next((u for u in ups if (u["upstream"], u["source"]) == (tag, src) and model not in u["builds"]), None)
    level = owner or d["level"]
    if u is None:
        text = d["reason"]
        if level != d["level"]:
            moved = not ups or ups[0]["upstream"] != tag
            text = reason(level, d["codes"], tag, "", moved)
        u = {"upstream": tag, "source": src, "level": level, "reason": dict(text), "builds": {}}
        if owner:
            # by the owner, knowing this proposal; a more serious one for another model counts again
            u["decided"] = d["level"]
        ups.insert(0, u)
    elif owner and owner != u["level"] and (owner == "important" or u["level"] == "undecided"):
        # another model's build of the same update: the owner can still decide or raise it;
        # otherwise the level and a text that may have been edited stay
        u["level"], u["reason"], u["decided"] = owner, reason(owner, d["codes"], tag, "", True), d["level"]
    elif not owner and combine([u["level"], u.get("decided", u["level"]), level]) != combine([u["level"], u.get("decided", u["level"])]):
        # this build's level is the more serious one: never drop that silently
        print(f"the update was {u['level']} in updates.json, now {level} as {model} {bn} says")
        u["level"] = level
        if d["reason"]["en"]:
            u["reason"] = dict(d["reason"])
    elif level != u["level"]:
        print(f"the update is already {u['level']} in updates.json, kept; {model} {bn} says {level}")
    u["builds"][model] = entry
    if model not in doc["models"]:
        print(f"{model} has no name under models in updates.json yet; the site won't build without it")
    ups.sort(key=lambda x: min(builds_of(x).values()), reverse=True)
    save(os.path.join(SITE, "updates.json"), doc)
    print(f"{model} {bn} added to updates.json: {u['level']}")
    return 0


def main(argv):
    cmd, args = (argv[1] if len(argv) > 1 else ""), argv[2:]

    def opt(name):
        if name in args:
            i = args.index(name)
            v = args[i + 1]
            del args[i:i + 2]
            return v
        return None
    try:
        if cmd == "record":
            facts, review = opt("--facts"), opt("--review")
            if len(args) == 1 and TAG.fullmatch(args[0]):
                return record(args[0], facts, review)
        elif cmd == "build" and len(args) == 2 and TAG.fullmatch(args[0]) and MODEL.fullmatch(args[1]):
            return build(*args)
        elif cmd == "ask" and args:
            pairs = [tuple(a.split(":")) for a in args]
            if all(len(p) == 2 and MODEL.fullmatch(p[0]) and TAG.fullmatch(p[1]) for p in pairs):
                return ask(pairs)
        elif cmd == "add" and len(args) in (2, 3) and TAG.fullmatch(args[0]) and MODEL.fullmatch(args[1]) \
                and (len(args) == 2 or args[2] in ("", "important", "routine")):
            return add(args[0], args[1], args[2] if len(args) == 3 else "")
    except Exception as e:
        print(f"update_level {cmd}: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
