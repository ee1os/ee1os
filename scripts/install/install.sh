#!/usr/bin/env bash
# Install os.ivan.gg on a phone from macOS or Linux.
#
#   curl -fLO https://os.ivan.gg/install.sh && bash install.sh
#
#   --check        check the computer, fastboot and the phone, then stop; changes nothing
#   --no-lock      flash but leave the bootloader unlocked
#   --zip PATH     use a downloaded <codename>-install-<build>.zip instead of downloading
#   --send PATH    send an install.log to Ivan
#
# Steps: 1 computer, 2 fastboot, 3 phone, 4 download, 5 unlock, 6 flash, 7 lock.
# Everything goes to ~/os-ivan-gg-install/<time>/install.log. On failure the script shows
# what went wrong and offers to send the log. Works with bash 3.2 (macOS).
set -u -o pipefail

VERSION=1
SITE=${OSIVANGG_SITE:-https://os.ivan.gg}
RELEASES=${OSIVANGG_RELEASES:-https://github.com/os-ivan-gg/releases/releases/download}
# SHA-256 of avb_pkmd.bin, the public half of the verified boot key. Fetched from a different
# host than the zip, so a swapped zip is caught even if its checksum file was swapped too.
FINGERPRINT=65894abf95040084e7f27ff8cb8e0d291b04abc266103fb88cef5e0c8c8bf161
FASTBOOT_MIN=35.0.1
PT_VERSION=37.0.1
PT_SHA256_DARWIN=ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d
PT_SHA256_LINUX=d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1
NEED_GB=${OSIVANGG_NEED_GB:-10}
WAIT=${OSIVANGG_WAIT:-180}
# Where answers come from; the tests point this at a file.
TTY=${OSIVANGG_TTY:-/dev/tty}

BASE=${OSIVANGG_HOME:-$HOME/os-ivan-gg-install}
CACHE=$BASE/cache
TOTAL=7

MODE=install
LOCK=1
ZIP=
SEND=
STEP=0
STEP_NAME="start"
LAST_CMD=
LAST_RC=
SERIAL=
FLASHING=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case $1 in
        --check) MODE=check ;;
        --no-lock) LOCK=0 ;;
        --zip) ZIP=${2:-}; shift ;;
        --send) SEND=${2:-}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- output and log

if [ -t 1 ]; then B=$(printf '\033[1m'); R=$(printf '\033[31m'); N=$(printf '\033[0m'); else B=; R=; N=; fi

say() { printf '%s\n' "$*"; }
step() {
    STEP=$1; STEP_NAME=$2; LAST_CMD=
    printf '\n%s== Step %s of %s: %s%s\n' "$B" "$STEP" "$TOTAL" "$STEP_NAME" "$N"
}

# Run a command, log it and its output, remember its exit code.
run() {
    LAST_CMD="$*"
    say "\$ $*"
    "$@"
    LAST_RC=$?
    return $LAST_RC
}

# Like run, but a failure stops the install.
must() { run "$@" || fail "This command failed."; }

ask() {
    # Prompts read the terminal, so the script also works when piped.
    local ans
    printf '%s ' "$1"
    [ -n "${TTY_OPEN:-}" ] || { exec 5< "$TTY" && TTY_OPEN=1; } 2>/dev/null
    if ! read -r ans <&5; then ans=; fi
    say "(answered: $ans)"
    REPLY=$ans
}

sha256() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

grouped() { printf '%s\n' "$1" | sed 's/\(........\)/\1 /g; s/ $//'; }

