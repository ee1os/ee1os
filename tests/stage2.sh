#!/usr/bin/env bash
# Stage 2 checks for the reboot credential (docs/07-roadmap.md, Stage 2; doc 04 *Test plan*).
# Needs the Stage 2 build and the Stage 1 setup (owner PIN, envB with its own PIN).
# Run inside the build container:  run.sh exec /src/grapheneos-envs/tests/stage2.sh <item>
#   enrol      set the reboot PIN, collision checks against owner and duress, password variant
#   noop       wrong PIN and right PIN must not reboot; timing with 0 / 1 / 2 alternates
#   reboot     reboot PIN at the owner's prompt -> reboot, owner locked, data intact
#   reboot-b   reboot PIN at envB's prompt -> reboot as well (doc 04 Q2)
#   escrow     same as reboot, with an LSKF captured for a resume-on-reboot update
#   lifecycle  owner PIN changed to the reboot PIN / owner lock removed -> reboot PIN deleted
#   cleanup    delete reboot PIN and duress credentials
# Checks print PASS, FAIL or SKIP (not checkable here); the script exits 1 if any check failed.
# Setup steps printed with "$ cmd" are not checks: their output is recorded, not asserted.
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=1111 B_PIN=2222 DURESS_PIN=9999 DURESS_PW=duress-pw REBOOT_PIN=5555
BOOT_REASON=reboot,userrequested
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/results/$(date +%F)-stage2-T3.md"
mkdir -p "$HERE/results"
FAILS=0

a()   { adb -s "$SERIAL" "$@"; }
sh_() { a shell "$@" | tr -d '\r'; }
log() { echo "$*" | tee -a "$RES"; }
run() { log "\$ $*"; { sh_ "$@" 2>&1 || true; } | sed 's/^/    /' | tee -a "$RES"; }
pass() { log "    PASS: $*"; }
fail() { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }
skip() { log "    SKIP: $*"; }
# check "<what>" <pattern> <cmd...>: run cmd, its output must match the extended regex
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
wait_services() {
  until sh_ service check activity | grep -q found && sh_ service check lock_settings | grep -q found; do
    sleep 2
  done
}
user_id() { sh_ pm list users | sed -n 's/.*UserInfo{\([0-9]*\):envB:.*/\1/p'; }
state()   { sh_ am get-started-user-state "$1" 2>&1 || true; }
boot_id() { sh_ cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }
unlock_owner() { sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null; }
header() {
  a connect "$SERIAL" >/dev/null 2>&1 || true
  wait_boot; wait_services
  a root >/dev/null; a wait-for-device; wait_services
  # after a boot the owner is locked and switching / starting other users is refused
  unlock_owner
  log ""; log "## $1 — $(date -Is)"
  log "build: $(sh_ getprop ro.build.fingerprint), system_server: $(sh_ "stat -c %y /system/framework/services.jar")"
}
set_reboot() { run cmd lock_settings set-reboot-credential --owner-credential "$OWNER_PIN" "$@"; }
set_duress() {
  run cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
    --duress-pin "$1" --duress-password "$2"
}
# adb shell joins its arguments into one command line and drops empty ones: pass "''"
reboot_cmd() { echo cmd lock_settings set-reboot-credential --owner-credential "$OWNER_PIN"; }
# same boot for $2 seconds?
no_reboot() {
  local id="$1" i
  for ((i = 0; i < $2; i++)); do
    if ! a get-state >/dev/null 2>&1 || [[ "$(boot_id)" != "$id" ]]; then
      fail "rebooted after ${i}s"; return 1
    fi
    sleep 1
  done
  pass "no reboot within $2 s"
}
# wait until the device has gone and come back with a different boot id
rebooted() {
  local id="$1" t0=$SECONDS new
  until ! a get-state >/dev/null 2>&1 || [[ "$(boot_id)" != "$id" ]]; do
    (( SECONDS - t0 > 60 )) && { fail "no reboot within 60 s"; return 1; }
    sleep 1
  done
  log "    device went down after $((SECONDS - t0)) s"
  wait_boot; wait_services
  a root >/dev/null; a wait-for-device; wait_services
  new="$(boot_id)"
  log "    back up after $((SECONDS - t0)) s"
  [[ -n "$new" && "$new" != "$id" ]] && pass "new boot id" || fail "boot id unchanged ($new)"
  [[ "$(sh_ getprop sys.boot.reason)" == "$BOOT_REASON" ]] && pass "boot reason $BOOT_REASON" \
    || fail "boot reason $(sh_ getprop sys.boot.reason)"
}
# ms for one wrong owner PIN, measured around the shell verify
wrong_ms() {
  local t0 t1
  t0=$(date +%s%N); sh_ cmd lock_settings verify --old 0000 >/dev/null || true; t1=$(date +%s%N)
  unlock_owner  # resets the failure count
  echo $(( (t1 - t0) / 1000000 ))
}
# a file in the owner's CE storage, to tell BFU from unlocked and to check data survives
SENTINEL=/data/system_ce/0/envs-sentinel
write_sentinel() { SENT="$(date +%s%N)"; sh_ "echo $SENT > $SENTINEL && sync"; }
after_reboot_checks() {
  local s
  s="$(state 0)"; log "    owner: $s"
  [[ "$s" == *RUNNING_LOCKED* ]] && pass "owner locked after boot" || fail "owner not locked: $s"
  [[ "$(sh_ "ls /data/user/0 | head -1")" == AAAA* ]] && pass "owner CE names encrypted" \
    || fail "owner CE names readable before unlock"
  [[ "$(sh_ "cat $SENTINEL 2>/dev/null")" == "$SENT" ]] && fail "sentinel readable before unlock" \
    || pass "sentinel unreadable before unlock"
  check "owner unlocks" 'Lock credential verified' cmd lock_settings verify --old "$OWNER_PIN"
  sleep 3
  s="$(state 0)"
  [[ "$s" == *RUNNING_UNLOCKED* ]] && pass "owner unlocked" || fail "owner after unlock: $s"
  [[ "$(sh_ "cat $SENTINEL 2>/dev/null")" == "$SENT" ]] && pass "sentinel intact" \
    || fail "sentinel lost"
  sh_ "rm -f $SENTINEL"
}

