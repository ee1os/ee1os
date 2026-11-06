#!/usr/bin/env bash
# A removable volume follows the current user (doc 04, decision 2026-11-06). Emulator, with vold's
# virtual disk in place of a USB stick, so USB port control is not covered here.
# Needs a freshly wiped emulator (EMU_ARGS=-wipe-data run.sh emulator); sets A's and B's PINs.
# Run inside the build container:  run.sh exec /src/ee1os/tests/usb-volume.sh
set -uo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
A_PIN=111111 B_PIN=222222
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-usb-volume.md}"
mkdir -p "$(dirname "$RES")"
FAILS=0

sh_()  { timeout 60 adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
log()  { echo "$*" | tee -a "$RES"; }
pass() { log "    PASS: $*"; }
fail() { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }
cur()  { sh_ am get-current-user; }

conn() {
  local i
  for i in $(seq 60); do
    adb connect "$SERIAL" >/dev/null 2>&1
    [[ "$(timeout 10 adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] \
      && return 0
    sleep 5
  done
  return 1
}
# turning the virtual disk off deletes its image, so every insert partitions it again
stick_out() { sh_ sm set-virtual-disk false; sleep 4; }
stick_in() {
  local i
  sh_ sm set-virtual-disk true; sleep 4
  sh_ sm partition "$(sh_ sm list-disks | head -1)" public
  for i in $(seq 30); do sh_ sm list-volumes public | grep -q ' mounted ' && return 0; sleep 1; done
  fail "the stick didn't mount"
}
owner() { sh_ dumpsys mount | grep -A8 'VolumeInfo{public' | grep -m1 -oE 'mountUserId=[0-9]+' | cut -d= -f2; }
roots() {  # the stick's root as user $1's file picker sees it, or nothing
  local id
  id="$(sh_ sm list-volumes public | awk '{print $NF}')"
  sh_ content query --user "$1" --uri content://com.android.externalstorage.documents/root \
    --projection root_id 2>/dev/null | grep -F "root_id=$id"
}
# the volume moves a moment after the switch: unmount and mount are queued
sees() {  # sees <user> <what>
  local i
  for i in $(seq 20); do
    [[ "$(owner)" == "$1" ]] && sh_ sm list-volumes public | grep -q ' mounted ' && [[ -n "$(roots "$1")" ]] \
      && { pass "$2"; return; }
    sleep 1
  done
  fail "$2 (belongs to $(owner), $(sh_ sm list-volumes public))"
}
lock() { sh_ input keyevent KEYCODE_SLEEP; sleep 3; }
pad() {
  local i
  sh_ input keyevent KEYCODE_WAKEUP; sleep 1.5
  for i in 1 2 3 4 5; do
    sh_ "rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; \
      cat /data/local/tmp/ui.xml" | grep -q 'id/key1' && return 0
    sh_ input swipe 540 1700 540 500 200; sleep 2
  done
  fail "no PIN pad"; return 1
}
enter() {  # enter <pin> <user>
  local d i
  for d in $(echo "$1" | grep -o .); do sh_ input keyevent "KEYCODE_$d"; sleep 0.3; done
  sh_ input keyevent KEYCODE_ENTER
  for i in $(seq 25); do [[ "$(cur)" == "$2" ]] && { sleep 5; return 0; }; sleep 1; done
  fail "user $2 didn't open (user $(cur))"
}
go() { lock; pad && enter "$1" "$2"; }

conn || { echo "no emulator at $SERIAL"; exit 1; }
adb -s "$SERIAL" root >/dev/null 2>&1; sleep 3; conn
log ""; log "## Removable volume across user switches — $(date -Is)"
log "build: $(sh_ getprop ro.build.fingerprint)"
sh_ settings put system screen_off_timeout 600000
sh_ cmd lock_settings set-pin "$A_PIN" >/dev/null
out="$(sh_ cmd lock_settings provision-protected-space --owner-credential "$A_PIN" --protected-pin "$B_PIN" 2>&1)"
log "    $out"
[[ "$out" == "protected space is user 10" ]] || { fail "setup"; exit 1; }
go "$A_PIN" 0

log "### inserted in A"
stick_in; sees 0 "A sees it"
log "### A to B and back with the stick left in"
go "$B_PIN" 10; sees 10 "it moves to B"
[[ -z "$(roots 0)" ]] && pass "A no longer lists it" || fail "A still lists it"
go "$A_PIN" 0; sees 0 "it moves back to A"
stick_out

log "### inserted in B, back to A with the stick left in (B stops)"
go "$B_PIN" 10
stick_in; sees 10 "B sees it"
go "$A_PIN" 0; sees 0 "A sees it"

log "### unmount and mount in B keep it with B"
go "$B_PIN" 10; sees 10 "it moves to B"
v="$(sh_ sm list-volumes public | awk '{print $1}')"
sh_ sm unmount "$v"; sleep 3; sh_ sm mount "$v"
sees 10 "B still sees it"

log "### reboot with the stick in, B first while A stays locked"
adb -s "$SERIAL" reboot; sleep 20; conn
adb -s "$SERIAL" root >/dev/null 2>&1; sleep 3; conn
sleep 10
pad && enter "$B_PIN" 10
sees 10 "B sees it"
log "### then back to A, still before A's first unlock"
lock
for i in $(seq 20); do [[ "$(cur)" == 0 ]] && break; sleep 1; done
pad && enter "$A_PIN" 0
sees 0 "A sees it after its first unlock"
stick_out

log ""
[[ "$FAILS" == 0 ]] && log "usb-volume: all passed" || log "usb-volume: $FAILS FAILED"
exit $(( FAILS > 0 ))
