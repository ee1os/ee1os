#!/usr/bin/env bash
# B's own Settings on the emulator: no Users screen, and "Delete protected space" (doc 04,
# decision 2026-11-11).
# Needs a freshly wiped emulator (EMU_ARGS=-wipe-data run.sh emulator); sets A's and B's PIN.
# Run inside the build container:  run.sh exec /src/ee1os/tests/delete-space.sh
#   1. B is opened from the lock screen; the Users screen doesn't come up there
#   2. the delete entry is on B's device unlock page; backing out of its PIN prompt deletes nothing
#   3. with B's PIN the space is deleted: the phone is back in A, user 10 is gone, and what
#      setup changed on A is put back
# Every check prints PASS or FAIL; the script exits 1 if any check failed.
set -uo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
A_PIN=111111 B_PIN=222222
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-delete-space-T3.md}"
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
  local i x
  for i in 1 2 3 4 5; do
    x="$(sh_ "rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; \
      cat /data/local/tmp/ui.xml 2>/dev/null")" || true
    [[ "$x" == *"<hierarchy"* ]] && { echo "$x"; return 0; }
    sleep 2
  done
  return 1
}
cur() { sh_ am get-current-user; }
top() { sh_ dumpsys activity activities | grep -m1 topResumedActivity | grep -oE 'u[0-9]+ [^ ]+'; }
wait_user() {
  local i
  for i in $(seq 40); do [[ "$(cur)" == "$1" ]] && return 0; sleep 1; done
  return 1
}
# centre of the first node whose text is exactly $1, on the screen that is up now
where() {
  ui | tr '>' '\n' | grep -F "text=\"$1\"" | head -1 \
    | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
    | awk '{print int(($1+$3)/2), int(($2+$4)/2)}'
}
# the same, scrolling down until it shows
find_text() {
  local i p
  for i in $(seq 8); do
    p="$(where "$1")"; [[ -n "$p" ]] && { echo "$p"; return 0; }
    sh_ input swipe 540 1600 540 700 300; sleep 1
  done
  return 1
}
restrictions() {
  local d; d="$(sh_ dumpsys user)"
  awk -v u="UserInfo{$1:" '
    index($0, u) {on = 1; next}
    on && /UserInfo\{/ {on = 0}
    on && /no_[a-z_]+/ {printf "%s ", $0}' <<< "$d" | tr -s ' '
}
unlock_page() {
  sh_ am force-stop --user 10 com.android.settings
  sh_ am start --user 10 -n com.android.settings/.SubSettings \
    --es :settings:show_fragment com.android.settings.safetycenter.ui.DeviceUnlockSubpageFragment \
    >/dev/null 2>&1
  sleep 4
}

conn || { echo "no emulator at $SERIAL"; exit 1; }
[[ "$(sh_ id -u)" == 0 ]] || { a root >/dev/null 2>&1; sleep 3; conn; }
log ""; log "## Deleting the protected space from its Settings — $(date -Is)"
log "build: $(sh_ getprop ro.build.fingerprint)"
sh_ settings put system screen_off_timeout 1800000
sh_ cmd lock_settings set-pin "$A_PIN" >/dev/null
out="$(sh_ cmd lock_settings provision-protected-space --owner-credential "$A_PIN" \
  --protected-pin "$B_PIN" 2>&1)"
log "    $out"
[[ "$out" == "protected space is user 10" ]] || { fail "setup"; exit 1; }
[[ "$(restrictions 0)" == *no_remove_user* ]] && pass "setup set no_remove_user on user 0" \
  || fail "no_remove_user not seen on user 0 (the checks of part 3 then say nothing)"

log "### B is opened; no Users screen there"
sh_ input keyevent KEYCODE_SLEEP; sleep 3
sh_ input keyevent KEYCODE_WAKEUP; sleep 1.5
for i in 1 2 3 4 5; do
  ui | grep -q 'id/key1' && break
  sh_ input swipe 540 1700 540 500 200; sleep 2
done
for d in $(echo "$B_PIN" | grep -o .); do sh_ input keyevent "KEYCODE_$d"; sleep 0.3; done
sh_ input keyevent KEYCODE_ENTER
if wait_user 10; then pass "B is open"; else fail "B didn't open (user $(cur))"; exit 1; fi
for i in $(seq 30); do [[ "$(sh_ am get-started-user-state 10)" == RUNNING_UNLOCKED ]] && break; sleep 1; done
sleep 8
sh_ am start --user 10 -a android.settings.USER_SETTINGS >/dev/null 2>&1; sleep 4
t="$(top)"; scr="$(ui)"
# the screen closes itself when hidden, so what was up before is on top again
log "    on top after asking for Users: ${t:-nothing}"
recs="$(sh_ dumpsys activity activities | grep -c 'ActivityRecord.*UserSettingsActivity')"
if [[ "$recs" != 0 || "$t" == *UserSettingsActivity* || "$scr" == *'text="Add user"'* ]]; then
  fail "B's Settings shows the Users screen"
else pass "the Users screen doesn't come up in B"; fi

log "### the delete entry; backing out deletes nothing"
unlock_page
p="$(find_text "Delete protected space")"
if [[ -n "$p" ]]; then pass "B's device unlock page has the entry"
else fail "no \"Delete protected space\" on B's device unlock page (on top: $(top))"; fi
if [[ -n "$p" ]]; then
  sh_ input tap $p; sleep 3
  b="$(where Delete)"
  if [[ -n "$b" ]]; then pass "the delete screen is up"; else fail "no Delete button (on top: $(top))"; fi
  [[ -n "$b" ]] && { sh_ input tap $b; sleep 3; }
  t="$(top)"; log "    on top after Delete: $t"
  [[ "$t" == *ConfirmLock* || "$t" == *ConfirmDeviceCredential* ]] && pass "B's PIN is asked for" \
    || fail "no PIN prompt after Delete"
  sh_ input keyevent KEYCODE_BACK; sleep 3
  sh_ input text 999999; sh_ input keyevent KEYCODE_ENTER; sleep 3   # goes nowhere if no prompt is up
  if [[ "$(cur)" == 10 ]] && sh_ pm list users | grep -q 'UserInfo{10:'; then
    pass "backing out of the PIN prompt keeps B"
  else fail "B is gone or left without its PIN (user $(cur))"; fi

  log "### with B's PIN the space is deleted"
  unlock_page
  p="$(find_text "Delete protected space")"; [[ -n "$p" ]] && { sh_ input tap $p; sleep 3; }
  b="$(where Delete)"; [[ -n "$b" ]] && { sh_ input tap $b; sleep 3; }
  sh_ input text "$B_PIN"; sh_ input keyevent KEYCODE_ENTER
  if wait_user 0; then pass "the phone is back in A"; else fail "still user $(cur)"; fi
  for i in $(seq 60); do sh_ pm list users | grep -q 'UserInfo{10:' || break; sleep 1; done
  if sh_ pm list users | grep -q 'UserInfo{10:'; then fail "user 10 is still there"
  else pass "user 10 is gone"; fi
  sleep 5
  after="$(restrictions 0)"
  log "    user 0 now: ${after:-no restrictions}; user_switcher_enabled=$(sh_ settings get global user_switcher_enabled)"
  [[ "$after" != *no_remove_user* ]] && pass "no_remove_user is off" || fail "no_remove_user stays on user 0"
  [[ "$after" != *no_add_private_profile* ]] && pass "no_add_private_profile is off" \
    || fail "no_add_private_profile stays on user 0"
  [[ "$(sh_ settings get global user_switcher_enabled)" == 1 ]] && pass "user switcher is back on" \
    || fail "user switcher stays off"
  out="$(sh_ cmd lock_settings verify --old "$A_PIN" 2>&1)"
  [[ "$out" == *"verified successfully"* ]] && pass "A's PIN still works" || fail "A's PIN: $out"
fi

log ""
if [[ $FAILS == 0 ]]; then log "delete-space: all passed"; log "result: PASS"
else log "delete-space: $FAILS failed"; log "result: FAIL"; fi
log "results: $RES"
[[ $FAILS == 0 ]]
