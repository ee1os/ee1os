#!/usr/bin/env bash
# Regression gate on n5, run after a phone build (scripts/track-upstream.sh, or by hand):
#   1. build the emulator target (ollama paused by emu-build.sh)
#   2. start a wiped emulator and wait for its boot (one retry with a fresh one)
#   3. run the alternate credential tests and the whole locksettings suite (atest)
#   4. on a fresh emulator, type the PINs at the real lock screen (tests/keyguard.sh)
#   5. on a fresh emulator, a removable volume across user switches (tests/usb-volume.sh)
#   6. on a fresh emulator, the Stage 1 layout (stage1.sh setup: owner PIN, envB), then the
#      reboot PIN at the owner's and envB's prompt (stage2.sh reboot, reboot-b) and envB's
#      storage before the owner unlocks (stage5.sh storage)
#   7. last, on a fresh emulator, the duress wipe (tests/duress.sh, decided 2026-11-10); the
#      emulator is left off and wiped
#   8. stop the emulator; exit non-zero if anything failed
# Each script that sets its own PINs gets a wiped emulator of its own.
# Logs: /mnt/flash/scratch/grapheneos/gate-<name>.log, for auth, lss (atest), keyguard,
# usb-volume, stage1, stage2, stage5 and duress; one summary line each.
set -uo pipefail
WS=/mnt/flash/scratch/grapheneos
RUN=/mnt/flash/home/faeton/work/ee1os/os/workspace/build-env/run.sh
label="emu build for the gate, $(date +%F_%H%M)"
NAMES=(auth lss keyguard usb-volume stage1 stage2 stage5 duress)

cd "$WS" || exit 1
./emu-build.sh "$label" droid > /dev/null 2>&1
sed -n "/=== $label/,\$p" build.log | grep -q 'BUILD_EXIT=0' || { echo "gate: emulator build failed"; exit 1; }

# building the test module needs the build's memory limits, and ollama paused like a build
sudo docker stop ollama > /dev/null && echo "$(date +%T) ollama stopped for the gate" >> mem.log
trap 'timeout 120 sudo docker stop grapheneos-emu > /dev/null 2>&1
      sudo docker start ollama > /dev/null && echo "$(date +%T) ollama restarted after the gate" >> mem.log' EXIT
# results of an earlier run must not count for this one
for n in "${NAMES[@]}"; do
    rm -f "$WS/gate-$n.log"
    [ ! -e "$WS/gate-$n.log" ] || { echo "gate: old result logs can't be removed"; exit 1; }
done

# a wiped emulator, booted to the end; it sometimes hangs at boot (graphics pipe), so a
# second try with a fresh one before giving up
boot() {
    sudo docker stop grapheneos-emu > /dev/null 2>&1 || true
    EMU_ARGS=-wipe-data "$RUN" emulator > /dev/null || return 1
    # the test scripts connect to 127.0.0.1:5555; the adb server on n5 outlives them and would
    # list the new emulator twice, and adb without a serial then answers nothing
    "$RUN" exec 'adb disconnect > /dev/null 2>&1
      for i in $(seq 150); do
        [ "$(timeout 10 adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = 1 ] && exit 0
        sleep 5
      done
      exit 1' > /dev/null 2>&1
}
# t <name> <seconds> <command>: one test script in the container, its result in gate-<name>.log;
# the first non-zero exit of a name is kept
declare -A RC
t() {
    local rc
    "$RUN" exec "RES=/src/gate-$1.log timeout -k 30 $2 $3" > /dev/null 2>&1
    rc=$?
    [ "${RC[$1]:-0}" != 0 ] || RC[$1]=$rc
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
if boot || boot; then t keyguard 1500 /src/ee1os/tests/keyguard.sh; fi
# so does the removable volume run
if boot || boot; then t usb-volume 1500 /src/ee1os/tests/usb-volume.sh; fi
# the Stage 1 layout, shared by the reboot PIN and storage runs (they need its PINs and envB)
if boot || boot; then
    t stage1 300 '/src/ee1os/tests/stage1.sh setup'
    if grep -qx 'result: PASS' "$WS/gate-stage1.log" 2>/dev/null; then
        t stage2 600 '/src/ee1os/tests/stage2.sh reboot'
        t stage2 600 '/src/ee1os/tests/stage2.sh reboot-b'
        t stage5 900 '/src/ee1os/tests/stage5.sh storage'
    fi
fi
# last: the duress PIN wipes the emulator, which then powers off; it stays off and wiped (the
# next boot wipes anyway)
if boot || boot; then t duress 600 '/src/ee1os/tests/duress.sh --yes-wipe'; fi
timeout 120 sudo docker stop grapheneos-emu > /dev/null 2>&1

rc=0
for n in keyguard usb-volume stage1 stage2 stage5 duress; do
    want=1; [ "$n" = stage2 ] && want=2   # reboot and reboot-b
    r=$(grep -a '^result:' "$WS/gate-$n.log" 2>/dev/null)
    got=$(grep -c . <<< "$r") ok=$(grep -cx 'result: PASS' <<< "$r")
    echo "gate: gate-$n.log $(echo ${r:-no result}) (exit ${RC[$n]:-not run})"
    [ "$got" = "$want" ] && [ "$ok" = "$want" ] && [ "${RC[$n]:-1}" = 0 ] || rc=1
done
for f in gate-auth.log gate-lss.log; do
    # atest's summary: "x86_64 FrameworksServicesTests: Passed: 829, Failed: 1, Ignored: 17, ..."
    s=$(sed 's/\x1b\[[0-9;]*m//g' "$WS/$f" | grep -aoE "Passed: [0-9]+, Failed: [0-9]+[^(]*" | tail -1)
    echo "gate: $f ${s:-no summary}"
    [[ $s =~ Passed:\ [1-9] ]] || rc=1
    [[ $s =~ Failed:\ 0, ]] || rc=1
done
exit $rc
