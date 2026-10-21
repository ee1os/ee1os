#!/usr/bin/env bash
# Regression gate on n5, run after a phone build (scripts/track-upstream.sh, or by hand):
#   1. build the emulator target (ollama paused by emu-build.sh)
#   2. start a wiped emulator and wait for its boot (one retry with a fresh one)
#   3. run the alternate credential tests and the whole locksettings suite (atest)
#   4. on a fresh emulator, type the PINs at the real lock screen (tests/keyguard.sh)
#   5. stop the emulator; exit non-zero if anything failed
# Logs: /mnt/flash/scratch/grapheneos/gate-auth.log, gate-lss.log, gate-keyguard.log
set -uo pipefail
WS=/mnt/flash/scratch/grapheneos
RUN=/mnt/flash/home/faeton/work/os-ivan-gg/workspace/build-env/run.sh
label="emu build for the gate, $(date +%F_%H%M)"

cd "$WS" || exit 1
./emu-build.sh "$label" droid > /dev/null 2>&1
sed -n "/=== $label/,\$p" build.log | grep -q 'BUILD_EXIT=0' || { echo "gate: emulator build failed"; exit 1; }

# building the test module needs the build's memory limits, and ollama paused like a build
sudo docker stop ollama > /dev/null && echo "$(date +%T) ollama stopped for the gate" >> mem.log
trap 'timeout 120 sudo docker stop grapheneos-emu > /dev/null 2>&1
      sudo docker start ollama > /dev/null && echo "$(date +%T) ollama restarted after the gate" >> mem.log' EXIT
# results of an earlier run must not count for this one
rm -f "$WS/gate-auth.log" "$WS/gate-lss.log" "$WS/gate-keyguard.log"
[ ! -e "$WS/gate-auth.log" ] && [ ! -e "$WS/gate-lss.log" ] && [ ! -e "$WS/gate-keyguard.log" ] \
    || { echo "gate: old result logs can't be removed"; exit 1; }

# a wiped emulator, booted to the end; it sometimes hangs at boot (graphics pipe), so a
# second try with a fresh one before giving up
boot() {
    sudo docker stop grapheneos-emu > /dev/null 2>&1 || true
    EMU_ARGS=-wipe-data "$RUN" emulator > /dev/null || return 1
    "$RUN" exec 'for i in $(seq 150); do
        [ "$(timeout 10 adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && exit 0
        sleep 5
      done
      exit 1' > /dev/null 2>&1
}
boot || { echo "gate: emulator didn't boot, trying a fresh one"; boot; } \
    || { echo "gate: emulator didn't boot"; exit 1; }

JOBS=12 HIGHMEM=2 MEM=44g MEMSWAP=68g "$RUN" exec '
  timeout 60 adb shell wm dismiss-keyguard; timeout 60 adb shell input keyevent 82
  timeout -k 60 3600 atest FrameworksServicesTests:com.android.server.locksettings.AlternateCredentialsTests \
      > /src/gate-auth.log 2>&1
  timeout -k 60 5400 atest FrameworksServicesTests:com.android.server.locksettings > /src/gate-lss.log 2>&1
'

# the lock screen run sets its own PINs, so it gets a wiped emulator of its own
krc=1
if boot || boot; then
    "$RUN" exec 'RES=/src/gate-keyguard.log timeout -k 30 900 /src/os-ivan-gg/tests/keyguard.sh' \
        > /dev/null 2>&1
    krc=$?
fi

rc=0
k=$(grep -a '^result:' "$WS/gate-keyguard.log" 2>/dev/null | tail -1)
echo "gate: gate-keyguard.log ${k:-no result} (exit $krc)"
[ "$k" = "result: PASS" ] && [ $krc = 0 ] || rc=1
for f in gate-auth.log gate-lss.log; do
    # atest's summary: "x86_64 FrameworksServicesTests: Passed: 829, Failed: 1, Ignored: 17, ..."
    s=$(sed 's/\x1b\[[0-9;]*m//g' "$WS/$f" | grep -aoE "Passed: [0-9]+, Failed: [0-9]+[^(]*" | tail -1)
    echo "gate: $f ${s:-no summary}"
    [[ $s =~ Passed:\ [1-9] ]] || rc=1
    [[ $s =~ Failed:\ 0, ]] || rc=1
done
exit $rc
