#!/usr/bin/env python3
"""Telegram buttons for track-upstream.sh (doc 08, *Buttons*).

  press.py ask <tag> <action>=<label>...   post the text on stdin in the OS topic with one
                                           button per action; exit 3 if buttons aren't set up
  press.py handle                          take the presses waiting in the inbox (does nothing
                                           when it is empty)
  press.py watch                           handle every 2 seconds for most of a minute (cron,
                                           every minute), so a press is answered in seconds

Actions, each for one tag and nothing else:
  push     APPROVE=<tag> track-upstream.sh         (a release held after its build)
  approve  approve-held.sh <tag>, then APPROVE=    (rebased commits waiting for approval)
  skip     SKIP=<tag> track-upstream.sh
  take     FORCE_TAG=<tag> track-upstream.sh       (a release left for the next monthly one)

A button carries a random one-time string, `ee1os:<22 chars>`; only its SHA-256 is kept here.
A press arrives as one JSON file in the inbox: {"v":1,"data":..,"from_id":..,"chat_id":..,
"message_id":..}, written by the relay that receives the bot's updates. It counts only if the
string is known and unused, the presser is the owner, and chat and message are the ones the
button was posted in. Whoever can write the inbox can claim to be the owner: the buttons are
a convenience, not a signature (doc 07 *Design notes*).

Settings are outside the repo, in /mnt/tank/scripts/ee1os/press.conf (JSON): owner_id,
chat_id, thread_id. Without that file `ask` exits 3 and the caller sends plain text.
"""
import base64
import fcntl
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.parse
import urllib.request

WS = os.environ.get("PRESS_WS", "/mnt/flash/scratch/grapheneos")
ENVS = os.environ.get("PRESS_ENVS", "/mnt/flash/home/faeton/work/ee1os/os")
CONF = os.environ.get("PRESS_CONF", "/mnt/tank/scripts/ee1os/press.conf")
API = os.environ.get("PRESS_API", "https://api.telegram.org")
STATE = os.path.join(WS, "state")
DIR = os.path.join(STATE, "press")
OPEN, DONE, INBOX, JUNK = (os.path.join(DIR, d) for d in ("open", "done", "inbox", "junk"))
LOG = os.path.join(WS, "press.log")
ACTIONS = ("push", "approve", "skip", "take")
TAG = re.compile(r"^[0-9]{10}$")
DATA = re.compile(r"^ee1os:[A-Za-z0-9_-]{22}$")
LIFETIME = 30 * 86400      # a held release can wait; what a press may do is checked again then
MAX_PRESS = 1024           # bytes of one inbox file
MAX_INBOX = 50             # presses taken in one run; the rest is thrown away
MAX_TEXT = 3900            # Telegram takes 4096 characters
NAME = re.compile(r"[0-9]{1,30}\.[0-9]{1,10}\.json")   # what the relay names a press


def log(msg):
    with open(LOG, "a", errors="backslashreplace") as f:
        f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), msg))


def conf():
    with open(CONF) as f:
        c = json.load(f)
    return {k: int(c[k]) for k in ("owner_id", "chat_id", "thread_id")}


def token():
    t = os.environ.get("PRESS_TOKEN")
    if t:
        return t
    out = subprocess.run(["midclt", "call", "alertservice.query"], capture_output=True,
                         text=True, timeout=60, check=True).stdout
    return next(a["attributes"]["bot_token"] for a in json.loads(out)
                if a["attributes"]["type"] == "Telegram")