# Write a copy of the log for sending: colour codes go, the phone's serial becomes a short
# hash, the home folder becomes ~.
redact() {
    local tag=
    if [ -n "$SERIAL" ]; then tag="serial-$(printf '%s' "$SERIAL" | sha256 /dev/stdin | cut -c1-8)"; fi
    awk -v s="$SERIAL" -v t="$tag" -v h="$HOME" '
        function swap(line, from, to,    out, i) {
            if (from == "") return line
            out = ""
            while ((i = index(line, from)) > 0) { out = out substr(line, 1, i - 1) to; line = substr(line, i + length(from)) }
            return out line
        }
        { gsub(/\033\[[0-9;]*m/, ""); print swap(swap($0, s, t), h, "~") }' "$1"
}

send_log() {
    local log=$1 out id
    [ -s "$log" ] || { say "No log at $log."; return 1; }
    out="${log%.log}.sent.log"
    redact "$log" > "$out"
    # The endpoint takes up to 1 MB; keep the end, where the error is.
    if [ "$(wc -c < "$out")" -gt 1000000 ]; then
        tail -c 1000000 "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    fi
    say "Sending $out ..."
    if id=$(curl -fsS --max-time 60 -H 'Content-Type: text/plain; charset=utf-8' \
            -H "X-Install-Script: sh/$VERSION" --data-binary "@$out" "$SITE/api/report"); then
        say ""
        say "${B}Sent. Report ID: $id${N}"
        say "Give Ivan this ID when you get in touch."
    else
        say "Sending failed (no internet, or the site is down)."
        say "Send this file to Ivan yourself: $out"
    fi
}

offer_report() {
    say ""
    say "The full log is $LOG"
    if [ -r "$TTY" ]; then
        ask "Send this log to Ivan? It goes to os.ivan.gg with your phone's serial number and home folder removed. [y/N]"
        case $REPLY in [yY]*) send_log "$LOG" ;; *) say "Not sent." ;; esac
    fi
}

fail() {
    trap - INT
    # Read the log's end before adding the summary to it.
    sleep 1
    local last
    last=$(tail -n 20 "$LOG")
    say ""
    say "${R}${B}Install stopped in step $STEP of $TOTAL ($STEP_NAME).${N}"
    say "$1"
    if [ -n "$LAST_CMD" ]; then say "Last command: $LAST_CMD (exit code ${LAST_RC:-?})"; fi
    if [ "$FLASHING" = 1 ]; then
        say "The phone may be partly flashed. Don't lock the bootloader. Run this script again"
        say "to flash it again; nothing on the phone needs saving at this point."
    fi
    say ""
    say "Last lines of the log:"
    printf '%s\n' "$last" | sed 's/^/  | /'
    offer_report
    exit 1
}

# ---------------------------------------------------------------- send mode

if [ -n "$SEND" ]; then
    LOG=$SEND
    send_log "$SEND"
    exit $?
fi

# ---------------------------------------------------------------- run folder and log

RUN=$BASE/$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN" "$CACHE" || { echo "Can't create $RUN"; exit 1; }
LOG=$RUN/install.log
: > "$LOG"
exec 3>&1 4>&2
exec > >(tee -a "$LOG") 2>&1
trap 'fail "Stopped with Ctrl-C."' INT

say "${B}os.ivan.gg installer${N} (script version $VERSION, mode: $MODE$( [ $LOCK = 0 ] && echo ', no lock'))"
say "Started $(date -u '+%Y-%m-%d %H:%M UTC'). Log: $LOG"

# ---------------------------------------------------------------- 1. computer

step 1 "Check the computer"
OS=$(uname -s)
ARCH=$(uname -m)
case $OS in
    Darwin) say "macOS $(sw_vers -productVersion 2>/dev/null) on $ARCH"; PT_OS=darwin; PT_SHA=$PT_SHA256_DARWIN ;;
    Linux)
        # shellcheck disable=SC1091
        say "Linux: $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown) on $ARCH, kernel $(uname -r)"
        PT_OS=linux; PT_SHA=$PT_SHA256_LINUX ;;
    *) fail "This script runs on macOS and Linux. On Windows use install.ps1 (see $SITE/install)." ;;
esac
say "bash $BASH_VERSION"

if [ "$(id -u)" = 0 ]; then
    fail "Don't run this as root or with sudo. Run it as your normal user."
