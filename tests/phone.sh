#!/usr/bin/env bash
# Phone check of a published build on the test Pixel (doc 08, *The test Pixel*), so every
# release gets a recorded run. Runs on the Mac the phone hangs off, over adb; the steps are those
# of T13 (tests/results/2026-10-30-T13-2026102911.md), the typing that of tests/keyguard.sh.
# Not run yet: the phone can't be reached from n5, so this script is untried.
#   SERIAL=<adb serial> A_PIN=<A's PIN> B_PIN=<B's PIN> REBOOT_PIN=<reboot PIN> tests/phone.sh [step...]
#   steps, in this order by default: state open power camera lockout-a lockout-b owner reboot logs
#   escrow (doc 08 Stage 6 item 4) runs only when named; "all" is the default list plus escrow
# B is the user named "Protected" (B_USER=<id> to override). The phone must be on A's home
# screen, unlocked, at the start. Results:
# tests/results/<date>-phone-<build>.md (RES= to change), build fingerprint first, and the
# keyguard log captured during the run next to it (<...>-keyguard.log). Ends with
# "result: PASS" or "result: FAIL (n)"; steps that couldn't run (no adb) count as failed and are
# listed as NOT RUN, never as results.
#
# HARD SAFETY RULES. The phone holds real data in B.
#   - It never types, enrols or asks for a duress PIN. There is no duress variable.
#   - It never wipes, factory-resets or runs fastboot; no "cmd recovery wipe", no "adb reboot".
#   - It changes no credential and no setting: no "cmd lock_settings", no "settings put", no root.
#   - The only PINs it types are A_PIN, B_PIN, REBOOT_PIN and the wrong entries 5000..01 to
#     5000..06 (A's length; 500001-500006 for 6 digits). It refuses to run if one of the three
#     equals a wrong entry. Never use a duress PIN of that form on this phone.
#
# Leaving B with the power button drops adb until A is unlocked (doc 08). The script then says
# what the owner must do on the phone, waits for adb (OWNER_WAIT seconds, default 1800) and
# carries on; checks made without the phone count as NOT RUN.
# macOS: works with its bash 3.2; adb calls get a time limit only if timeout or gtimeout exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OWNER_WAIT="${OWNER_WAIT:-1800}"
FAILS=0 NOTRUN=0 ABORT=0 LOCKOUT_A=0
CAP_PID=""

die() { echo "phone.sh: $*" >&2; exit 2; }
if command -v timeout > /dev/null; then TMO=timeout
elif command -v gtimeout > /dev/null; then TMO=gtimeout
else TMO=""; fi
tmo() { local s=$1; shift; if [ -n "$TMO" ]; then "$TMO" "$s" "$@"; else "$@"; fi; }

[ -n "${SERIAL:-}" ] || die "SERIAL is required (adb devices)"
for v in A_PIN B_PIN REBOOT_PIN; do
  eval "p=\${$v:-}"
  [ -n "$p" ] || die "$v is required"
  case "$p" in *[!0-9]*) die "$v must be digits only" ;; esac
