#!/usr/bin/env python3
"""scripts/press.py against a local stand-in for the Bot API. Touches nothing outside a temp
directory and starts no real action (PRESS_RUN records what would run).
Run:  tests/press-test.py     prints PASS or FAIL per check, exits 1 if any failed."""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
PRESS = os.path.join(HERE, "..", "scripts", "press.py")
OWNER, CHAT, THREAD = 1001, -100500, 890
calls, fails = [], 0


class Api(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        params = {k: v[0] for k, v in urllib.parse.parse_qs(body.decode()).items()}
        calls.append((self.path.rsplit("/", 1)[1], params))
        out = json.dumps({"ok": True, "result": {"message_id": 100 + len(calls)}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def check(ok, what):
    global fails
    print("    %s: %s" % ("PASS" if ok else "FAIL", what))
    fails += 0 if ok else 1


with tempfile.TemporaryDirectory() as tmp:
    srv = http.server.HTTPServer(("127.0.0.1", 0), Api)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    state = os.path.join(tmp, "state")
    inbox = os.path.join(state, "press", "inbox")
    os.makedirs(inbox)
    ran = os.path.join(tmp, "ran")
    hook = os.path.join(tmp, "hook")
    with open(hook, "w") as f:
        f.write('#!/bin/sh\necho "$1 $2" >> %s\n[ ! -e %s/fail ]\n' % (ran, tmp))
    os.chmod(hook, 0o755)
    confp = os.path.join(tmp, "press.conf")
    env = dict(os.environ, PRESS_WS=tmp, PRESS_CONF=confp, PRESS_TOKEN="t", PRESS_RUN=hook, PRESS_NOWATCH="1",
               PRESS_API="http://127.0.0.1:%d" % srv.server_address[1])

    def press(*args, text=None):
        return subprocess.run([sys.executable, PRESS, *args], input=text, text=True, env=env,
                              capture_output=True)

    def ask(tag, *pairs):
        """Post a request; returns (message id, {action: callback_data})."""
        n = len(calls)
        r = press("ask", tag, *pairs, text="release %s" % tag)
        assert r.returncode == 0, r.stderr
        # the message with the buttons; closing an older offer comes before it
        n = next(i for i in range(n, len(calls)) if "reply_markup" in calls[i][1])
        kb = json.loads(calls[n][1]["reply_markup"])["inline_keyboard"][0]
        return 100 + n + 1, {p.split("=")[0]: b["callback_data"] for p, b in zip(pairs, kb)}

    def drop(data, from_id=OWNER, chat=CHAT, mid=None, raw=None, name=None):
        name = name or "%d.1.json" % time.time_ns()
        with open(os.path.join(inbox, name), "w") as f:
            f.write(raw if raw is not None else json.dumps(
                {"v": 1, "data": data, "from_id": from_id, "chat_id": chat, "message_id": mid}))
        r = press("handle")
        assert r.returncode == 0, r.stderr

    def runs():
        try:
            with open(ran) as f:
                return f.read().split("\n")[:-1]
        except OSError:
            return []

    def put(name, value):
        with open(os.path.join(state, name), "w") as f:
            f.write(value)

    print("## press.py")
    check(press("ask", "2026120100", "push=Push", text="x").returncode == 3,
          "without the settings file ask says so (exit 3) and posts nothing")
    check(not calls, "nothing was sent")
    with open(confp, "w") as f:
        json.dump({"owner_id": OWNER, "chat_id": CHAT, "thread_id": THREAD}, f)

    put("held-tag", "2026120100")
    put("held-bn", "2026120105")
    mid, b = ask("2026120100", "push=Push", "skip=Drop")
    sent = calls[-1]
    check(sent[0] == "sendMessage" and sent[1]["message_thread_id"] == str(THREAD)
          and sent[1]["chat_id"] == str(CHAT), "the request goes to the configured chat and topic")
    check(all(len(v) <= 64 and v.startswith("ee1os:") for v in b.values()),
          "buttons carry ee1os:<string> within Telegram's 64 bytes")
    stored = " ".join(open(os.path.join(state, "press", "open", n)).read()
                      for n in os.listdir(os.path.join(state, "press", "open")))
    check(not any(v in stored for v in b.values()), "the strings themselves aren't stored")

    drop(b["push"], from_id=OWNER + 1, mid=mid)
    check(runs() == [], "someone else's press does nothing")
    drop(b["push"], chat=CHAT - 1, mid=mid)
    drop(b["push"], mid=mid + 1)
    check(runs() == [], "a press from another chat or message does nothing")
    drop("ee1os:" + "A" * 22, mid=mid)
    drop("huta:a:" + "A" * 22, mid=mid)
    drop(None, raw="{not json", mid=mid)
    drop(None, raw="x" * 5000, mid=mid)
    drop(None, raw=json.dumps({"data": b["push"], "from_id": str(OWNER), "chat_id": CHAT,
                               "message_id": mid}))
    drop(None, raw=json.dumps({"data": b["push"] + "\n", "from_id": OWNER, "chat_id": CHAT,
                               "message_id": mid}))
    drop(None, raw=json.dumps({"data": b["push"], "from_id": True, "chat_id": CHAT,
                               "message_id": mid}))
    os.symlink(confp, os.path.join(inbox, "1.1.json"))
    os.symlink(confp, os.path.join(inbox, "link.json"))
    os.mkdir(os.path.join(inbox, "2.1.json"))
    os.mkfifo(os.path.join(inbox, "3.1.json"))
    open(os.path.join(inbox.encode(), b"0\xff.json"), "w").close()
    open(os.path.join(inbox, "0\nforged line.json"), "w").close()
    old = os.path.join(inbox, "old.tmp")
    open(old, "w").close()
    os.utime(old, (time.time() - 120, time.time() - 120))
    ahead = os.path.join(inbox, "ahead.tmp")
    open(ahead, "w").close()
    os.utime(ahead, (time.time() + 9999, time.time() + 9999))
    open(os.path.join(inbox, "fresh.tmp"), "w").close()
    for i in range(60):          # entries this user can't just unlink
        os.makedirs(os.path.join(inbox, "0%02d.json" % i, "x"))
    check(press("handle").returncode == 0 and runs() == [],
          "unknown strings, garbage, links, a fifo, directories and odd names do nothing")
    check(os.listdir(inbox) == ["fresh.tmp"], "the inbox is emptied, but for a drop being written")
    os.remove(os.path.join(inbox, "fresh.tmp"))
    logged = open(os.path.join(tmp, "press.log"), errors="replace").read()
    check("forged line" not in logged, "an odd file name doesn't get into the log")

    put("track.lock", "")
    import fcntl
    held_lock = open(os.path.join(state, "track.lock"))
    fcntl.flock(held_lock, fcntl.LOCK_EX)
    n = len(calls)
    drop(b["push"], mid=mid)
    check(runs() == [] and calls[-1][0] == "sendMessage" and "Press again" in calls[-1][1]["text"],
          "while the nightly run works the press is refused, and says so")
    held_lock.close()

    n = len(calls)
    drop(b["push"], mid=mid)
    check(runs() == ["push 2026120100"], "the owner's press starts the action")
    check(len(calls) == n + 1 and calls[-1][0] == "editMessageText"
          and "reply_markup" not in calls[-1][1] and "Push: started" in calls[-1][1]["text"],
          "the message says so and loses its buttons")
    drop(b["push"], mid=mid)
    drop(b["skip"], mid=mid)
    check(runs() == ["push 2026120100"], "a second press, or the other button, does nothing more")

    mid, b = ask("2026120100", "approve=Approve and build", "skip=Drop")
    drop(b["approve"], mid=mid)
    check(runs() == ["push 2026120100"] and "already built" in calls[-1][1]["text"],
          "Approve does nothing for a release that is already built")

    put("held-tag", "2026120200")
    mid, b = ask("2026120100", "push=Push")
    drop(b["push"], mid=mid)
    check(runs() == ["push 2026120100"] and "no longer held" in calls[-1][1]["text"],
          "a button for a release that is no longer held does nothing")

    os.remove(os.path.join(state, "held-bn"))
    mid, b = ask("2026120200", "approve=Approve and build", "skip=Drop")
    drop(b["approve"], mid=mid)
    check(runs()[-1] == "approve 2026120200", "Approve starts for the release held before its build")

    open(os.path.join(tmp, "fail"), "w").close()
    mid, b = ask("2026120200", "skip=Drop")
    drop(b["skip"], mid=mid)
    check("Drop: failed" in calls[-1][1]["text"], "an action that fails is reported on the message")
    os.remove(os.path.join(tmp, "fail"))

    put("upstream-tag", "2026110200")
    mid, b = ask("2026120300", "take=Take it anyway")
    put("skipped-tag", "2026120300")
    drop(b["take"], mid=mid)
    check(runs()[-1] != "take 2026120300", "Take does nothing while another release is held")
    os.remove(os.path.join(state, "held-tag"))
    mid, b = ask("2026120300", "take=Take it anyway")
    drop(b["take"], mid=mid)
    check(runs()[-1] == "take 2026120300", "Take starts for the release that was left out")
    put("upstream-tag", "2026120400")
    mid, b = ask("2026120300", "take=Take it anyway")
    n = len(runs())
    drop(b["take"], mid=mid)
    check(len(runs()) == n and "not newer" in calls[-1][1]["text"],
          "an old Take button can't move the forks back to an older release")
    put("upstream-tag", "2026110200")

    srv.shutdown()
    r = press("ask", "2026120300", "take=Take it anyway", text="x")
    check(r.returncode == 1 and os.listdir(os.path.join(state, "press", "open")) == [],
          "when the message can't be sent ask fails and leaves no open button")
    srv = http.server.HTTPServer(("127.0.0.1", 0), Api)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env["PRESS_API"] = "http://127.0.0.1:%d" % srv.server_address[1]

    mid, b = ask("2026120300", "take=Take it anyway")
    opend = os.path.join(state, "press", "open")
    for name in os.listdir(opend):
        path = os.path.join(opend, name)
        rec = json.load(open(path))
        rec["expires"] = int(time.time()) - 1
        json.dump(rec, open(path, "w"))
    n = len(runs())
    drop(b["take"], mid=mid)
    check(len(runs()) == n and "expired" in calls[-1][1]["text"], "an expired button does nothing")
    t = time.time()
    check(press("watch").returncode == 0 and time.time() - t < 10,
          "with no button that can be pressed the watch looks once and ends")
    ask("2026120300", "take=Take it anyway")
    try:
        subprocess.run([sys.executable, PRESS, "watch"], env=env, timeout=6)
        going = False
    except subprocess.TimeoutExpired:
        going = True
    check(going, "with an open button the watch keeps looking")
    put("ready", "2026120300\nhusky 2026120410\nstallion 2026120413\n")
    mid, b = ask("2026120300", "publish=Publish", "keep=Not now")
    lives = {r["action"]: r["expires"] - r["created"] for r in
             (json.load(open(os.path.join(opend, n))) for n in os.listdir(opend))
             if r["action"] in ("publish", "keep")}
    check(lives == {"publish": 86400, "keep": 86400}, "the Publish buttons are open for 24 hours")
    held_lock = open(os.path.join(state, "track.lock"))
    fcntl.flock(held_lock, fcntl.LOCK_EX)
    drop(b["publish"], mid=mid)
    held_lock.close()
    check(runs()[-1] == "publish 2026120300" and "Publish: started" in calls[-1][1]["text"],
          "Publish starts for the releases that are waiting, also while the nightly run works")
    n = len(runs())
    drop(b["keep"], mid=mid)
    check(len(runs()) == n, "Not now does nothing after Publish")
    put("ready", "2026120300\nhusky 2026120410\n")
    mid, b = ask("2026120300", "publish=Publish", "keep=Not now")
    put("ready", "2026120300\nhusky 2026120610\n")
    ask("2026120300", "publish=Publish", "keep=Not now")
    check(calls[-2][0] == "editMessageText" and calls[-2][1]["message_id"] == str(mid)
          and "Replaced" in calls[-2][1]["text"], "a new offer to publish closes the one before")
    drop(b["publish"], mid=mid)
    check(len(runs()) == n, "the older message's Publish does nothing for the newer builds")
    put("ready", "2026120300\nhusky 2026120610\n")
    for action in ("publish-important", "publish-routine"):
        mid, b = ask("2026120300", "publish=Publish", action + "=Publish as it says", "keep=Not now")
        drop(b[action], mid=mid)
        check(runs()[-1] == action + " 2026120300", "%s starts with its level" % action)
        n = len(runs())
        drop(b["publish"], mid=mid)
        check(len(runs()) == n, "and Publish on the same message does nothing after it")
    lives = {r["action"]: r["expires"] - r["created"] for r in
             (json.load(open(os.path.join(state, "press", "done", n))) for n in
              os.listdir(os.path.join(state, "press", "done"))) if r["action"].startswith("publish-")}
    check(set(lives.values()) == {86400} and len(lives) == 2, "they are open for 24 hours too")
    mid, b = ask("2026120300", "publish-important=Publish as important", "keep=Not now")
    n = len(runs())
    ask("2026120300", "publish=Publish", "keep=Not now")
    drop(b["publish-important"], mid=mid)
    check(len(runs()) == n, "a newer offer closes those as well")
    put("ready", "2026120400\nhusky 2026120510\n")
    mid, b = ask("2026120300", "publish=Publish", "keep=Not now")
    drop(b["publish"], mid=mid)
    check(len(runs()) == n and "no longer waiting" in calls[-1][1]["text"],
          "a Publish button for other releases than the ones waiting does nothing")
    os.remove(os.path.join(state, "ready"))
    check(press("ask", "2026120300", "rm=Remove", text="x").returncode == 2
          and press("ask", "nottag", "push=Push", text="x").returncode == 2,
          "ask refuses an unknown action and a malformed tag")

print("press: %s" % ("all passed" if not fails else "%d failed" % fails))
sys.exit(1 if fails else 0)
