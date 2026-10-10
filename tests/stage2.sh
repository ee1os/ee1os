#!/usr/bin/env bash
# Stage 2 checks for the reboot credential (docs/07-roadmap.md, Stage 2; doc 04 *Test plan*).
# Needs the Stage 2 build and the Stage 1 setup (owner PIN, envB with its own PIN).
# Run inside the build container:  run.sh exec /src/grapheneos-envs/tests/stage2.sh <item>
#   enrol      set the reboot PIN, collision checks against owner and duress
#   noop       wrong PIN and right PIN must not reboot; timing with 0 / 1 / 2 alternates
#   reboot     reboot PIN at the owner's prompt -> reboot, owner locked, data intact
#   reboot-b   reboot PIN at envB's prompt -> reboot as well (doc 04 Q2)
#   cleanup    delete reboot PIN and duress credentials
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=1111 B_PIN=2222 DURESS_PIN=9999 DURESS_PW=duress-pw REBOOT_PIN=5555
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/results/$(date +%F)-stage2-T3.md"
mkdir -p "$HERE/results"

a()   { adb -s "$SERIAL" "$@"; }
sh_() { a shell "$@" | tr -d '\r'; }
log() { echo "$*" | tee -a "$RES"; }
run() { log "\$ $*"; { sh_ "$@" 2>&1 || true; } | sed 's/^/    /' | tee -a "$RES"; }

wait_boot() {
  a wait-for-device
  until [[ "$(sh_ getprop sys.boot_completed)" == 1 ]]; do sleep 2; done
}
wait_services() {
  until sh_ service check activity | grep -q found && sh_ service check lock_settings | grep -q found; do
    sleep 2
  done
}
user_id() { sh_ pm list users | sed -n 's/.*UserInfo{\([0-9]*\):envB:.*/\1/p'; }
state()   { sh_ am get-started-user-state "$1" 2>&1 || true; }
boot_id() { sh_ cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }
header() {
  a connect "$SERIAL" >/dev/null 2>&1 || true
  wait_boot; wait_services
  # after a boot the owner is locked and switching / starting other users is refused
  sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null
  log ""; log "## $1 — $(date -Is)"
  log "build: $(sh_ getprop ro.build.fingerprint)"
}
set_reboot() { run cmd lock_settings set-reboot-credential --owner-credential "$OWNER_PIN" "$@"; }
set_duress() {
  run cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
    --duress-pin "$1" --duress-password "$2"
}
# adb shell joins its arguments into one command line and drops empty ones: pass "''"
# same boot after $1 seconds?
no_reboot() {
  local id="$1" i
  for ((i = 0; i < $2; i++)); do
    a get-state >/dev/null 2>&1 && [[ "$(boot_id)" == "$id" ]] || { log "    REBOOTED after ${i}s"; return 1; }
    sleep 1
  done
  log "    no reboot within $2 s"
}
# wait until the device has gone and come back with a new boot id
rebooted() {
  local id="$1" t0=$SECONDS
  until ! a get-state >/dev/null 2>&1 || [[ "$(boot_id)" != "$id" ]]; do
    (( SECONDS - t0 > 60 )) && { log "    no reboot within 60 s"; return 1; }
    sleep 1
  done
  log "    device went down after $((SECONDS - t0)) s"
  wait_boot; wait_services
  log "    back up after $((SECONDS - t0)) s, boot reason: $(sh_ getprop sys.boot.reason)"
}
# ms for one wrong owner PIN, measured around the shell verify
wrong_ms() {
  local t0 t1
  t0=$(date +%s%N); sh_ cmd lock_settings verify --old 0000 >/dev/null || true; t1=$(date +%s%N)
  sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null  # resets the failure count
  echo $(( (t1 - t0) / 1000000 ))
}
after_reboot_checks() {
  log "    owner: $(state 0)"
  a root >/dev/null; a wait-for-device; sleep 2
  run "ls /data/user/0 | head -2"
  run cmd lock_settings verify --old "$OWNER_PIN"
  sleep 3
  log "    owner after unlock: $(state 0)"
  run "ls /data/user/0 | head -2"
}

case "${1:-}" in
  enrol)
    header "enrolment"
    log "### owner PIN as reboot PIN -> collision"
    set_reboot --reboot-pin "$OWNER_PIN"
    log "### too short -> validation error"
    set_reboot --reboot-pin 12
    log "### wrong owner credential -> refused"
    run cmd lock_settings set-reboot-credential --owner-credential 0000 --reboot-pin "$REBOOT_PIN"
    sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null
    log "### duress enrolled, duress PIN as reboot PIN -> collision"
    set_duress "$DURESS_PIN" "$DURESS_PW"
    set_reboot --reboot-pin "$DURESS_PIN"
    log "### valid"
    set_reboot --reboot-pin "$REBOOT_PIN"
    log "### reverse: reboot PIN as duress PIN -> collision, old duress kept"
    set_duress "$REBOOT_PIN" "$DURESS_PW"
    ;;
  noop)
    header "no reboot for wrong / right credentials"; id="$(boot_id)"
    run cmd lock_settings verify --old 0000
    run cmd lock_settings verify --old "$OWNER_PIN"
    no_reboot "$id" 20 || exit 1
    log "### wrong-PIN response time, ms (5 runs), with duress + reboot PIN"
    log "    $(for i in 1 2 3 4 5; do wrong_ms; done | tr '\n' ' ')"
    set_reboot --reboot-pin "''"
    log "### with duress only"
    log "    $(for i in 1 2 3 4 5; do wrong_ms; done | tr '\n' ' ')"
    set_duress "''" "''"
    log "### with none"
    log "    $(for i in 1 2 3 4 5; do wrong_ms; done | tr '\n' ' ')"
    set_duress "$DURESS_PIN" "$DURESS_PW"
    set_reboot --reboot-pin "$REBOOT_PIN"
    no_reboot "$id" 5
    ;;
  reboot)
    header "reboot PIN at the owner's prompt"; id="$(boot_id)"
    run cmd lock_settings verify --old "$REBOOT_PIN"
    rebooted "$id"
    after_reboot_checks
    ;;
  reboot-b)
    header "reboot PIN at envB's prompt"; id="$(boot_id)"; N="$(user_id)"
    run am start-user -w "$N"
    log "    envB: $(state "$N")"
    run cmd lock_settings verify --user "$N" --old "$REBOOT_PIN"
    rebooted "$id"
    after_reboot_checks
    ;;
  cleanup)
    header "cleanup"
    set_reboot --reboot-pin "''"
    set_duress "''" "''"
    ;;
  *)
    sed -n 2,9p "$0"; exit 2 ;;
esac
log "results: $RES"