done
L=${#A_PIN}
[ "$L" -ge 6 ] && [ ${#B_PIN} = "$L" ] && [ ${#REBOOT_PIN} = "$L" ] \
  || die "A_PIN, B_PIN and REBOOT_PIN must have the same length, 6 or more (the layout's PIN length)"
[ "$A_PIN" != "$B_PIN" ] && [ "$A_PIN" != "$REBOOT_PIN" ] && [ "$B_PIN" != "$REBOOT_PIN" ] \
  || die "A_PIN, B_PIN and REBOOT_PIN must differ"
wrong() { printf "5%0$((L - 1))d" "$1"; }   # wrong entry n: 500001 for n=1 at 6 digits
for n in 1 2 3 4 5 6; do
  case "$(wrong $n)" in "$A_PIN"|"$B_PIN"|"$REBOOT_PIN") die "a PIN equals the wrong entry $(wrong $n)" ;; esac
done
command -v adb > /dev/null || die "no adb"

sh_()   { tmo 60 adb -s "$SERIAL" shell "$@" | tr -d '\r'; }
alive() { [ "$(tmo 10 adb -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')" = device ]; }
log()   { echo "$(date +%T) $*" | tee -a "$RES"; }
pass()  { log "    PASS: $*"; }
fail()  { log "    FAIL: $*"; FAILS=$((FAILS + 1)); }
notrun() { log "    NOT RUN: $*"; NOTRUN=$((NOTRUN + 1)); }
# judge <status> <what> [seen]: a check that didn't hold is a result only if the phone was there
judge() {
  if [ "$1" = 0 ]; then pass "$2${3:+ ($3)}"
  elif alive; then fail "$2${3:+ ($3)}"
  else notrun "$2 (no adb)"; fi
}
say() { { printf '\n>>> %s\n' "$*" > /dev/tty; } 2>/dev/null || printf '\n>>> %s\n' "$*" >&2; }
ask() {  # ask <question>: y 0, n 1, anything else or no terminal 2
  local a
  { printf '>>> %s [y/n, anything else skips] ' "$1" > /dev/tty && read -r a < /dev/tty; } 2>/dev/null || return 2
  case "$a" in y|Y) return 0 ;; n|N) return 1 ;; *) return 2 ;; esac
}

# the keyguard's own log, captured from before any typing (T13 note: a later logcat -d had
# lost the dispatch lines); restarted whenever adb comes back
cap_start() {
  cap_stop
  adb -s "$SERIAL" logcat -v time -T 1 -s KeyguardAbsKeyInputViewController >> "$CAP" 2>/dev/null &
  CAP_PID=$!
}
cap_stop() { [ -z "$CAP_PID" ] || kill "$CAP_PID" 2>/dev/null; CAP_PID=""; }
trap cap_stop EXIT
matched() { local n; n=$(grep -c "PIN entry matched user $1, switching" "$CAP" 2>/dev/null); echo "${n:-0}"; }

# back <what the owner must do>: wait for adb to return, up to OWNER_WAIT seconds
back() {
  local t0=$SECONDS
  alive && return 0
  log "    adb gone: $1"
  say "adb is gone. On the phone: $1. Waiting for adb, up to $((OWNER_WAIT / 60)) min."
  until alive; do
    if (( SECONDS - t0 > OWNER_WAIT )); then
      log "    adb didn't come back within ${OWNER_WAIT}s; the remaining steps are not run"
      ABORT=1; return 1
    fi
    sleep 5
  done
  sleep 3
  log "    adb back after $((SECONDS - t0)) s"
  cap_start
}
UNLOCK_A="unlock A with A's PIN and leave it on A's home screen"

ui() {
  sh_ "rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; \
    cat /data/local/tmp/ui.xml 2>/dev/null" || true
}
cur()    { sh_ am get-current-user; }
state()  { sh_ am get-started-user-state "$1" 2>&1; }
shown()  { sh_ dumpsys window | grep -m1 -oE 'isKeyguardShowing=[a-z]+' | cut -d= -f2; }
top()    { sh_ dumpsys activity activities | grep -m1 topResumedActivity | grep -oE 'u[0-9]+ [^ ]+'; }
focus()  { sh_ dumpsys window | grep -m1 mCurrentFocus | grep -oE 'u[0-9]+ [^ }]+'; }
uptime_s() { sh_ cat /proc/uptime | cut -d. -f1; }
# the bouncer's message line: "Try again in N seconds" (or minutes) during a lockout
msg() { sh_ input keyevent KEYCODE_WAKEUP; ui | tr '>' '\n' | grep -oE 'text="[^"]*(Try again|Wrong|Enter|PIN)[^"]*"' | head -3 | tr '\n' ' '; }
countdown() {  # prints the countdown, if one shows; uiautomator needs a few tries while it ticks
  local i c
  for i in 1 2 3; do
    c="$(msg | grep -oE 'Try again in [0-9]+ (seconds?|minutes?|hours?)' | head -1)"
    [ -n "$c" ] && { echo "$c"; return 0; }
    sleep 1
  done
  return 1
}
wait_user() { local i; for i in $(seq 25); do [ "$(cur)" = "$1" ] && return 0; sleep 1; done; return 1; }