def api(method, **params):
    body = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request("%s/bot%s/%s" % (API, token(), method), data=body)
    with urllib.request.urlopen(req, timeout=20) as r:
        reply = json.load(r)
    if reply.get("ok") is not True:
        raise RuntimeError("%s refused" % method)
    return reply["result"]


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def ask(tag, pairs):
    if not os.path.exists(CONF):
        return 3
    c = conf()
    text = sys.stdin.read().strip()[:MAX_TEXT]
    if not TAG.fullmatch(tag) or not text or not pairs:
        print("usage: press.py ask <tag> <action>=<label>... < text", file=sys.stderr)
        return 2
    buttons, records = [], []
    for pair in pairs:
        action, _, label = pair.partition("=")
        if action not in ACTIONS or not label:
            print("unknown action: %s" % pair, file=sys.stderr)
            return 2
        data = "ee1os:" + base64.urlsafe_b64encode(secrets.token_bytes(16)).decode().rstrip("=")
        buttons.append({"text": label, "callback_data": data})
        records.append({"hash": digest(data), "action": action, "label": label})
    for d in (OPEN, DONE):
        os.makedirs(d, mode=0o700, exist_ok=True)
    now = int(time.time())

    def store(message_id):
        for r in records:
            r.update(tag=tag, chat_id=c["chat_id"], message_id=message_id, text=text,
                     created=now, expires=now + LIFETIME, siblings=[x["hash"] for x in records])
            tmp = os.path.join(OPEN, r["hash"] + ".tmp")
            with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
                json.dump(r, f)
            os.rename(tmp, os.path.join(OPEN, r["hash"] + ".json"))

    # the records first, bound to no message yet (no press fits them): a message that was
    # sent never has buttons this side doesn't know
    store(None)
    try:
        msg = api("sendMessage", chat_id=c["chat_id"], message_thread_id=c["thread_id"],
                  text=text, reply_markup=json.dumps({"inline_keyboard": [buttons]}))
        store(int(msg["message_id"]))
    except Exception as e:
        for r in records:
            try:
                os.unlink(os.path.join(OPEN, r["hash"] + ".json"))
            except OSError:
                pass
        log("ask %s failed: %s" % (tag, type(e).__name__))
        return 1
    log("asked %s: %s (message %s)" % (tag, " ".join(r["action"] for r in records),
                                         msg["message_id"]))
    return 0


def still_wanted(action, tag):
    """Why this press can't do anything any more, or None."""
    held = read(os.path.join(STATE, "held-tag"))
    built = os.path.exists(os.path.join(STATE, "held-bn"))
    if action == "take":
        if held:
            return "%s is held, decide that first" % held
        if read(os.path.join(STATE, "skipped-tag")) != tag:
            return "%s is no longer the release that was left out" % tag
        ours = read(os.path.join(STATE, "upstream-tag"))
        if not TAG.fullmatch(ours) or tag <= ours:
            return "%s is not newer than what the forks are on" % tag
        return None
    if held != tag:
        return "%s is no longer held" % tag
    if action == "push" and not built:
        return "%s isn't built yet" % tag
    if action == "approve" and built:
        return "%s is already built; its commits are approved" % tag
    return None


