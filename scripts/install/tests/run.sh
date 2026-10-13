#!/usr/bin/env bash
# Tests for install.sh: a fake fastboot plays each phone state against a local stand-in for
# the releases and the report endpoint. No phone or internet needed.
#   scripts/install/tests/run.sh          (SCRIPT_BASH=/path/to/bash picks the bash under test)
# The temp folder must allow running programs (on a noexec /tmp, set TMPDIR).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../install.sh
T=$(mktemp -d)
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null; rm -rf "$T"' EXIT

BN=2099010100
PORT=$((20000 + RANDOM % 20000))
WEB=$T/web

# A tiny install zip: the real public key file and a flash script that calls fastboot.
make_zip() {  # make_zip <out.zip> <key file>
    local name=husky-install-$BN src=$T/zipsrc
    rm -rf "$src"; mkdir -p "$src/$name"
    cp "$2" "$src/$name/avb_pkmd.bin"
    cat > "$src/$name/flash-all.sh" <<'EOF'
#!/bin/sh
set -e
fastboot erase avb_custom_key
fastboot flash avb_custom_key avb_pkmd.bin
fastboot flash boot boot.img
fastboot flash super super_1.img
EOF
    python3 - "$1" "$src" "$name" <<'EOF'
import os, sys, zipfile
out, src, name = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(os.path.join(src, name))):
        z.write(os.path.join(src, name, f), name + "/" + f)
EOF
}

mkdir -p "$WEB/releases/updates" "$WEB/releases/$BN" "$T/bin"
make_zip "$WEB/releases/$BN/husky-install-$BN.zip" "$HERE/fixtures/avb_pkmd.bin"
(cd "$WEB/releases/$BN" && sha256sum "husky-install-$BN.zip" > "SHA256SUMS-$BN")
echo "$BN 4070908800 husky stable" > "$WEB/releases/updates/husky-stable"
head -c 1032 /dev/urandom > "$T/otherkey.bin"
mkdir -p "$T/bad" && make_zip "$T/bad/husky-install-$BN.zip" "$T/otherkey.bin"
echo ok > "$WEB/index.html"
cp "$HERE/fastboot" "$T/bin/fastboot"; chmod +x "$T/bin/fastboot"
FAKE_DIR=$T "$T/bin/fastboot" --version > /dev/null 2>&1 || { echo "Can't run programs in $T (noexec?). Set TMPDIR."; exit 1; }

python3 "$HERE/server.py" "$WEB" "$PORT" & SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fs "http://127.0.0.1:$PORT/" > /dev/null && break; sleep 0.3; done

pass=0; failed=0
OUT=