KEYS=""   # "<key> <x> <y>" per key of the pad that is up now
keymap() {
  local x d c
  x="$(ui | tr '>' '\n')"
  KEYS=""
  for d in 0 1 2 3 4 5 6 7 8 9 _enter; do
    c="$(echo "$x" | grep -F "resource-id=\"com.android.systemui:id/key$d\"" | head -1 \
      | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' \
      | awk '{print int(($1+$3)/2), int(($2+$4)/2)}')"
    [ -z "$c" ] || KEYS="$KEYS$d $c"$'\n'
  done
  for d in 0 1 2 3 4 5 6 7 8 9; do xy "$d" > /dev/null || return 1; done
}
xy() { echo "$KEYS" | awk -v k="$1" '$1 == k { print $2, $3; f = 1 } END { exit !f }'; }
lock() { sh_ input keyevent KEYCODE_SLEEP; sleep 3; }
bouncer() {
  local i
  sh_ input keyevent KEYCODE_WAKEUP; sleep 1.5
  for i in 1 2 3 4 5; do
    ui | grep -q 'id/key1' && keymap && return 0
    sh_ input swipe $((W / 2)) $((H * 3 / 4)) $((W / 2)) $((H / 4)) 200; sleep 2
  done
  return 1
}
# the PIN as taps on the pad. With auto-confirm (on with a protected space) the OK key is hidden
# and the pad submits at the layout's length; without it the OK key is in the map and tapped
tap_pin() {
  local d
  for d in $(echo "$1" | grep -o .); do sh_ input tap $(xy "$d"); sleep 0.3; done
  if xy _enter > /dev/null; then sleep 0.5; sh_ input tap $(xy _enter); fi
  sleep 4
}
# enter <pin>: at the lock screen, from a locked or sleeping screen
enter() { bouncer && tap_pin "$1"; }
opened() {  # opened <user> <what>
  local u s
  wait_user "$1"; u="$(cur)" s="$(shown)"
  [ "$u" = "$1" ] && [ "$s" = false ]; judge $? "$2" "user $u, keyguard showing $s"
}
# to_a: the phone on, in A, unlocked; leaves B (adb may drop) and unlocks A if needed
to_a() {
  [ "$ABORT" = 0 ] || return 1
  back "$UNLOCK_A" || return 1
  if [ "$(cur)" != 0 ]; then lock; sleep 2; back "$UNLOCK_A" || return 1; fi
  [ "$(shown)" != true ] || enter "$A_PIN"
  [ "$(cur)" = 0 ] && [ "$(shown)" = false ]
}
# to_b_app: B open with its Settings on top (from A, or B if it is open already)
to_b_app() {
  [ "$ABORT" = 0 ] || return 1
  if ! alive || [ "$(cur)" != "$BU" ] || [ "$(shown)" != false ]; then
    to_a || return 1
    lock; enter "$B_PIN"; wait_user "$BU" || return 1
  fi
  sh_ am start --user "$BU" -W -a android.settings.SETTINGS > /dev/null; sleep 3
  case "$(top)" in "u$BU "*) return 0 ;; *) return 1 ;; esac
}
# rebooted <uptime before>: 0 down within 60 s and back within 300 s with a lower uptime;
# 1 no reboot, 2 not back, 3 back but the uptime isn't lower
rebooted() {
  local t0=$SECONDS u
  while alive; do
    u="$(uptime_s)"
    [ -n "$u" ] && [ "$u" -lt "$1" ] && break   # down and up between two reads
    (( SECONDS - t0 > 60 )) && return 1
    sleep 1
  done
  t0=$SECONDS
  until alive && [ "$(sh_ getprop sys.boot_completed)" = 1 ]; do
    (( SECONDS - t0 > 300 )) && return 2
    sleep 5
  done
  sleep 15   # lock screen and users settle
  u="$(uptime_s)"
  [ -n "$u" ] && [ "$u" -lt "$1" ] || return 3
}