fi

for t in curl unzip awk; do
    command -v "$t" > /dev/null 2>&1 || fail "$t is missing. Install it and run the script again."
done
command -v sha256sum > /dev/null 2>&1 || command -v shasum > /dev/null 2>&1 \
    || fail "Neither sha256sum nor shasum is installed."

free_kb=$(df -Pk "$BASE" | awk 'NR==2 {print $4}')
free_kb=${free_kb:-0}
say "Free space in $BASE: $((free_kb / 1024 / 1024)) GB"
if [ "$free_kb" -lt $((NEED_GB * 1024 * 1024)) ]; then
    fail "The install needs about $NEED_GB GB free in $BASE. Free some space and run the script again."
fi

vm=
if [ "$OS" = Darwin ]; then
    [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = 1 ] && vm="a virtual machine"
elif command -v systemd-detect-virt > /dev/null 2>&1; then
    v=$(systemd-detect-virt 2>/dev/null) && [ "$v" != none ] && vm="a virtual machine ($v)"
fi
if [ -n "$vm" ]; then
    say "Warning: this looks like $vm. USB pass-through often drops the phone halfway through"
    say "flashing. Use a real computer if you can."
fi

if ! curl -fsS --max-time 20 -o /dev/null "$SITE/"; then
    fail "Can't reach $SITE. Check the internet connection."
fi
say "Internet: OK"

# ---------------------------------------------------------------- 2. fastboot

step 2 "Find fastboot"

# 35.0.1 -> 350001 style number for comparing; drops a distro epoch ("1:34.0.4-debian").
vnum() { printf '%s\n' "$1" | sed 's/^[0-9]*://' | awk -F'[.-]' '{printf "%d%03d%03d\n", $1, $2, $3}'; }

FASTBOOT=
if command -v fastboot > /dev/null 2>&1; then
    have=$(fastboot --version 2>/dev/null | awk '/fastboot version/ {print $3; exit}')
    say "Installed fastboot: $(command -v fastboot), version ${have:-unknown}"
    if [ -n "$have" ] && [ "$(vnum "$have")" -ge "$(vnum $FASTBOOT_MIN)" ]; then
        FASTBOOT=$(command -v fastboot)
    else
        say "That's older than $FASTBOOT_MIN, so the script uses its own copy."
    fi
fi
if [ -z "$FASTBOOT" ]; then
    if [ "$OS" = Linux ] && [ "$ARCH" != x86_64 ]; then
        fail "Google's platform-tools are only built for x86_64 Linux. Install fastboot $FASTBOOT_MIN or newer from your distribution and run the script again."
    fi
    ptzip=$CACHE/platform-tools_r$PT_VERSION-$PT_OS.zip
    if [ ! -f "$ptzip" ] || [ "$(sha256 "$ptzip")" != "$PT_SHA" ]; then
        must curl -fL --retry 3 --progress-bar -o "$ptzip" \
            "https://dl.google.com/android/repository/platform-tools_r$PT_VERSION-$PT_OS.zip" 2>&4
    fi
    got=$(sha256 "$ptzip")
    if [ "$got" != "$PT_SHA" ]; then
        rm -f "$ptzip"
        fail "platform-tools download doesn't match its expected SHA-256 (got $got). Run the script again."
    fi
    say "platform-tools $PT_VERSION: SHA-256 OK"
    rm -rf "$CACHE/platform-tools"
    must unzip -q -o "$ptzip" -d "$CACHE"
    FASTBOOT=$CACHE/platform-tools/fastboot
fi
# Only for this script and the flash script it runs; nothing changes system-wide.
PATH=$(dirname "$FASTBOOT"):$PATH
export PATH
say "Using $FASTBOOT ($("$FASTBOOT" --version 2>/dev/null | awk '/fastboot version/ {print $3; exit}'))"

# ---------------------------------------------------------------- 3. phone

step 3 "Find the phone"