def busy():
    """Why track-upstream.sh would leave at once without a word, or None."""
    try:
        with open(os.path.join(STATE, "track.lock"), "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return "the nightly run is working"
    if os.environ.get("PRESS_RUN"):
        return None
    try:
        names = subprocess.run(["sudo", "-n", "docker", "ps", "--format", "{{.Names}}"],
                               capture_output=True, text=True, timeout=30).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return None
    return "a build is running" if "grapheneos-build" in names else None


def run(action, tag):
    """Start what the button stands for. Returns (ok, what to say). Never raises."""
    try:
        return start(action, tag)
    except Exception as e:
        return False, "failed (%s)" % type(e).__name__


def start(action, tag):
    env = {"push": "APPROVE", "approve": "APPROVE", "skip": "SKIP", "take": "FORCE_TAG"}[action]
    hook = os.environ.get("PRESS_RUN")      # tests: record instead of running
    if hook:
        rc = subprocess.run([hook, action, tag]).returncode
        return rc == 0, "started" if rc == 0 else "failed (exit %d)" % rc
    if action == "approve":
        p = subprocess.Popen([os.path.join(ENVS, "scripts/approve-held.sh"), tag],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
        try:
            out = p.communicate(timeout=600)[0]
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, 9)
            p.wait()
            return False, "not approved: approve-held.sh took too long"
        log("approve-held %s (exit %d): %s" % (tag, p.returncode, " / ".join(out.split("\n"))[:1500]))
        if p.returncode != 0:
            return False, "not approved: " + " / ".join(out.strip().splitlines()[-3:])[:300]
    # a build takes hours: its own tmux session, logged
    cmd = "cd %s && %s=%s scripts/track-upstream.sh >> %s 2>&1" % (ENVS, env, tag, LOG)
    p = subprocess.run(["tmux", "new-session", "-d", "-s", "ee1os-press-%s-%d" % (tag, time.time()),
                        cmd], capture_output=True, text=True)
    if p.returncode != 0:
        return False, "couldn't start: " + p.stderr.strip()[:200]
    return True, "started"


def settle(rec, note):
    """Say on the message what happened and take its buttons off."""
    try:
        api("editMessageText", chat_id=rec["chat_id"], message_id=rec["message_id"],
            text="%s\n\n%s" % (rec["text"][:MAX_TEXT - len(note)], note))
        return
    except Exception as e:  # the press is decided either way
        log("couldn't edit message %s: %s" % (rec["message_id"], type(e).__name__))
    try:   # at least no dead buttons
        api("editMessageReplyMarkup", chat_id=rec["chat_id"], message_id=rec["message_id"])
    except Exception as e:
        log("couldn't take the buttons off message %s: %s" % (rec["message_id"], type(e).__name__))


def say(c, text):
    try:
        api("sendMessage", chat_id=c["chat_id"], message_thread_id=c["thread_id"], text=text)
    except Exception as e:
        log("couldn't say %r: %s" % (text, type(e).__name__))


def one(path, c):
    """One inbox file. Never raises for what the file holds."""
    try:
        # the inbox is writable by another user: a plain file, no link, a few bytes
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as f:
            st = os.fstat(fd)
            if not (st.st_mode & 0o170000) == 0o100000:
                return "not a file"
            if st.st_size > MAX_PRESS:
                return "too large"
            p = json.loads(f.read(MAX_PRESS + 1))
        data = p["data"]
        ints = [p[k] for k in ("from_id", "chat_id", "message_id")]
    except (OSError, ValueError, KeyError, TypeError):
        return "not a press"
    if not isinstance(data, str) or not DATA.fullmatch(data) \
            or not all(type(i) is int for i in ints):
        return "not a press"
    h = digest(data)
    src = os.path.join(OPEN, h + ".json")
    try:
        with open(src) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return "unknown or used button"
    if p["from_id"] != c["owner_id"]:
        return "not the owner"                      # the button stays for the owner
    if p["chat_id"] != rec["chat_id"] or p["message_id"] != rec["message_id"]:
        return "not the message this button was posted in"
    why = None if time.time() > rec["expires"] else still_wanted(rec["action"], rec["tag"])
    if why is None and time.time() <= rec["expires"]:
        wait = busy()
        if wait:      # the button stays: the action would be lost, not queued
            say(c, "ee1os: %s can't start now, %s. Press again later." % (rec["label"], wait))
            return "busy: " + wait
    # used up from here on, whatever happens next; the rename decides between two runs
    dst = os.path.join(DONE, h + ".json")
    try:
        os.rename(src, dst)
    except OSError:
        return "unknown or used button"
    for s in rec.get("siblings", []):
        if s != h:
            try:
                os.rename(os.path.join(OPEN, s + ".json"), os.path.join(DONE, s + ".json"))
            except OSError:
                pass
    if time.time() > rec["expires"]:
        settle(rec, "This button expired.")
        return "expired"
    if why:
        settle(rec, "Nothing done: %s." % why)
        return "stale: " + why
    ok, said = run(rec["action"], rec["tag"])
    settle(rec, "%s: %s." % (rec["label"], said))
    return "%s %s: %s" % (rec["action"], rec["tag"], said)


def discard(path):
    """Get an inbox entry out of the way, whatever it is."""
    for rm in (os.unlink, os.rmdir):
        try:
            rm(path)
            return
        except OSError:
            pass
    # something this user can't delete (another user's directory with files in it): out of
    # the inbox, so it isn't met again every minute
    try:
        os.makedirs(JUNK, mode=0o700, exist_ok=True)
        os.rename(path, os.path.join(JUNK, "%d" % time.time_ns()))
        log("an inbox entry that can't be removed was moved to %s" % JUNK)
    except OSError as e:
        log("an inbox entry can't be removed or moved: %s" % type(e).__name__)


def handle():
    try:
        names = sorted(os.listdir(INBOX))
    except OSError:
        return 0
    if not names or not os.path.exists(CONF):
        return 0
    with open(os.path.join(DIR, "handle.lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        c = conf()
        taken = other = 0
        for n in names:
            path = os.path.join(INBOX, n)
            if not NAME.fullmatch(n):
                # a drop still being written (.tmp) is left for a minute; the rest goes unread
                try:
                    age = time.time() - os.lstat(path).st_mtime
                except OSError:
                    continue
                if n.endswith(".tmp") and 0 <= age < 60:
                    continue
                discard(path)
                other += 1
                continue
            taken += 1
            try:
                result = "dropped" if taken > MAX_INBOX else one(path, c)
            except Exception as e:
                result = "error %s" % type(e).__name__
            log("press %s: %s" % (n, result))
            discard(path)
        if other:
            log("%d other inbox entries removed" % other)
    return 0


def main(argv):
    if len(argv) >= 4 and argv[1] == "ask":
        return ask(argv[2], argv[3:])
    if len(argv) == 2 and argv[1] == "handle":
        return handle()
    if len(argv) == 2 and argv[1] == "watch":
        end = time.monotonic() + 56
        while True:
            handle()
            if time.monotonic() + 2 > end:
                return 0
            time.sleep(2)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