# case <name> <expected exit> <answers> [VAR=value ...] -- [script args]
case_() {
    local name=$1 want=$2 answers=$3; shift 3
    # One home for all cases, so the download cache carries over like on a real computer.
    local fake=$T/fake-$pass-$failed home=$T/home
    rm -rf "$fake"; mkdir -p "$fake" "$home"
    printf '%b' "$answers" > "$T/answers"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        printf '%s\n' "${1#*=}" > "$fake/${1%%=*}"; shift
    done
    [ $# -gt 0 ] && shift
    rm -f "$WEB/report.txt"
    OUT=$(HOME=$home FAKE_DIR=$fake PATH="$T/bin:$PATH" \
        OSIVANGG_SITE=http://127.0.0.1:$PORT OSIVANGG_RELEASES=http://127.0.0.1:$PORT/releases \
        OSIVANGG_HOME=$home/os-ivan-gg-install OSIVANGG_NEED_GB=0 OSIVANGG_WAIT=0 \
        OSIVANGG_TTY=$T/answers "${SCRIPT_BASH:-bash}" "$SCRIPT" "$@" 2>&1)
    local rc=$?
    CALLS=$(cat "$fake/calls" 2>/dev/null)
    STATE=$(cat "$fake/unlocked" 2>/dev/null)
    if [ "$rc" = "$want" ]; then CUR_OK=1; else CUR_OK=0; fi
    CUR=$name; CUR_RC=$rc
}
expect() {  # expect <grep pattern> <in: OUT|CALLS> [!]
    local hay
    if [ "$2" = CALLS ]; then hay=$CALLS; else hay=$OUT; fi
    if [ "${3:-}" = '!' ]; then
        printf '%s\n' "$hay" | grep -q -- "$1" && { CUR_OK=0; echo "   unexpected: $1"; }
    else
        printf '%s\n' "$hay" | grep -q -- "$1" || { CUR_OK=0; echo "   missing: $1"; }
    fi
}
done_() {
    if [ "$CUR_OK" = 1 ]; then pass=$((pass + 1)); echo "ok   $CUR"
    else failed=$((failed + 1)); echo "FAIL $CUR (exit $CUR_RC)"; printf '%s\n' "$OUT" | tail -25 | sed 's/^/   | /'; fi
}

case_ "check mode changes nothing" 0 "" unlocked=no -- --check
expect "Check passed" OUT; expect "flashing [un]*lock" CALLS '!'; expect "flash " CALLS '!'; done_

case_ "check mode warns when OEM unlocking is off" 0 "" unlocked=no ability=0 -- --check
expect "OEM unlocking is off" OUT; done_

case_ "no phone" 1 "" devices=0
expect "No phone in fastboot mode" OUT; expect "Install stopped in step 3" OUT; done_

case_ "two phones" 1 "" devices=2
expect "More than one phone" OUT; done_

case_ "no udev permissions" 1 "" perm=1
expect "udev rules" OUT; done_

case_ "codename without a build" 1 "" product=sunfish
expect "no os.ivan.gg build for sunfish" OUT; done_

case_ "locked phone: unlock, flash, lock" 0 "UNLOCK\nLOCK\n" unlocked=no
expect "flashing unlock" CALLS; expect "flash avb_custom_key" CALLS; expect "flashing lock" CALLS
expect "Matches os.ivan.gg's key" OUT; expect "65894abf 95040084 e7f27ff8 cb8e0d29" OUT; expect "Done." OUT
[ "$STATE" = no ] || { CUR_OK=0; echo "   phone not locked at the end"; }; done_

case_ "second run reuses the download" 0 "UNLOCK\nLOCK\n" unlocked=no
expect "Already downloaded" OUT; expect "Unpacking" OUT '!'; done_

case_ "unlocked phone, --no-lock" 0 "FLASH\n" unlocked=yes -- --no-lock
expect "flash super" CALLS; expect "flashing lock" CALLS '!'; expect "Skipped (--no-lock)" OUT; done_

case_ "anything but UNLOCK stops before touching the phone" 0 "unlock\n" unlocked=no
expect "flashing unlock" CALLS '!'; expect "flash " CALLS '!'; expect "Nothing was changed" OUT; done_

case_ "OEM unlocking off stops" 1 "" unlocked=no ability=0
expect "OEM unlocking is off" OUT; expect "flashing unlock" CALLS '!'; done_

case_ "flash failure: no lock, report sent without serial or home" 1 "FLASH\ny\n" unlocked=yes fail=super
expect "Install stopped in step 6" OUT; expect "partly flashed" OUT; expect "flashing lock" CALLS '!'
expect "Report ID: R-TEST" OUT
if [ -f "$WEB/report.txt" ]; then
    grep -q 3A1B2C3D4E00 "$WEB/report.txt" && { CUR_OK=0; echo "   serial left in the report"; }
    grep -q "$T/home" "$WEB/report.txt" && { CUR_OK=0; echo "   home path left in the report"; }
    grep -q 'serial-' "$WEB/report.txt" || { CUR_OK=0; echo "   serial not replaced by a hash"; }
else CUR_OK=0; echo "   no report received"; fi
done_

case_ "flash failure, report declined" 1 "FLASH\nn\n" unlocked=yes fail=super
expect "Not sent." OUT; [ -f "$WEB/report.txt" ] && { CUR_OK=0; echo "   report sent anyway"; }; done_

case_ "zip signed with another key is refused" 1 "FLASH\n" unlocked=yes -- --zip "$T/bad/husky-install-$BN.zip"
expect "not signed with os.ivan.gg's key" OUT; expect "flash " CALLS '!'; done_

case_ "zip for another phone is refused" 1 "" unlocked=yes product=shiba -- --zip "$WEB/releases/$BN/husky-install-$BN.zip"
expect "but the phone is a shiba" OUT; done_

cp "$WEB/releases/$BN/SHA256SUMS-$BN" "$T/sums.bak"
echo "0000000000000000000000000000000000000000000000000000000000000000  husky-install-$BN.zip" > "$WEB/releases/$BN/SHA256SUMS-$BN"
case_ "checksum mismatch is refused" 1 "" unlocked=yes
expect "doesn't match SHA256SUMS" OUT; expect "flash " CALLS '!'; done_
cp "$T/sums.bak" "$WEB/releases/$BN/SHA256SUMS-$BN"

echo
echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