# fastboot getvar prints "name: value" on stderr.
getvar() {
    fastboot -s "$SERIAL" getvar "$1" 2>&1 | awk -v k="$1" '{sub(/^\(bootloader\) /, "")} index($0, k ": ") == 1 {print substr($0, length(k) + 3); exit}'
}

hint_shown=0
waited=0
while :; do
    list=$(fastboot devices 2>&1 | grep -v '^$')
    # A phone is a "<serial><tab>fastboot" line (fastboot 37 adds a space after the tab);
    # anything else is a message from fastboot.
    n=$(printf '%s\n' "$list" | awk -F'\t *' '$2 == "fastboot"' | grep -vc 'no permissions')
    if printf '%s\n' "$list" | grep -q 'no permissions'; then
        say "$list"
        fail "The phone is there but this user may not talk to it. Install the udev rules (Debian/Ubuntu: sudo apt install android-sdk-platform-tools-common; Arch: android-udev), unplug and reconnect the phone, and run the script again."
    fi
    [ "$n" -ge 1 ] && break
    if [ $hint_shown = 0 ]; then
        say "Waiting for a phone in fastboot mode."
        say "  Turn the phone off, then hold volume down and press power until the bootloader"
        say "  screen shows. Connect it with a USB cable that carries data (not a charge-only"
        say "  cable), straight to the computer, not through a hub."
        hint_shown=1
    fi
    if [ $waited -ge "$WAIT" ]; then
        fail "No phone in fastboot mode after $((WAIT / 60)) minutes."
    fi
    sleep 3; waited=$((waited + 3))
done
if [ "$n" -gt 1 ]; then
    say "$list"
    fail "More than one phone is connected. Leave only the one you want to install on."
fi
SERIAL=$(printf '%s\n' "$list" | awk -F'\t *' '$2 == "fastboot" {print $1; exit}')
say "Found phone $SERIAL"

if [ "$(getvar is-userspace)" = yes ]; then
    fail "The phone is in fastbootd (the recovery's fastboot), not the bootloader. Run: fastboot reboot bootloader, then run the script again."
fi
CODENAME=$(getvar product)
UNLOCKED=$(getvar unlocked)
say "Phone: $CODENAME, bootloader unlocked: ${UNLOCKED:-unknown}"
say "Bootloader $(getvar version-bootloader), radio $(getvar version-baseband), slot $(getvar current-slot)"
[ -n "$CODENAME" ] || fail "fastboot found the phone but couldn't read its codename."

