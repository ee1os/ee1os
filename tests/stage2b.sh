#!/usr/bin/env bash
# Stage 2b checks: Reboot PIN screens in Settings, driven with uiautomator
# (docs/07-roadmap.md, Stage 2b; doc 04 *Settings flow*). Needs the Stage 2 builds of
# frameworks/base and Settings and the Stage 1 setup (owner PIN).
# Run inside the build container:  run.sh exec /src/ee1os/tests/stage2b.sh <item>
#   screens    add, duress collision error, update, delete, add again through the screens
# Every check prints PASS or FAIL; the script exits 1 if any check failed.
# Screen behaviour (layout, keyboard, texts) is still a T4 check: this only proves the flow.
set -euo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
OWNER_PIN=1111 DURESS_PIN=9999 DURESS_PW=duress-pw REBOOT_PIN=5555
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/results/$(date +%F)-stage2b-T3.md"
mkdir -p "$HERE/results"
FAILS=0
PKG=com.android.settings

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
# a fresh hierarchy dump, never a stale one
ui() {
  sh_ "rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; \
    cat /data/local/tmp/ui.xml 2>/dev/null" || true
}
# centre of the first node whose attribute $1 equals $2
centre() {
  { ui | tr '>' '\n' | grep -F "$1=\"$2\"" || true; } | head -1 \
    | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
    | awk '{print int(($1+$3)/2), int(($2+$4)/2)}'
}
tap() {  # tap <attr> <value>
  local xy; xy="$(centre "$1" "$2")"
  [[ -n "$xy" ]] || { fail "no node $1=\"$2\" on screen"; return 1; }
  sh_ input tap $xy; sleep 1.5
}
type_into() {  # type_into <resource-id suffix> <text>: replaces the field's text
  tap resource-id "$PKG:id/$1" || return 1
  sh_ input keycombination KEYCODE_CTRL_LEFT KEYCODE_A; sh_ input keyevent KEYCODE_DEL
  sh_ input text "$2"; sleep 0.5
}
on_screen() {  # on_screen "<what>" <text>: some node shows <text>
  local i
  for i in 1 2 3 4 5; do
    ui | grep -qF "$2" && { pass "$1"; return 0; }
    sleep 1
  done
  fail "$1 (\"$2\" not on screen)"
}
# the action items are below the long description
scroll_down() { sh_ input swipe 540 1600 540 400 300; sleep 1; }
open_main() {
  sh_ am force-stop "$PKG"
  run am start -W -n "$PKG/.security.RebootCredentialMainActivity"
  # owner credential confirmation: wait for the PIN pad, typing earlier is lost
  local i
  for i in $(seq 10); do ui | grep -qF 'Enter PIN' && break; sleep 1; done
  sh_ input text "$OWNER_PIN"; sh_ input keyevent KEYCODE_ENTER; sleep 3
}

cleanup() {
  sh_ am force-stop "$PKG" >/dev/null 2>&1 || true
  sh_ cmd lock_settings set-reboot-credential --owner-credential "$OWNER_PIN" --reboot-pin "''" \
    >/dev/null 2>&1 || true
  sh_ cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
    --duress-pin "''" --duress-password "''" >/dev/null 2>&1 || true
}

case "${1:-}" in
  screens)
    trap 'cleanup; log "result: $([[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)") (exit trap)"' EXIT
    a connect "$SERIAL" >/dev/null 2>&1 || true
    wait_boot; a root >/dev/null; a wait-for-device
    sh_ cmd lock_settings verify --old "$OWNER_PIN" >/dev/null
    sh_ input keyevent KEYCODE_WAKEUP; sh_ wm dismiss-keyguard; sleep 1
    log ""; log "## Reboot PIN screens — $(date -Is)"
    log "build: $(sh_ getprop ro.build.fingerprint), Settings: $(sh_ "stat -c %y \$(pm path $PKG | head -1 | cut -d: -f2)")"
    run cmd lock_settings set-reboot-credential --owner-credential "$OWNER_PIN" --reboot-pin "''"
    run cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
      --duress-pin "$DURESS_PIN" --duress-password "$DURESS_PW"

    log "### add"
    open_main
    on_screen "main screen after owner PIN" "Add reboot PIN or password"
    tap text "Add reboot PIN or password"
    on_screen "setup screen" "Enter reboot PIN"
    log "### collision with the duress PIN -> error, nothing saved"
    type_into credential_input "$DURESS_PIN"
    type_into credential_input_confirmation "$DURESS_PIN"
    tap text "Add"
    on_screen "duress collision shown" "same as the duress PIN or password"
    tap text "Dismiss"
    log "### valid PIN"
    type_into credential_input "$REBOOT_PIN"
    type_into credential_input_confirmation "$REBOOT_PIN"
    tap text "Add"
    # like the duress screens, saving closes both screens (setup reports cancelled on stop)
    open_main
    on_screen "reopened: update / delete offered" "Update reboot PIN or password"

    log "### update to another PIN"
    tap text "Update reboot PIN or password"
    on_screen "update screen" "Enter reboot PIN"
    type_into credential_input 6666
    type_into credential_input_confirmation 6666
    tap text "Update"
    out="$(sh_ cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
      --duress-pin 6666 --duress-password "$DURESS_PW" 2>&1 || true)"
    [[ "$out" == *"collision: reboot credential"* ]] && pass "service has the updated PIN" \
      || fail "service doesn't have the updated PIN: $out"

    log "### delete"
    open_main
    on_screen "reopened after update" "Update reboot PIN or password"
    scroll_down
    tap text "Delete reboot PIN or password"
    tap text "Delete"
    scroll_down
    on_screen "deleted, add offered again" "Add reboot PIN or password"

    log "### the service agrees: add through the screen, then the shell sees a collision"
    tap text "Add reboot PIN or password"
    type_into credential_input "$REBOOT_PIN"
    type_into credential_input_confirmation "$REBOOT_PIN"
    tap text "Add"
    open_main
    on_screen "added again" "Update reboot PIN or password"
    out="$(sh_ cmd lock_settings set-duress-credentials --owner-credential "$OWNER_PIN" \
      --duress-pin "$REBOOT_PIN" --duress-password "$DURESS_PW" 2>&1 || true)"
    log "    duress = reboot PIN through the shell: $out"
    [[ "$out" == *"collision: reboot credential"* ]] && pass "service has the PIN from the screen" \
      || fail "service doesn't know the PIN from the screen"

    ;;
  *)
    sed -n 2,8p "$0"; exit 2 ;;
esac
log "results: $RES"
[[ $FAILS == 0 ]]