step_state() {
  log "### 0. build, lock state, users"
  local p
  for p in ro.build.display.id ro.boot.slot_suffix ro.boot.verifiedbootstate ro.boot.flash.locked \
           ro.boot.vbmeta.device_state ro.build.version.security_patch ro.build.type sys.boot.reason; do
    log "    $p=$(sh_ getprop "$p")"
  done
  log "    users: $(sh_ pm list users | grep UserInfo | tr -s ' \n' ' ')"
  log "    now: user $(cur), keyguard showing $(shown), top $(top)"
  [ -n "$BU" ]; judge $? "users 0 and B present" "B is user ${BU:-none}"
  to_a; judge $? "A open at the start"
}

step_open() {
  log "### 1. A's PIN opens A; B's PIN at A's lock screen opens B"
  to_a || { notrun "1: A not open"; return; }
  lock; enter "$A_PIN"; opened 0 "1.1 A's PIN opens A"
  local n0 u s
  n0=$(matched "$BU")
  lock; enter "$B_PIN"; wait_user "$BU"
  u="$(cur)" s="$(state "$BU")"
  [ "$u" = "$BU" ] && [[ "$s" == *RUNNING_UNLOCKED* ]] && [ "$(shown)" = false ]
  judge $? "1.2 B's PIN at A's lock screen opens B" "user $u, $s, top $(top)"
  [ "$(matched "$BU")" -gt "$n0" ]; judge $? "1.2 dispatch logged (PIN entry matched user $BU)"
}

step_power() {
  log "### 2.1 power in B with an app open: A's lock screen, nothing of B"
  to_b_app || { notrun "2.1: B with an app open"; return; }
  log "    before: top $(top)"
  sh_ input keyevent KEYCODE_POWER
  local i u t f good=0 bad=0 seen=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    u="$(cur)" t="$(top)" f="$(focus)"
    [ -n "$u" ] || break   # adb went
    seen="$seen [$u|${t:-none}|$f]"
    if [ "$u" = 0 ] && [[ "$t" != "u$BU "* ]] && [[ "$f" == "u0 NotificationShade"* ]]; then
      good=$((good + 1))
    else bad=$((bad + 1)); fi
  done
  log "    samples after power:$seen"
  if [ $((good + bad)) -lt 3 ]; then notrun "2.1 power in B (adb went after $((good + bad)) samples)"
  else [ "$bad" = 0 ]; judge $? "2.1 power in B: user 0, nothing of B, focus on A's lock screen" "$good samples"; fi
  if alive; then
    sh_ input keyevent KEYCODE_WAKEUP; sleep 2
    [ "$(cur)" = 0 ] && [ "$(shown)" = true ]; judge $? "2.1 wake: still A's lock screen"
    enter "$A_PIN"; opened 0 "2.1 A opens after B"
  else
    back "$UNLOCK_A (adb drops when B is left with the power button)" || return
    log "    A unlocked by the owner: user $(cur), keyguard showing $(shown)"
  fi
}

step_camera() {
  log "### 3. camera over the lock screen (double power), back returns to it"
  to_a || { notrun "3: A not open"; return; }
  lock; sh_ input keyevent KEYCODE_WAKEUP; sleep 1.5
  # GestureLauncherService: two power presses within 300 ms (InputShellCommand --doubletap)
  sh_ input keyevent --doubletap KEYCODE_POWER; sleep 4
  local u t s f
  u="$(cur)" t="$(top)" s="$(shown)"
  [ "$u" = 0 ] && [[ "$t" == "u0 "*[Cc]amera* ]] && [ "$s" = true ]
  judge $? "3 camera opens over A's lock screen" "user $u, top ${t:-none}, keyguard showing $s"
  sh_ input keyevent KEYCODE_BACK; sleep 3
  u="$(cur)" s="$(shown)" f="$(focus)"
  [ "$u" = 0 ] && [ "$s" = true ] && [[ "$f" == "u0 NotificationShade"* ]]
  judge $? "3 back on A's lock screen" "user $u, keyguard showing $s, focus ${f:-none}"
  enter "$A_PIN"; opened 0 "3 A opens after the camera"
}

