#!/usr/bin/env bash
# What A's Settings shows of B's apps, on the emulator (doc 04 *Kept out of A's screens*).
# Needs a freshly wiped emulator (EMU_ARGS=-wipe-data run.sh emulator); sets A's and B's PIN.
# Run inside the build container:  run.sh exec /src/ee1os/tests/app-list.sh
# An app is installed for B only: A's list of all apps must not name it. Then it is installed
# for A too (the list must name it now, which shows the list is read right), and its page in A
# must not offer "Uninstall for all users".
# Every check prints PASS or FAIL; the script exits 1 if any check failed.
set -uo pipefail
SERIAL="${SERIAL:-127.0.0.1:5555}"
A_PIN=111111 B_PIN=222222
# any app that isn't part of the system image; the gate has built this one
APK="${APK:-$ANDROID_PRODUCT_OUT/testcases/FrameworksServicesTests/x86_64/FrameworksServicesTests.apk}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="${RES:-$HERE/results/$(date +%F)-app-list-T3.md}"
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
ui() {
  local i x
  for i in 1 2 3 4 5; do
    x="$(sh_ "rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; \
      cat /data/local/tmp/ui.xml 2>/dev/null")" || true
    [[ "$x" == *"<hierarchy"* ]] && { echo "$x"; return 0; }
    sleep 2
  done
  return 1
}
texts() { ui | tr '>' '\n' | grep -oE '(text|content-desc)="[^"]+"' | sort -u; }
# every text of a list, read while scrolling to its end (the end: a screen that adds nothing)
all_texts() {
  local seen="" now same=0 i
  for i in $(seq 60); do
    now="$(texts)"
    if [[ -z "$(comm -13 <(echo "$seen") <(echo "$now"))" ]]; then
      same=$((same + 1)); [[ $same -ge 2 ]] && break
    else same=0; fi
    seen="$(printf '%s\n%s\n' "$seen" "$now" | sort -u)"
    sh_ input swipe 540 1600 540 700 300; sleep 1
  done
  echo "$seen"
}
all_apps() {
  sh_ am force-stop com.android.settings
  sh_ am start -a android.settings.MANAGE_ALL_APPLICATIONS_SETTINGS >/dev/null; sleep 4
  all_texts
}

[[ -f "$APK" ]] || { echo "no app to install at $APK"; exit 1; }
PKG="$(aapt2 dump badging "$APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
LABEL="$(aapt2 dump badging "$APK" | sed -n "s/^application-label:'\(.*\)'$/\1/p" | head -1)"
[[ -n "$PKG" ]] || { echo "can't read the app's name from $APK"; exit 1; }
[[ -n "$LABEL" ]] || LABEL="$PKG"   # an app without a label is listed by its package name

conn || { echo "no emulator at $SERIAL"; exit 1; }
[[ "$(sh_ id -u)" == 0 ]] || { a root >/dev/null 2>&1; sleep 3; conn; }
log ""; log "## B's apps in A's Settings — $(date -Is)"
log "build: $(sh_ getprop ro.build.fingerprint)"
log "app: $PKG, \"$LABEL\""
sh_ settings put system screen_off_timeout 1800000
sh_ cmd lock_settings set-pin "$A_PIN" >/dev/null
out="$(sh_ cmd lock_settings provision-protected-space --owner-credential "$A_PIN" \
  --protected-pin "$B_PIN" 2>&1)"
log "    $out"
[[ "$out" == "protected space is user 10" ]] || { fail "setup"; exit 1; }
sh_ input keyevent KEYCODE_WAKEUP; sh_ wm dismiss-keyguard; sleep 2
[[ "$(sh_ dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+')" == "isKeyguardShowing=false" ]] \
  || { sh_ input text "$A_PIN"; sh_ input keyevent KEYCODE_ENTER; sleep 3; }

log "### installed for B only"
timeout 300 adb -s "$SERIAL" install -t --user 10 "$APK" >/dev/null 2>&1
# read whole first: a grep that stops at its match would end the pipe early
inb="$(sh_ pm list packages --user 10)"; ina="$(sh_ pm list packages --user 0)"
if grep -qx "package:$PKG" <<< "$inb" && ! grep -qx "package:$PKG" <<< "$ina"; then
  pass "in B, not in A"
else fail "install for B only"; fi
list="$(all_apps)"
n="$(grep -c . <<< "$list")"
[[ $n -ge 20 ]] && pass "A's list of all apps read ($n texts)" || fail "A's list not read ($n texts)"
if grep -qF "\"$LABEL\"" <<< "$list"; then fail "A's list names B's app"
else pass "A's list doesn't name B's app"; fi
if grep -qiF "Not installed for this user" <<< "$list"; then fail "A's list has apps of other users"
else pass "no \"Not installed for this user\" in A's list"; fi

log "### installed for A too"
sh_ pm install-existing --user 0 "$PKG" >/dev/null
list="$(all_apps)"
if grep -qF "\"$LABEL\"" <<< "$list"; then pass "A's list names it now"
else fail "A's list doesn't name the app installed for A (the check above then says nothing)"; fi
sh_ am force-stop com.android.settings
sh_ am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d "package:$PKG" >/dev/null; sleep 4
page="$(ui)"
if [[ "$page" == *"$LABEL"* ]]; then pass "the app's page is up"; else fail "the app's page isn't up"; fi
more="$(echo "$page" | tr '>' '\n' | grep -F 'content-desc="More options"' | head -1 \
  | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
  | awk '{print int(($1+$3)/2), int(($2+$4)/2)}')"
if [[ -z "$more" ]]; then pass "no menu on the app's page, so no \"Uninstall for all users\""
else
  sh_ input tap $more; sleep 2
  menu="$(texts)"
  log "    menu: $(grep -oE 'text="[^"]+"' <<< "$menu" | tr '\n' ' ')"
  if grep -qiF "for all users" <<< "$menu"; then fail "A is offered \"Uninstall for all users\""
  else pass "no \"Uninstall for all users\" in A"; fi
  sh_ input keyevent KEYCODE_BACK
fi

log ""
if [[ $FAILS == 0 ]]; then log "app-list: all passed"; log "result: PASS"
else log "app-list: $FAILS failed"; log "result: FAIL"; fi
log "results: $RES"
[[ $FAILS == 0 ]]
