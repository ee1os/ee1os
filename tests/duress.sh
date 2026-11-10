#!/usr/bin/env bash
# Duress wipe on the emulator: enrol a duress PIN, enter it, the device must wipe and go off.
# DESTROYS the emulator's data; the last step of tests/gate.sh, on a wiped emulator of its own.
# Needs a freshly wiped emulator (EMU_ARGS=-wipe-data run.sh emulator), or for LAYOUT=plain
# one where user 0 already has A_PIN (stage1.sh setup).
# Run inside the build container:  run.sh exec '/src/ee1os/tests/duress.sh --yes-wipe'
#   LAYOUT=protected (default)  A's PIN, then a protected space as first setup makes it; B, the
#                               alternates authority, enrols duress (doc 04)
#   LAYOUT=plain                user 0 is the authority and enrols duress (stage1.sh duress)
# The duress PIN goes in through cmd lock_settings verify, which enters through checkCredential
# like the bouncer (doc 03, *Who reaches the hook*). Pass: duress enrolled, the non-CE storage
# keys gone (check-non-ce-storage-keys, as DuressPasswordTest does) and the device gone within
# LIMIT seconds. A device still up after that is a FAIL. Afterwards the emulator is off and wiped.
set -uo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
LAYOUT="${LAYOUT:-protected}"
LIMIT="${LIMIT:-60}"
A_PIN=111111 B_PIN=222222 DURESS_PIN=999999 DURESS_PW=duress-pw
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-duress-T3.md}"
mkdir -p "$(dirname "$RES")"
FAILS=0

sh_()  { timeout 60 adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
log()  { echo "$*" | tee -a "$RES"; }
pass() { log "    PASS: $*"; }
fail() { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }
up()   { [[ "$(timeout 10 adb -s "$SERIAL" get-state 2>/dev/null)" == device ]]; }
done_() {
  log "results: $RES"
  log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
  [[ $FAILS == 0 ]]; exit
}
conn() {
  local i
  for i in $(seq 30); do
    adb connect "$SERIAL" >/dev/null 2>&1
    [[ "$(timeout 10 adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] \
      && return 0
    sleep 2
  done
  return 1
}

[[ "${1:-}" == --yes-wipe ]] || { echo "destroys the emulator data; add --yes-wipe"; exit 2; }
[[ "$LAYOUT" == protected || "$LAYOUT" == plain ]] || { echo "LAYOUT is protected or plain"; exit 2; }
conn || { echo "no emulator at $SERIAL"; exit 1; }
log ""; log "## Duress wipe ($LAYOUT) — $(date -Is)"
log "build: $(sh_ getprop ro.build.fingerprint)"

# A's PIN: new, or already set (stage1.sh setup uses the same)
out="$(sh_ cmd lock_settings set-pin "$A_PIN" 2>&1)"
if [[ "$out" != "Pin set to '$A_PIN'" ]]; then
  log "    set-pin: $out"
  [[ "$(sh_ cmd lock_settings verify --old "$A_PIN" 2>&1)" == *"verified successfully"* ]] \
    || { fail "A's PIN not set"; done_; }
fi
owner="$A_PIN"
if [[ "$LAYOUT" == protected ]]; then
  out="$(sh_ cmd lock_settings provision-protected-space --owner-credential "$A_PIN" \
    --protected-pin "$B_PIN" 2>&1)"
  log "    $out"
  [[ "$out" == "protected space is user "* ]] || { fail "protected space setup"; done_; }
  owner="$B_PIN"
fi
auth="$(sh_ cmd lock_settings get-alternates-authority)"
log "    alternates authority: user $auth"

# --sleep-5s-before-poweroff (test only, needs the owner credential) keeps the device up after
# the keys are deleted, so their absence can be seen (DuressWipe.java, DuressPasswordTest.java)
out="$(sh_ cmd lock_settings set-duress-credentials --owner-credential "$owner" \
  --duress-pin "$DURESS_PIN" --duress-password "$DURESS_PW" --sleep-5s-before-poweroff 2>&1)"
rc=$?
[[ -n "$out" ]] && log "    $out"
if [[ $rc == 0 && -z "$out" ]]; then pass "duress enrolled by user $auth"
else fail "duress not enrolled (exit $rc)"; done_; fi

keys="$(sh_ cmd lock_settings check-non-ce-storage-keys)"
log "    non-CE keys before: ${keys:-none}"
[[ -n "$keys" ]] || fail "no non-CE keys before the wipe: the check after it would prove nothing"

log "### the duress PIN, entered as user 0"
out="$(sh_ cmd lock_settings verify --old "$DURESS_PIN" 2>&1)"
log "    $out"
t0=$SECONDS gone="" cleared=""
while (( SECONDS - t0 < LIMIT )); do
  if ! up; then gone=$((SECONDS - t0)); break; fi
  if [[ -z "$cleared" ]]; then
    k="$(sh_ cmd lock_settings check-non-ce-storage-keys 2>/dev/null)"; r=$?
    [[ $r == 0 && -z "$k" ]] && up && cleared=$((SECONDS - t0))
  fi
  sleep 1
done
[[ -n "$cleared" ]] && pass "no non-CE keys left after ${cleared}s" \
  || fail "non-CE keys still there (last read: ${k:-none read})"
[[ -n "$gone" ]] && pass "device gone after ${gone}s" || fail "device still up after ${LIMIT}s: duress did not fire"
log "    the emulator is wiped; the next one starts with EMU_ARGS=-wipe-data run.sh emulator"
done_