step_lockout_a() {
  log "### 4a. 5 wrong PINs: A's countdown shows, ticks, and A opens after it"
  to_a || { notrun "4a: A not open"; return; }
  local n c1 c2 i
  lock; bouncer || { judge 1 "4a pad up"; return; }
  for n in 1 2 3 4 5; do tap_pin "$(wrong $n)"; done
  c1="$(countdown)"; judge $? "4a.1 countdown after 5 wrong PINs" "${c1:-message: $(msg)}"
  sleep 6
  c2="$(countdown)"
  [ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" != "$c2" ]; judge $? "4a.2 countdown ticks" "$c1 -> ${c2:-none}"
  [ "$(cur)" = 0 ] && ui | grep -q 'id/key1'; judge $? "4a.3 pad still up, user 0"
  for i in $(seq 30); do countdown > /dev/null || break; sleep 5; done
  enter "$A_PIN"; opened 0 "4a.4 A opens after the lockout"
  LOCKOUT_A=1
}

step_lockout_b() {
  log "### 4b. one more wrong PIN: B alone in lockout; A still opens; B after its lockout"
  # wrong PINs count for A and B alike (doc 04); A's unlock cleared only A's count
  [ "$LOCKOUT_A" = 1 ] || { notrun "4b needs 4a right before it"; return; }
  to_a || { notrun "4b: A not open"; return; }
  local c t0 u
  lock; enter "$(wrong 6)"; t0=$SECONDS
  c="$(countdown)"; [ -n "$c" ] && [ "$(cur)" = 0 ]; judge $? "4b.1 B alone in lockout" "${c:-message: $(msg)}"
  tap_pin "$B_PIN"
  c="$(countdown)"; u="$(cur)"
  [ -n "$c" ] && [ "$u" = 0 ]; judge $? "4b.2 B's PIN during B's lockout: countdown, still user 0" "user $u, ${c:-no countdown}"
  tap_pin "$A_PIN"; opened 0 "4b.3 A opens during B's lockout"
  # 6 failures: 5 minutes (SoftwareRateLimiter.java:107; on the phone Weaver's may be longer)
  sleep $(( 320 - (SECONDS - t0) > 0 ? 320 - (SECONDS - t0) : 0 ))
  lock; enter "$B_PIN"; wait_user "$BU"; judge $? "4b.4 B opens after its lockout" "user $(cur)"
}

step_owner() {
  log "### 2.2 the physical power button in B (owner)"
  to_b_app || { notrun "2.2: B with an app open"; return; }
  say "Owner: B is open with Settings. Press the phone's power button once, watch for any flash of B's apps, then press it again to wake. A's lock screen must show, still locked. Then $UNLOCK_A."
  local t0=$SECONDS
  until ! alive || { [ "$(cur)" = 0 ] && [ "$(shown)" = false ]; }; do
    (( SECONDS - t0 > OWNER_WAIT )) && { notrun "2.2: nothing happened on the phone"; return; }
    sleep 2
  done
  back "$UNLOCK_A" || { notrun "2.2 (no adb)"; return; }
  ask "Both presses: A's lock screen, still locked, nothing of B shown, not even briefly?"
  case $? in
    0) pass "2.2 physical power in B: A's lock screen, still locked, no flash of B (owner)" ;;
    1) fail "2.2 physical power in B (owner saw B or an unlocked A)" ;;
    *) notrun "2.2 physical power in B (no answer)" ;;
  esac
}

