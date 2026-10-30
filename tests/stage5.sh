#!/usr/bin/env bash
# Stage 5 checks: envB unlocked while the owner stays locked (docs/07-roadmap.md, Stage 5).
# Needs the Stage 1 setup (owner PIN, envB with its own PIN).
# Run inside the build container:  run.sh exec /src/ee1os/tests/stage5.sh <item>
#   storage    reboot, unlock envB first: shared storage, MediaStore, owner CE still locked,
#              then the owner unlocks with both users' storage working
# Every check prints PASS or FAIL; the script exits 1 if any check failed.
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=1111 B_PIN=2222
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/results/$(date +%F)-stage5-T3.md"
mkdir -p "$HERE/results"
FAILS=0

a()   { adb -s "$SERIAL" "$@"; }
sh_() { a shell "$@" | tr -d '\r'; }
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
wait_services() {
  until sh_ service check activity | grep -q found && sh_ service check lock_settings | grep -q found; do
    sleep 2
  done
}
user_id() { sh_ pm list users | sed -n 's/.*UserInfo{\([0-9]*\):envB:.*/\1/p'; }
state()   { sh_ am get-started-user-state "$1" 2>&1 || true; }
owner_locked() { [[ "$(sh_ "ls /data/user/0 | head -1")" == AAAA* ]]; }
# poll until $2 (a shell condition) holds, up to $1 seconds
wait_for() {
  local i
  for ((i = 0; i < $1; i++)); do sh_ "$2" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
storage_checks() {  # $1 user
  # the FUSE view of user $1, the root shell's /storage is user 0's
  local d="/mnt/user/$1/emulated/$1"
  wait_for 30 "test -d $d/Download" && pass "$d mounted" || fail "$d not mounted"
  check "volume of user $1 mounted" "emulated;$1 mounted" sm list-volumes all
  local f="$d/Download/envs-$(date +%s).txt"
  sh_ "echo stage5 > $f"
  [[ "$(sh_ "cat $f" 2>/dev/null)" == stage5 ]] && pass "write + read on user $1's storage" \
    || fail "no write on user $1's storage"
  sh_ "rm -f $f"
  check "MediaStore of user $1 answers" 'Row:|No result found' \
    content query --user "$1" --uri content://media/external/file --projection _id
}

case "${1:-}" in
  storage)
    a connect "$SERIAL" >/dev/null 2>&1 || true
    wait_boot; wait_services; a root >/dev/null; a wait-for-device; wait_services
    N="$(user_id)"
    log ""; log "## envB before the owner, shared storage — $(date -Is)"
    log "build: $(sh_ getprop ro.build.fingerprint), system_server: $(sh_ "stat -c %y /system/framework/services.jar")"
    run settings put global allow_user_switching_when_system_user_locked 1
    # a right entry clears envB's failure count, earlier tests may have left it throttled
    sh_ cmd lock_settings verify --user "$N" --old "$B_PIN" >/dev/null || true
    a reboot; wait_boot; wait_services; a root >/dev/null; a wait-for-device; wait_services
    owner_locked && pass "owner locked after boot" || fail "owner CE readable after boot"
    sh_ logcat -c
    run am start-user "$N"
    check "envB unlocks" 'Lock credential verified' \
      cmd lock_settings verify --user "$N" --old "$B_PIN"
    wait_for 30 "am get-started-user-state $N | grep -q RUNNING_UNLOCKED" \
      && pass "envB RUNNING_UNLOCKED" || fail "envB: $(state "$N")"
    storage_checks "$N"
    owner_locked && pass "owner CE still locked" || fail "owner CE unlocked"
    [[ "$(state 0)" == *RUNNING_LOCKED* ]] && pass "owner RUNNING_LOCKED" || fail "owner: $(state 0)"
    run "logcat -d -b system,main | grep -E 'StorageSessionController|StorageUserConnection|unmounted due to' | head -20"
    [[ -z "$(sh_ "logcat -d -b crash | grep 'FATAL EXCEPTION IN SYSTEM PROCESS'")" ]] \
      && pass "no system_server crash" || fail "system_server crashed"
    log "### the owner unlocks afterwards"
    check "owner unlocks" 'Lock credential verified' cmd lock_settings verify --old "$OWNER_PIN"
    wait_for 30 "am get-started-user-state 0 | grep -q RUNNING_UNLOCKED" \
      && pass "owner RUNNING_UNLOCKED" || fail "owner: $(state 0)"
    storage_checks 0
    storage_checks "$N"
    run settings put global allow_user_switching_when_system_user_locked 0
    ;;
  *)
    sed -n 2,7p "$0"; exit 2 ;;
esac
log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
log "results: $RES"
[[ $FAILS == 0 ]]