# Which build to install: the newest on the stable channel, or the one in --zip.
if [ -n "$ZIP" ]; then
    [ -f "$ZIP" ] || fail "No file at $ZIP."
    zname=$(basename "$ZIP")
    case $zname in
        *-install-*.zip) ;;
        *) fail "$zname isn't an install zip (expected <codename>-install-<build>.zip)." ;;
    esac
    ZCODE=${zname%%-install-*}
    BUILD=${zname##*-install-}; BUILD=${BUILD%.zip}
    [ "$ZCODE" = "$CODENAME" ] || fail "$zname is for $ZCODE, but the phone is a $CODENAME."
else
    chan=$(curl -fsSL --max-time 30 "$RELEASES/updates/$CODENAME-stable" 2>/dev/null)
    BUILD=$(printf '%s\n' "$chan" | awk 'NR==1 {print $1}')
    if [ -z "$BUILD" ]; then
        fail "There is no os.ivan.gg build for $CODENAME yet. The list is at $SITE/devices."
    fi
fi
say "Build to install: $BUILD"

if [ "$MODE" = check ]; then
    say ""
    say "${B}Check passed.${N} The computer, fastboot and the phone are ready for build $BUILD."
    if [ "$UNLOCKED" = no ]; then
        ability=$(fastboot -s "$SERIAL" flashing get_unlock_ability 2>&1 | awk -F': ' '/get_unlock_ability/ {print $2; exit}')
        [ "$ability" = 1 ] || say "But OEM unlocking is off: turn it on in Developer options before installing."
    fi
    say "Run the script without --check to install. Log: $LOG"
    exit 0
fi

# ---------------------------------------------------------------- 4. download

step 4 "Download and check build $BUILD"
NAME=$CODENAME-install-$BUILD
if [ -z "$ZIP" ]; then
    ZIP=$CACHE/$NAME.zip
    sums=$CACHE/SHA256SUMS-$BUILD
    must curl -fsSL --retry 3 -o "$sums" "$RELEASES/$BUILD/SHA256SUMS-$BUILD"
    want=$(awk -v f="$NAME.zip" '$2 == f {print $1}' "$sums")
    [ -n "$want" ] || fail "SHA256SUMS-$BUILD doesn't list $NAME.zip."
    if [ -f "$ZIP" ] && [ "$(sha256 "$ZIP")" = "$want" ]; then
        say "Already downloaded: $ZIP"
    else
        # Older builds in the cache are no longer needed.
        rm -rf "$CACHE"/*-install-*
        say "Downloading $NAME.zip (about 2 GB)."
        if ! run curl -fL --retry 3 --progress-bar -C - -o "$ZIP.part" "$RELEASES/$BUILD/$NAME.zip" 2>&4; then
            rm -f "$ZIP.part"
            must curl -fL --retry 3 --progress-bar -o "$ZIP.part" "$RELEASES/$BUILD/$NAME.zip" 2>&4
        fi
        mv "$ZIP.part" "$ZIP"
    fi
    got=$(sha256 "$ZIP")
    say "SHA-256 $got"
    if [ "$got" != "$want" ]; then
        rm -f "$ZIP"
        fail "The download doesn't match SHA256SUMS-$BUILD. It was deleted; run the script again."
    fi
    say "Matches SHA256SUMS-$BUILD."
else
    sums=$(dirname "$ZIP")/SHA256SUMS-$BUILD
    if [ -f "$sums" ]; then
        want=$(awk -v f="$NAME.zip" '$2 == f {print $1}' "$sums")
        [ "$(sha256 "$ZIP")" = "$want" ] || fail "$ZIP doesn't match $sums."
        say "Matches $sums."
    else
        say "No SHA256SUMS-$BUILD next to the zip; relying on the key check below."
    fi
fi

# The unpacked folder is reused only if it came from this exact zip.
DIR=$CACHE/$NAME
zsum=$(sha256 "$ZIP")
if [ "$(cat "$DIR/.unpacked" 2>/dev/null)" != "$zsum" ]; then
    rm -rf "$DIR"
    say "Unpacking (about 4.5 GB)."
    must unzip -q -o "$ZIP" -d "$CACHE"
    [ -d "$DIR" ] || fail "The zip didn't contain a $NAME folder."
    echo "$zsum" > "$DIR/.unpacked"
fi
[ -f "$DIR/avb_pkmd.bin" ] || fail "The zip has no avb_pkmd.bin."
[ -f "$DIR/flash-all.sh" ] || fail "The zip has no flash-all.sh."
key=$(sha256 "$DIR/avb_pkmd.bin")
say "Key fingerprint in the zip: $(grouped "$key")"
if [ "$key" != "$FINGERPRINT" ]; then
    rm -rf "$DIR"
    fail "This zip is not signed with os.ivan.gg's key. Expected $(grouped "$FINGERPRINT"). Don't flash it."
fi
say "Matches os.ivan.gg's key."

# ---------------------------------------------------------------- 5. unlock

step 5 "Unlock the bootloader"
if [ "$UNLOCKED" = yes ]; then
    say "Already unlocked."
    say ""
    say "${B}Flashing erases everything on the phone.${N}"
    ask "Type FLASH to continue, anything else to stop:"
    [ "$REPLY" = FLASH ] || { say "Stopped. Nothing was changed on the phone."; exit 0; }
else
    ability=$(fastboot -s "$SERIAL" flashing get_unlock_ability 2>&1 | awk -F': ' '/get_unlock_ability/ {print $2; exit}')
    say "OEM unlocking allowed: ${ability:-unknown}"
    if [ "$ability" = 0 ]; then
        fail "OEM unlocking is off. Start the phone, turn it on in Settings > System > Developer options, then come back to the bootloader and run the script again."
    fi
    say "Unlocking ${B}erases everything on the phone${N}: apps, photos, accounts, all of it."
    say "The phone then asks you to confirm: use the volume keys to pick Unlock, press power."
    ask "Type UNLOCK to continue, anything else to stop:"
    [ "$REPLY" = UNLOCK ] || { say "Stopped. Nothing was changed on the phone."; exit 0; }
    must fastboot -s "$SERIAL" flashing unlock
    say "Confirm on the phone. Waiting for the bootloader to report unlocked ..."
    waited=0
    while [ "$(getvar unlocked)" != yes ]; do
        [ $waited -ge 300 ] && fail "The bootloader still isn't unlocked after 5 minutes. Was it confirmed on the phone?"
        sleep 5; waited=$((waited + 5))
    done
    say "Unlocked."
fi

# ---------------------------------------------------------------- 6. flash

step 6 "Flash build $BUILD"
say "This takes a few minutes. Don't touch the cable or the phone until it's done."
FLASHING=1
LAST_CMD="sh flash-all.sh (in $DIR)"
say "\$ $LAST_CMD"
(cd "$DIR" && sh flash-all.sh)
LAST_RC=$?
[ "$LAST_RC" = 0 ] || fail "The flash script failed."
# The flash script installs the key itself; older zips didn't.
if ! grep -q 'flash avb_custom_key' "$DIR/flash-all.sh"; then
    must fastboot -s "$SERIAL" erase avb_custom_key
    must fastboot -s "$SERIAL" flash avb_custom_key "$DIR/avb_pkmd.bin"
fi
FLASHING=0
[ "$(getvar product)" = "$CODENAME" ] || fail "The phone didn't come back to the bootloader after flashing."
say "Flashed."

# ---------------------------------------------------------------- 7. lock

step 7 "Lock the bootloader"
if [ "$LOCK" = 0 ]; then
    say "Skipped (--no-lock). The bootloader stays unlocked and the phone shows an orange warning"
    say "on every boot. To lock later, in the bootloader: fastboot flashing lock"
else
    say "Locking turns on full verified boot. The phone then only boots software signed with"
    say "this key:"
    say ""
    grouped "$FINGERPRINT" | awk '{print "    " $1 " " $2 " " $3 " " $4; print "    " $5 " " $6 " " $7 " " $8}'
    say ""
    say "Locking ${B}erases the phone again${N}. Confirm on the phone with the volume keys and power."
    ask "Type LOCK to lock, anything else to leave it unlocked:"
    if [ "$REPLY" = LOCK ]; then
        must fastboot -s "$SERIAL" flashing lock
        say "Confirm on the phone. Waiting for the bootloader to report locked ..."
        waited=0
        while [ "$(getvar unlocked)" != no ]; do
            [ $waited -ge 300 ] && fail "The bootloader still isn't locked after 5 minutes. Was it confirmed on the phone?"
            sleep 5; waited=$((waited + 5))
        done
        say "Locked."
    else
        say "Left unlocked. To lock later, in the bootloader: fastboot flashing lock"
    fi
fi

trap - INT
say ""
say "${B}Done.${N} With Start selected in the bootloader, press power."
say "A locked phone shows a yellow notice on every boot, \"Your device is loading a different"
say "operating system\", with the key's fingerprint; compare it with the one above. An orange"
say "warning means the bootloader is unlocked. Once the phone has booted and you've checked it,"
say "turn OEM unlocking off in Developer options."
say ""
say "Log: $LOG"
exit 0