# reboot_pin <tag>: the reboot PIN at A's lock screen; checks the boot, A left before first unlock
reboot_pin() {
  local up0 r br
  up0="$(uptime_s)"
  [ -n "$up0" ] || { notrun "$1 reboot PIN (can't read /proc/uptime)"; return 1; }
  lock; enter "$REBOOT_PIN"
  rebooted "$up0"; r=$?
  case $r in
    1) judge 1 "$1 reboot PIN reboots" "no reboot within 60 s"; return 1 ;;
    2) notrun "$1 reboot PIN (the phone didn't come back within 300 s)"; return 1 ;;
    3) judge 1 "$1 reboot PIN reboots" "back, but uptime $(uptime_s) s"; return 1 ;;
  esac
  pass "$1 reboot PIN reboots (uptime $(uptime_s) s)"
  cap_start
  br="$(sh_ getprop sys.boot.reason)"
  [ "$br" = reboot,userrequested ]; judge $? "$1 boot reason reboot,userrequested" "$br"
  [ "$(sh_ getprop ro.build.display.id)" = "$BN" ]; judge $? "$1 same build" "$(sh_ getprop ro.build.display.id)$(sh_ getprop ro.boot.slot_suffix)"
  [[ "$(state 0)" == *RUNNING_LOCKED* ]]; judge $? "$1 user 0 RUNNING_LOCKED" "$(state 0)"
}

step_reboot() {
  log "### 5. reboot PIN at A's lock screen, then B as first unlock, then A"
  to_a || { notrun "5: A not open"; return; }
  reboot_pin 5.1 || return
  local n0 u
  n0=$(matched "$BU")
  enter "$B_PIN"; wait_user "$BU"; u="$(cur)"
  [ "$u" = "$BU" ] && [[ "$(state "$BU")" == *RUNNING_UNLOCKED* ]] && [[ "$(state 0)" == *RUNNING_LOCKED* ]]
  judge $? "5.2 B first after the boot, A still locked" "user $u, B $(state "$BU"), A $(state 0)"
  [ "$(matched "$BU")" -gt "$n0" ]; judge $? "5.2 dispatch logged (PIN entry matched user $BU)"
  lock; wait_user 0; u="$(cur)"
  if [ -z "$u" ] && ! alive; then
    notrun "5.3 lock in B (adb dropped)"; notrun "5.4 A after B first (the owner unlocked A)"
    back "$UNLOCK_A"; return
  fi
  [ "$u" = 0 ]; judge $? "5.3 lock in B: user 0" "user $u"
  enter "$A_PIN"; wait_user 0
  [[ "$(state 0)" == *RUNNING_UNLOCKED* ]] && [ "$(shown)" = false ]
  judge $? "5.4 A opens after B first (A's first unlock)" "A $(state 0)"
  log "    B now: $(state "$BU")"
}

step_logs() {
  log "### 6. users kept, crashes and ANRs"
  back "$UNLOCK_A" || { notrun "6: no adb"; return; }
  local users n crash
  users="$(sh_ pm list users)"
  [[ "$users" == *"UserInfo{0:"* && "$users" == *"UserInfo{$BU:"* ]]
  judge $? "6a users 0 and $BU kept" "$(echo "$users" | grep -c UserInfo) users"
  n="$(sh_ logcat -d -b main,system,crash | grep -cE 'FATAL EXCEPTION|ANR in ')"
  [ "${n:-x}" = 0 ]; judge $? "6b no FATAL EXCEPTION or ANR in logcat since the boot" "${n:-not read}"
  crash="$(sh_ logcat -d -b crash)"
  log "    crash buffer: $(echo "$crash" | grep -E 'Fatal signal|FATAL EXCEPTION' | head -5 | tr '\n' ' ')"
  # known: init's SIGABRT from /vendor/bin/gpuflag a few seconds into a boot (T11-T13)
  [ -z "$(echo "$crash" | grep -E 'Fatal signal|FATAL EXCEPTION' | grep -v '(init)')" ]
  judge $? "6c no crash in the crash buffer other than init's known one"
}