case "${1:-}" in
  enrol)
    header "enrolment"
    set_reboot --reboot-pin "''"
    set_duress "''" "''"
    log "### owner PIN as reboot PIN -> collision"
    check "owner collision" 'collision: owner credential' $(reboot_cmd) --reboot-pin "$OWNER_PIN"
    log "### too short -> validation error"
    check "too short" 'validation failed' $(reboot_cmd) --reboot-pin 12
    log "### wrong owner credential -> refused"
    check "wrong owner credential" 'didn.t match|failed|error' \
      cmd lock_settings set-reboot-credential --owner-credential 0000 --reboot-pin "$REBOOT_PIN"
    unlock_owner
    log "### duress enrolled, duress PIN / password as reboot credential -> collision"
    set_duress "$DURESS_PIN" "$DURESS_PW"
    check "duress PIN collision" 'collision: duress credential' $(reboot_cmd) --reboot-pin "$DURESS_PIN"
    check "duress password collision" 'collision: duress credential' \
      $(reboot_cmd) --reboot-password "$DURESS_PW"
    log "### password variant"
    check "password set" 'Reboot credential set' $(reboot_cmd) --reboot-password reboot-pw
    log "### valid"
    check "PIN set" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    log "### reverse: reboot PIN as duress PIN -> collision, old duress kept"
    check "reverse collision" 'collision: reboot credential' \
      cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
      --duress-pin "$REBOOT_PIN" --duress-password "$DURESS_PW"
    log "### deleting and setting again"
    check "delete" 'Reboot credential deleted' $(reboot_cmd) --reboot-pin "''"
    check "set again" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    ;;
  noop)
    header "no reboot for wrong / right credentials"; id="$(boot_id)"
    set_duress "$DURESS_PIN" "$DURESS_PW"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    run cmd lock_settings verify --old 0000
    run cmd lock_settings verify --old "$OWNER_PIN"
    run cmd lock_settings verify --old reboot-pw
    no_reboot "$id" 20 || true
    log "### wrong-PIN response time, ms (20 runs each)"
    log "    duress + reboot PIN: $(for i in $(seq 20); do wrong_ms; done | tr '\n' ' ')"
    check "reboot PIN deleted" 'Reboot credential deleted' $(reboot_cmd) --reboot-pin "''"
    log "    duress only:         $(for i in $(seq 20); do wrong_ms; done | tr '\n' ' ')"
    set_duress "''" "''"
    log "    none:                $(for i in $(seq 20); do wrong_ms; done | tr '\n' ' ')"
    set_duress "$DURESS_PIN" "$DURESS_PW"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    no_reboot "$id" 5 || true
    ;;
  reboot)
    header "reboot PIN at the owner's prompt"; id="$(boot_id)"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    write_sentinel
    run cmd lock_settings verify --old "$REBOOT_PIN"
    rebooted "$id" && after_reboot_checks
    ;;
  reboot-b)
    header "reboot PIN at envB's prompt"; id="$(boot_id)"; N="$(user_id)"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    write_sentinel
    run am start-user -w "$N"
    log "    envB: $(state "$N")"
    run cmd lock_settings verify --user "$N" --old "$REBOOT_PIN"
    rebooted "$id" && after_reboot_checks
    ;;
  escrow)
    # goldfish has no reboot escrow HAL, so the escrow can be prepared but never armed: this
    # checks the clear call is harmless and the logs show it, not the armed case (Stage 6)
    header "reboot PIN with an LSKF captured for resume on reboot"; id="$(boot_id)"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    run cmd recovery request-lskf com.android.shell
    unlock_owner
    captured="$(sh_ cmd recovery is-lskf-captured com.android.shell 2>&1 || true)"
    log "    $captured"
    [[ "$captured" == *true* ]] || skip "no LSKF captured (escrow HAL fails here): only the reboot is checked, not the escrow"
    write_sentinel
    sh_ logcat -c
    run cmd lock_settings verify --old "$REBOOT_PIN"
    rebooted "$id" && after_reboot_checks
    run "logcat -d -b system,main | grep -E 'RebootEscrow|RebootBfu' | head -20"
    ;;
  lifecycle)
    header "reboot PIN after owner credential changes"; id="$(boot_id)"; N="$(user_id)"
    run am start-user -w "$N"
    deleted() { check "$1" "deleted reboot credential, $2" logcat -d -b system -s DuressPasswordHelper; }
    log "### owner PIN changed to the reboot PIN -> reboot PIN deleted"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    sh_ logcat -c
    check "owner PIN changed" 'set to' cmd lock_settings set-pin --old "$OWNER_PIN" "$REBOOT_PIN"
    deleted "deleted on PIN change" 'equal to the new owner credential'
    run cmd lock_settings verify --user "$N" --old "$REBOOT_PIN"
    no_reboot "$id" 10 || true
    check "owner PIN restored" 'set to' cmd lock_settings set-pin --old "$REBOOT_PIN" "$OWNER_PIN"
    log "### owner PIN changed to something else -> reboot PIN kept"
    check "reboot PIN enrolled" 'Reboot credential set' $(reboot_cmd) --reboot-pin "$REBOOT_PIN"
    sh_ logcat -c
    check "owner PIN changed" 'set to' cmd lock_settings set-pin --old "$OWNER_PIN" 4321
    check "owner PIN restored" 'set to' cmd lock_settings set-pin --old 4321 "$OWNER_PIN"
    log "\$ logcat: deleted reboot credential"
    [[ -z "$(sh_ logcat -d -b system -s DuressPasswordHelper | grep 'deleted reboot credential')" ]] \
      && pass "kept" || fail "deleted on an unrelated change"
    log "### owner lock removed -> reboot PIN deleted"
    sh_ logcat -c
    check "owner lock cleared" 'cleared' cmd lock_settings clear --old "$OWNER_PIN"
    deleted "deleted on lock removal" 'owner screen lock removed'
    run cmd lock_settings verify --user "$N" --old "$REBOOT_PIN"
    no_reboot "$id" 10 || true
    check "owner PIN set again" 'set to' cmd lock_settings set-pin "$OWNER_PIN"
    ;;
  cleanup)
    header "cleanup"
    set_reboot --reboot-pin "''"
    set_duress "''" "''"
    ;;
  *)
    sed -n 2,12p "$0"; exit 2 ;;
esac
log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
log "results: $RES"
[[ $FAILS == 0 ]]
