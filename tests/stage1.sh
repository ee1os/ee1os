#!/usr/bin/env bash
# Stage 1 baseline experiments on the unmodified emulator (docs/07-roadmap.md, Stage 1).
# Run inside the build container:  run.sh exec /src/ee1os/tests/stage1.sh <item>
#   setup      owner PIN + secondary user "envB" with its own PIN          (item 1)
#   evict      CE state of envB after switch / stop / no_run_in_background (item 2)
#   bootorder  switch to envB before the owner unlocks after a reboot      (item 3)
#   lockout    6 wrong owner PINs, record the throttling                   (item 5)
#   duress     enrol duress and enter it -> WIPES the emulator             (item 4, needs --yes-wipe)
#              (tests/duress.sh with LAYOUT=plain, after setup)
# setup checks what it sets and prints PASS or FAIL; evict, bootorder and lockout record
# observations only. Every item ends with "result: PASS" or "result: FAIL (n)" and exits 1 on a
# failed check. New PINs need 6 digits (LockPatternUtils.MIN_NEW_PIN_SIZE).
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=111111 B_PIN=222222
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-stage1-T3.md}"
mkdir -p "$(dirname "$RES")"
FAILS=0

a()   { adb -s "$SERIAL" "$@"; }
sh_() { timeout 60 adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
log() { echo "$*" | tee -a "$RES"; }
run() { log "\$ $*"; { sh_ "$@" 2>&1 || true; } | sed 's/^/    /' | tee -a "$RES"; }
pass() { log "    PASS: $*"; }
fail() { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }
check() {
  local what="$1" pat="$2" out; shift 2
  log "\$ $*"
  out="$(sh_ "$@" 2>&1 || true)"
  echo "$out" | sed 's/^/    /' | tee -a "$RES"
  if echo "$out" | grep -qE "$pat"; then pass "$what"; else fail "$what (expected /$pat/)"; fi
}

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
  local d
  sh_ input keyevent KEYCODE_WAKEUP; sh_ wm dismiss-keyguard; sleep 1
  # input text doesn't reach the bouncer on this build; single key events do (keyguard.sh)
  for d in $(echo "$1" | grep -o .); do sh_ input keyevent "KEYCODE_$d"; sleep 0.3; done
  sh_ input keyevent KEYCODE_ENTER; sleep 3
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
    check "owner PIN set" "Pin set to '$OWNER_PIN'" cmd lock_settings set-pin "$OWNER_PIN"
    [[ -n "$(user_id)" ]] || run pm create-user envB
    N="$(user_id)"; log "envB = user $N"
    [[ -n "$N" ]] || { fail "envB not created"; log "result: FAIL ($FAILS)"; exit 1; }
    run am start-user -w "$N"
    check "envB PIN set" "Pin set to '$B_PIN'" cmd lock_settings set-pin --user "$N" "$B_PIN"
    check "owner PIN verifies" 'Lock credential verified' cmd lock_settings verify --old "$OWNER_PIN"
    check "envB PIN verifies" 'Lock credential verified' \
      cmd lock_settings verify --user "$N" --old "$B_PIN"
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
    # the owner PIN of setup is duress.sh's A_PIN; it checks and logs on its own
    SERIAL="$SERIAL" RES="$RES" LAYOUT=plain exec "$HERE/duress.sh" --yes-wipe
    ;;
  *)
    sed -n 2,12p "$0"; exit 2 ;;
esac
log "results: $RES"
log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
[[ $FAILS == 0 ]]
