#!/usr/bin/env bash
# Stage 1 baseline experiments on the unmodified emulator (docs/07-roadmap.md, Stage 1).
# Run inside the build container:  run.sh exec /src/ee1os/tests/stage1.sh <item>
#   setup      owner PIN + secondary user "envB" with its own PIN          (item 1)
#   evict      CE state of envB after switch / stop / no_run_in_background (item 2)
#   bootorder  switch to envB before the owner unlocks after a reboot      (item 3)
#   lockout    6 wrong owner PINs, record the throttling                   (item 5)
#   duress     enrol duress and enter it -> WIPES the emulator             (item 4, needs --yes-wipe)
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=1111 B_PIN=2222 DURESS_PIN=9999 DURESS_PW=duress-pw
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/results/$(date +%F)-stage1-T3.md"
mkdir -p "$HERE/results"

a()   { adb -s "$SERIAL" "$@"; }
sh_() { a shell "$@" | tr -d '\r'; }
log() { echo "$*" | tee -a "$RES"; }
run() { log "\$ $*"; { sh_ "$@" 2>&1 || true; } | sed 's/^/    /' | tee -a "$RES"; }

wait_boot() {
  a wait-for-device
  until [[ "$(sh_ getprop sys.boot_completed)" == 1 ]]; do sleep 2; done
}
user_id() { sh_ pm list users | sed -n 's/.*UserInfo{\([0-9]*\):envB:.*/\1/p'; }
state()   { sh_ am get-started-user-state "$1" 2>&1 || true; }
# poll until the state of user $1 matches $2, up to $3 seconds
wait_state() {
  local i
  for ((i = 0; i < $3; i++)); do
    [[ "$(state "$1")" == *"$2"* ]] && { log "    after ${i}s: $(state "$1")"; return 0; }
    sleep 1
  done
  log "    after $3s: $(state "$1") (expected $2)"
}
ce_listing() {  # encrypted CE names = locked
  a root >/dev/null; a wait-for-device
  run "ls /data/user/$1 | head -4"
}
# key removal lags the stop by a few seconds: poll until the CE names are encrypted
wait_ce_locked() {
  local i
  a root >/dev/null; a wait-for-device
  for ((i = 0; i < $2; i++)); do
    [[ "$(sh_ "ls /data/user/$1 | head -1")" == AAAA* ]] && { log "    CE locked after ${i}s"; return 0; }
    sleep 1
  done
  log "    CE still unlocked after $2s"; ce_listing "$1"
}
# boot_completed stays 1 across a system_server restart, so also wait for the services
wait_services() {
  until sh_ service check activity | grep -q found && sh_ service check lock_settings | grep -q found; do
    sleep 2
  done
}
unlock_ui() {  # type PIN $1 at whatever keyguard is showing
  sh_ input keyevent KEYCODE_WAKEUP; sh_ wm dismiss-keyguard; sleep 1
  sh_ input text "$1"; sh_ input keyevent KEYCODE_ENTER; sleep 3
}
switch_and_unlock() { sh_ am switch-user "$1"; sleep 4; unlock_ui "$2"; }

header() {
  a connect "$SERIAL" >/dev/null 2>&1 || true
  wait_boot; wait_services
  log ""; log "## $1 — $(date -Is)"
  log "build: $(sh_ getprop ro.build.fingerprint)"
}

case "${1:-}" in
  setup)
    header "item 1: setup"
    run cmd lock_settings set-pin "$OWNER_PIN"
    [[ -n "$(user_id)" ]] || run pm create-user envB
    N="$(user_id)"; log "envB = user $N"
    run am start-user -w "$N"
    run cmd lock_settings set-pin --user "$N" "$B_PIN"
    run am stop-user -w "$N"
    ;;
  evict)
    header "item 2: eviction"; N="$(user_id)"
    log "### plain switch away"
    switch_and_unlock "$N" "$B_PIN"; log "    in envB: $(state "$N")"
    switch_and_unlock 0 "$OWNER_PIN"; sleep 10; log "    10s after switch to 0: $(state "$N")"
    ce_listing "$N"
    log "### explicit stop"
    run am stop-user -w "$N"; log "    $(state "$N")"; wait_ce_locked "$N" 30
    log "### no_run_in_background"
    switch_and_unlock "$N" "$B_PIN"
    run pm set-user-restriction --user "$N" no_run_in_background 1
    switch_and_unlock 0 "$OWNER_PIN"
    wait_state "$N" "not started" 60 || true
    wait_ce_locked "$N" 30
    run pm set-user-restriction --user "$N" no_run_in_background 0
    run pm get-user-restriction --user "$N" no_run_in_background
    run "logcat -d -b main | grep -E 'vold.*(still has unlocked files|were not locked)' | tail -2"
    ;;
  bootorder)
    header "item 3: boot order"; N="$(user_id)"
    run settings put global allow_user_switching_when_system_user_locked 1
    a reboot; wait_boot
    log "    owner after boot: $(state 0)"
    run am switch-user "$N"; sleep 5
    unlock_ui "$B_PIN"
    log "    envB: $(state "$N"); owner: $(state 0)"
    run "logcat -d -b crash | grep -A3 'FATAL EXCEPTION IN SYSTEM PROCESS'"
    log "    (screen behaviour: check with scrcpy, note it in T4)"
    wait_services
    run settings put global allow_user_switching_when_system_user_locked 0
    ;;
  lockout)
    header "item 5: lockout"
    for i in 1 2 3 4 5 6; do run cmd lock_settings verify --old 0000; done
    log "    stopping at 6: 10 failures would lock the owner out for 4 h"
    log "    waiting 65 s, then the right PIN"; sleep 65
    run cmd lock_settings verify --old "$OWNER_PIN"
    ;;
  duress)
    [[ "${2:-}" == --yes-wipe ]] || { echo "destroys the emulator data; add --yes-wipe"; exit 2; }
    header "item 4: duress"
    run cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
      --duress-pin "$DURESS_PIN" --duress-password "$DURESS_PW"
    run cmd lock_settings check-non-ce-storage-keys
    # the shell verify enters through checkCredential like the keyguard bouncer (doc 03, *Who
    # reaches the hook*); typing at the keyguard is a T4 item, `input text` doesn't reach it
    run cmd lock_settings verify --old "$DURESS_PIN"
    sleep 1
    # same check as DuressPasswordTest: no non-CE keys left once the wipe has run
    run cmd lock_settings check-non-ce-storage-keys
    for i in $(seq 60); do a get-state >/dev/null 2>&1 || { log "    device gone after ${i}s"; break; }; sleep 1; done
    a get-state >/dev/null 2>&1 && log "    device still up after 60 s: duress did not fire"
    log "    restart with: EMU_ARGS=-wipe-data run.sh emulator"
    ;;
  *)
    sed -n 2,9p "$0"; exit 2 ;;
esac
log "results: $RES"
