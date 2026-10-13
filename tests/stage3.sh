#!/usr/bin/env bash
# Stage 3 checks (docs/07-roadmap.md, Stage 3). Needs the Stage 1 setup (owner PIN, envB).
# Run inside the build container:  run.sh exec /src/os-ivan-gg/tests/stage3.sh <item>
#   openfiles  use envB, stop it, list CE files of envB still open after the key is removed (3c)
# Every check prints PASS or FAIL; the script exits 1 if any check failed.
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=1111 B_PIN=2222
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/results/$(date +%F)-stage3-T3.md"
mkdir -p "$HERE/results"
FAILS=0

a()   { adb -s "$SERIAL" "$@"; }
sh_() { a shell "$@" | tr -d '\r'; }
log() { echo "$*" | tee -a "$RES"; }
run() { log "\$ $*"; { sh_ "$@" 2>&1 || true; } | sed 's/^/    /' | tee -a "$RES"; }
pass() { log "    PASS: $*"; }
fail() { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }

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
header() {
  a connect "$SERIAL" >/dev/null 2>&1 || true
  wait_boot; wait_services
  a root >/dev/null; a wait-for-device; wait_services
  # after a boot the owner is locked and switching / starting other users is refused
  sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null
  log ""; log "## $1 — $(date -Is)"
  log "build: $(sh_ getprop ro.build.fingerprint)"
}
locked()  { [[ "$(sh_ "ls /data/user/$1 | head -1")" == AAAA* ]]; }
ce_open() {  # process, pid, path of every open file under N's CE directories
  sh_ "lsof 2>/dev/null | grep -E '/data/(system_ce|misc_ce|vendor_ce|user|media)/$1/' \
    | awk '{print \$1, \$2, \$NF}' | sort -u"
}

case "${1:-}" in
  openfiles)
    header "3c: open CE files after stop"; N="$(user_id)"
    sh_ am switch-user "$N"; sleep 6
    run cmd lock_settings verify --user "$N" --old "$B_PIN"
    sh_ wm dismiss-keyguard
    for act in android.settings.SETTINGS android.intent.action.DIAL \
               android.media.action.IMAGE_CAPTURE android.settings.SYNC_SETTINGS; do
      sh_ am start --user "$N" -a "$act" >/dev/null 2>&1 || true; sleep 4
    done
    open_before="$(ce_open "$N" | wc -l)"
    log "    envB: $(sh_ am get-started-user-state "$N"), CE files open: $open_before"
    (( open_before > 0 )) && pass "envB used ($open_before CE files open)" \
      || fail "nothing open, the test didn't exercise envB"
    sh_ am switch-user 0; sleep 6
    sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null
    sh_ logcat -c
    t0=$SECONDS
    run am stop-user -w "$N"
    for i in $(seq 60); do locked "$N" && break; sleep 1; done
    locked "$N" && pass "CE locked after $((SECONDS - t0)) s" || fail "CE not locked after 60 s"
    left="$(ce_open "$N")"
    log "    CE files still open after the stop:"
    echo "$left" | sed '/^$/d; s/^/      /' | tee -a "$RES"
    [[ -z "$left" ]] && pass "no CE files open" || fail "$(echo "$left" | wc -l) CE files open"
    warn="$(sh_ "logcat -d -b main | grep -E 'vold.*(still has unlocked files|were not locked)' \
      | grep -v adbd" || true)"
    [[ -z "$warn" ]] && pass "no vold warning" || { fail "vold warning"; log "$warn"; }
    ;;
  *)
    sed -n 2,4p "$0"; exit 2 ;;
esac
log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
log "results: $RES"
[[ $FAILS == 0 ]]
