#!/usr/bin/env bash
# Lock screen dispatch on the emulator, typed at the real bouncer (doc 04 *Lock screen*).
# Needs a freshly wiped emulator (EMU_ARGS=-wipe-data run.sh emulator); sets A, B and a reboot PIN.
# Run inside the build container:  run.sh exec /src/ee1os/tests/keyguard.sh
# Each PIN goes in as taps on the pad and as key events (those need the pad's focus).
# Screenshots of the bouncer come out black (secure window): what is on screen is read from
# uiautomator instead. Every check prints PASS or FAIL; the script exits 1 if any check failed.
set -uo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
A_PIN=111111 B_PIN=222222 REBOOT_PIN=333333
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-keyguard-T3.md}"
mkdir -p "$(dirname "$RES")"
FAILS=0

a()   { adb -s "$SERIAL" "$@"; }
sh_() { timeout 60 adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
log() { echo "$*" | tee -a "$RES"; }
pass() { log "    PASS: $*"; }
fail() { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }

conn() {
  local i
  for i in $(seq 30); do
    adb connect "$SERIAL" >/dev/null 2>&1
    [[ "$(timeout 10 adb -s "$SERIAL" shell echo ok 2>/dev/null | tr -d '\r')" == ok ]] && return 0
    sleep 2
  done
  return 1
}
ui() {
  sh_ "rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; \
    cat /data/local/tmp/ui.xml 2>/dev/null" || true
}
cur()   { sh_ am get-current-user; }
shown() { sh_ dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+' | cut -d= -f2; }
top()   { sh_ dumpsys activity activities | grep -m1 topResumedActivity | grep -oE 'u[0-9]+ [^ ]+'; }
# the bouncer's message line: a lockout shows "Try again in N seconds."
# (minutes or hours too, for longer lockouts). uiautomator needs the screen idle for a moment and
# the countdown changes every second, so a read is tried a few times
msg()       { ui | tr '>' '\n' | grep -oE 'text="[^"]*(Try again|Wrong|Enter|PIN)[^"]*"' | head -3 | tr '\n' ' '; }
countdown() {
  local i
  for i in 1 2 3; do
    ui | grep -qE 'Try again in [0-9]+ (seconds?|minutes?|hours?)' && return 0
    sleep 1
  done
  return 1
}
wait_user() {
  local i
  for i in $(seq 20); do [[ "$(cur)" == "$1" ]] && return 0; sleep 1; done
  return 1
}

declare -A K
keymap() {  # centre of each key on the pad that is up now
  local x d
  x="$(ui | tr '>' '\n')"
  for d in 0 1 2 3 4 5 6 7 8 9 _enter; do
    K[$d]="$(echo "$x" | grep -F "resource-id=\"com.android.systemui:id/key$d\"" | head -1 \
      | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
      | awk '{print int(($1+$3)/2), int(($2+$4)/2)}')"
  done
  for d in 0 1 2 3 4 5 6 7 8 9 _enter; do [[ -n "${K[$d]}" ]] || { fail "key$d not found"; return 1; }; done
}
lock() { sh_ input keyevent KEYCODE_SLEEP; sleep 3; }
bouncer() {
  local i
  sh_ input keyevent KEYCODE_WAKEUP; sleep 1.5
  for i in 1 2 3 4 5; do
    ui | grep -q 'id/key1' && { keymap; return; }
    sh_ input swipe 540 1700 540 500 200; sleep 2
  done
  fail "no PIN pad"; return 1
}
tap_pin() {
  local d
  for d in $(echo "$1" | grep -o .); do sh_ input tap ${K[$d]}; sleep 0.3; done
  sh_ input tap ${K[_enter]}; sleep 4
}
key_pin() {
  local d
  for d in $(echo "$1" | grep -o .); do sh_ input keyevent "KEYCODE_$d"; sleep 0.3; done
  sh_ input keyevent KEYCODE_ENTER; sleep 4
}
opened() {  # opened <user> <what>
  if wait_user "$1" && [[ "$(shown)" == false ]]; then pass "$2"
  else fail "$2 (user $(cur), keyguard showing $(shown))"; fi
}

conn || { echo "no emulator at $SERIAL"; exit 1; }
[[ "$(sh_ id -u)" == 0 ]] || { a root >/dev/null 2>&1; sleep 3; conn; }
log ""; log "## Lock screen dispatch — $(date -Is)"
log "build: $(sh_ getprop ro.build.fingerprint)"
sh_ settings put system screen_off_timeout 600000
sh_ cmd lock_settings set-pin "$A_PIN" >/dev/null
out="$(sh_ cmd lock_settings provision-protected-space --owner-credential "$A_PIN" \
  --protected-pin "$B_PIN" --reboot-pin "$REBOOT_PIN" 2>&1)"
log "    $out"
[[ "$out" == "protected space is user 10" ]] || { fail "setup"; exit 1; }

log "### A's PIN, tapped and as key events"
lock; bouncer && tap_pin "$A_PIN"; opened 0 "A opens (taps)"
lock; bouncer && key_pin "$A_PIN"; opened 0 "A opens (key events)"

log "### B's PIN at A's lock screen: B opens without asking again"
lock; bouncer && tap_pin "$B_PIN"
screen="$(ui)"
if wait_user 10 && [[ "$(sh_ am get-started-user-state 10)" == RUNNING_UNLOCKED ]] \
    && [[ "$screen" == *"<hierarchy"* && "$screen" != *id/key1* ]]; then pass "B opens"
else fail "B opens (user $(cur), $(sh_ am get-started-user-state 10))"; fi

log "### screen off in B with an app open: back on A's lock screen, nothing of B on top"
sh_ am start --user 10 -W -a android.settings.SETTINGS >/dev/null; sleep 3
[[ "$(top)" == u10* ]] || fail "B's Settings didn't open ($(top))"
lock
wait_user 0 && pass "user 0 after screen off" || fail "user $(cur) after screen off"
sh_ input keyevent KEYCODE_WAKEUP; sleep 3
[[ "$(shown)" == true ]] && pass "lock screen showing" || fail "no lock screen after wake"
# nothing is resumed under the lock screen; the focused window must be user 0's shade
t="$(top)" f="$(sh_ dumpsys window | grep -m1 mCurrentFocus)"
if [[ "$t" == u10* ]]; then fail "B's activity on top: $t"
elif [[ "$f" != *" u0 NotificationShade"* ]]; then fail "focus not on A's lock screen: ${f:-none read}"
else pass "nothing of B on top, focus on A's lock screen"; fi
bouncer && key_pin "$A_PIN"; opened 0 "A opens (key events) right after B"

log "### during a lockout the pad still sends every entry"
# wrong PINs count for A and B alike (doc 04), so both lock out together; B's PIN then can't
# open B either. What matters here is that the entries still reach the service.
sh_ logcat -c
lock; bouncer
for w in 500001 500002 500003 500004 500005; do tap_pin "$w"; done
key_pin "$B_PIN"; tap_pin "$B_PIN"
n="$(sh_ logcat -d | grep -c 'Verifying primary lockscreen credential for user 10')"
[[ "$n" == 7 ]] && pass "all 7 entries reached the service" || fail "$n of 7 entries reached the service"
[[ "$(cur)" == 0 ]] || fail "user $(cur) after the lockout entries"
ui | grep -q 'id/key1' && pass "pad still up" || fail "pad gone during the lockout"
countdown && pass "countdown shown" || fail "no countdown during the lockout (message: $(msg))"

log "### only B in lockout: B's PIN shows B's countdown, and opens B once it ends"
# A's unlock clears A's count only; one more wrong PIN then puts B alone into its next lockout
# (6 failures, 5 min, SoftwareRateLimiter.java:107)
sleep 65
lock; bouncer && key_pin "$A_PIN"; opened 0 "A opens after the lockout"
lock; bouncer && tap_pin 500006
tap_pin "$B_PIN"
if [[ "$(cur)" == 0 ]] && countdown; then pass "B's PIN during B's lockout: countdown, still user 0"
else fail "B's PIN during B's lockout (user $(cur), message: $(msg))"; fi
sleep 300
lock; bouncer && tap_pin "$B_PIN"
wait_user 10 && pass "B opens once its lockout ended" || fail "B didn't open after its lockout"

log "results: $RES"
log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
[[ $FAILS == 0 ]]