step_escrow() {
  log "### escrow (doc 08 Stage 6 item 4): LSKF captured, then the reboot PIN; A must stay locked"
  # The shell may call these on a user build: RecoverySystemService.onShellCommand only checks
  # that the caller is shell, then clears the calling identity, so the RECOVERY/REBOOT check
  # (enforcePermissionForResumeOnReboot) sees system_server (RecoverySystemService.java:1257-1270,
  # :593-601); no debuggable check. Shell holds REBOOT anyway (packages/Shell/AndroidManifest.xml:211).
  to_a || { notrun "escrow: A not open"; return; }
  local out
  out="$(sh_ cmd recovery request-lskf com.android.shell 2>&1)"; log "    $out"
  [[ "$out" == *"status: success"* ]]; judge $? "escrow: LSKF requested"
  lock; enter "$A_PIN"; opened 0 "escrow: A unlocks (the LSKF is captured on unlock)"
  out="$(sh_ cmd recovery is-lskf-captured com.android.shell 2>&1)"; log "    $out"
  [[ "$out" == *"capture status: true"* ]]; judge $? "escrow: LSKF captured"
  if reboot_pin "escrow:"; then
    enter "$A_PIN"; opened 0 "escrow: A opens after the boot"
  else
    alive && sh_ cmd recovery clear-lskf com.android.shell | sed 's/^/    /' | tee -a "$RES"
  fi
}

alive || die "no device $SERIAL (adb devices; if the phone is in B, $UNLOCK_A)"
BN="$(sh_ getprop ro.build.display.id)" FP="$(sh_ getprop ro.build.fingerprint)"
[ -n "$BN" ] && [ -n "$FP" ] || die "can't read the build from $SERIAL"
RES="${RES:-$HERE/results/$(date +%F)-phone-$BN.md}"
mkdir -p "$(dirname "$RES")"
[ -s "$RES" ] || echo "build: $FP" > "$RES"
CAP="${RES%.md}-keyguard.log"
WH="$(sh_ wm size | tail -1 | grep -oE '[0-9]+x[0-9]+')"
W="${WH%x*}" H="${WH#*x}"
[ -n "$WH" ] || die "can't read the screen size"
# B: the protected space's user (named "Protected" by its setup), or B_USER
BU="${B_USER:-$(sh_ pm list users | sed -n 's/.*UserInfo{\([0-9]*\):Protected:.*/\1/p' | head -1)}"
case "$BU" in ''|*[!0-9]*) die "no protected space user found; set B_USER" ;; 0) die "B can't be user 0" ;; esac

STEPS="${*:-default}"
STEPS="${STEPS/all/default escrow}"
STEPS="${STEPS/default/open power camera lockout-a lockout-b owner reboot logs}"
for s in $STEPS; do
  case "$s" in open|power|camera|lockout-a|lockout-b|owner|reboot|logs|escrow) ;; *) die "unknown step $s" ;; esac
done

log ""; log "## Phone check of $BN on $SERIAL — $(date +%FT%T%z); steps: $STEPS"
log "build: $FP"
cap_start
step_state
for s in $STEPS; do
  if [ "$ABORT" = 1 ]; then notrun "$s (no adb)"; continue; fi
  case "$s" in
    open) step_open ;; power) step_power ;; camera) step_camera ;;
    lockout-a) step_lockout_a ;; lockout-b) step_lockout_b ;; owner) step_owner ;;
    reboot) step_reboot ;; logs) step_logs ;; escrow) step_escrow ;;
  esac
done
alive && [ "$(cur)" != 0 ] && say "The phone is left in B."
log "not run: $NOTRUN"
log "results: $RES (keyguard log: $CAP)"
n=$((FAILS + NOTRUN))
log "result: $([ "$n" = 0 ] && echo PASS || echo "FAIL ($n)")"
[ "$n" = 0 ]
