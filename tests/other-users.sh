#!/usr/bin/env bash
# Users beside A and B, and B's removal, on the emulator (doc 04, decision 2026-11-11).
# Needs a freshly wiped emulator (EMU_ARGS=-wipe-data run.sh emulator); sets A's and B's PIN.
# Run inside the build container:  run.sh exec /src/ee1os/tests/other-users.sh
#   1. a third user is added and opened; screen off returns to A and the third user is stopped,
#      although it has no "run in background" restriction of its own
#   2. B is removed: what setup changed on A (no removing users, no private space, user
#      switcher off) is put back
# Every check prints PASS or FAIL; the script exits 1 if any check failed.
set -uo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
A_PIN=111111 B_PIN=222222
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-other-users-T3.md}"
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
cur() { sh_ am get-current-user; }
wait_user() {
  local i
  for i in $(seq 30); do [[ "$(cur)" == "$1" ]] && return 0; sleep 1; done
  return 1
}
state() { sh_ am get-started-user-state "$1" 2>&1 | tail -1; }
# the restrictions of a user as dumpsys prints them, on one line
restrictions() {
  local d; d="$(sh_ dumpsys user)"
  awk -v u="UserInfo{$1:" '
    index($0, u) {on = 1; next}
    on && /UserInfo\{/ {on = 0}
    on && /no_[a-z_]+/ {printf "%s ", $0}' <<< "$d" | tr -s ' '
}

conn || { echo "no emulator at $SERIAL"; exit 1; }
[[ "$(sh_ id -u)" == 0 ]] || { a root >/dev/null 2>&1; sleep 3; conn; }
log ""; log "## Other users beside the protected space — $(date -Is)"
log "build: $(sh_ getprop ro.build.fingerprint)"
sh_ settings put system screen_off_timeout 1800000
sh_ cmd lock_settings set-pin "$A_PIN" >/dev/null
out="$(sh_ cmd lock_settings provision-protected-space --owner-credential "$A_PIN" \
  --protected-pin "$B_PIN" 2>&1)"
log "    $out"
[[ "$out" == "protected space is user 10" ]] || { fail "setup"; exit 1; }
before="$(restrictions 0)"
log "    user 0 with the protected space: $before; user_switcher_enabled=$(sh_ settings get global user_switcher_enabled)"
[[ "$before" == *no_remove_user* ]] && pass "setup set no_remove_user on user 0" \
  || fail "no_remove_user not seen on user 0 (the checks of part 2 then say nothing)"

log "### a third user: stopped when the screen goes off"
out="$(sh_ pm create-user third 2>&1)"; log "    $out"
T="$(grep -oE '[0-9]+$' <<< "$out")"
[[ -n "$T" ]] || { fail "third user not created"; T=0; }
if [[ "$T" != 0 ]]; then
  r="$(restrictions "$T")"
  [[ "$r" != *no_run_in_background* ]] && pass "user $T has no run-in-background restriction" \
    || log "    note: user $T has no_run_in_background of its own: $r"
  sh_ input keyevent KEYCODE_WAKEUP; sh_ am switch-user "$T" >/dev/null
  if wait_user "$T"; then pass "user $T is in front"; else fail "switch to user $T (user $(cur))"; fi
  for i in $(seq 30); do [[ "$(state "$T")" == RUNNING_UNLOCKED ]] && break; sleep 1; done
  log "    user $T: $(state "$T")"
  sh_ input keyevent KEYCODE_SLEEP
  if wait_user 0; then pass "user 0 after screen off"; else fail "still user $(cur) after screen off"; fi
  st=""
  for i in $(seq 30); do
    st="$(state "$T")"; [[ "$st" != RUNNING* && "$st" != STOPPING* && "$st" != SHUTDOWN* && "$st" != BOOTING* ]] && break
    sleep 1
  done
  if [[ "$st" == *"not started"* ]]; then pass "user $T is stopped ($st)"
  else fail "user $T still runs behind user 0: $st"; fi
fi

log "### B is removed: A gets its settings back"
# as B's own shell user: user 0 may not remove users (no_remove_user), B may remove itself
out="$(sh_ "su 1002000 pm remove-user 10" 2>&1)"; log "    $out"
for i in $(seq 60); do sh_ pm list users | grep -q 'UserInfo{10:' || break; sleep 1; done
users="$(sh_ pm list users)"
if grep -q 'UserInfo{10:' <<< "$users"; then fail "user 10 is still there"; else pass "user 10 is gone"; fi
sleep 5
after="$(restrictions 0)"
log "    user 0 now: ${after:-no restrictions}; user_switcher_enabled=$(sh_ settings get global user_switcher_enabled)"
[[ "$after" != *no_remove_user* ]] && pass "no_remove_user is off" || fail "no_remove_user stays on user 0"
[[ "$after" != *no_add_private_profile* ]] && pass "no_add_private_profile is off" \
  || fail "no_add_private_profile stays on user 0"
[[ "$(sh_ settings get global user_switcher_enabled)" == 1 ]] && pass "user switcher is back on" \
  || fail "user switcher stays off"
[[ "$(sh_ settings get global allow_user_switching_when_system_user_locked)" == 0 ]] \
  && pass "no switching while user 0 is locked" || fail "switching while user 0 is locked stays on"

log ""
if [[ $FAILS == 0 ]]; then log "other-users: all passed"; log "result: PASS"
else log "other-users: $FAILS failed"; log "result: FAIL"; fi
log "results: $RES"
[[ $FAILS == 0 ]]
