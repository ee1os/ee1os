#!/usr/bin/env bash
# Build container for the GrapheneOS 17 tree on n5. See docs/08-development-and-testing.md.
#   run.sh image              build the container image (once, or after Dockerfile changes)
#   run.sh shell              interactive shell, lunch already done
#   run.sh build [targets]    m -j$JOBS [targets]          (log: /src/build.log)
#   run.sh emulator           start the emulator headless; adb at 127.0.0.1:5555 on n5
#   run.sh emulator-stop      stop it
#   run.sh exec <cmd...>      run a command with lunch done (adb, atest, tests/*.sh; NAME= names it)
#   run.sh exec-it <cmd...>   the same with a terminal (prompts, e.g. the signing passphrase)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=/mnt/flash/scratch/grapheneos
ENVS=/mnt/flash/home/faeton/work/ee1os/os   # ee1os symlinks here
IMAGE=grapheneos-build:24.04
JOBS="${JOBS:-8}"
MEM="${MEM:-28g}"
MEMSWAP="${MEMSWAP:-$MEM}"   # RAM + swap; e.g. 52g with the n5 zram swap on
# soong sizes its highmem pool (metalava, R8, ...) from host RAM, not the container cap
HIGHMEM="${HIGHMEM:-1}"
LUNCH="${LUNCH:-sdk_phone64_x86_64-cur-userdebug}"
# goldfish super is 2800 MiB (?= in sdk_phone64_x86_64.mk); GrapheneOS 17 images need ~2850
SUPER="${SUPER:-$((3584 * 1048576))}"
EMU_ARGS="${EMU_ARGS:-}"      # e.g. EMU_ARGS=-wipe-data after a duress test

KVM_GID="$(stat -c %g /dev/kvm)"
common=(--rm --memory "$MEM" --memory-swap "$MEMSWAP" --network host
        -v "$SRC:/src" -v "$ENVS:$ENVS"
        --device /dev/kvm --group-add "$KVM_GID"
        -e JOBS="$JOBS" -e NINJA_HIGHMEM_NUM_JOBS="$HIGHMEM" -e LUNCH="$LUNCH" -e BOARD_EMULATOR_DYNAMIC_PARTITIONS_SIZE="$SUPER" -e EMU_ARGS="$EMU_ARGS")
# the signing keys and their passphrase only for signing (KEYS=1, release.sh step 2): code built
# from the tree never sees them; an empty root-only tmpfs over both
if [ "${KEYS:-0}" != 1 ]; then
  for d in "$SRC/grapheneos-17/keys" "$SRC/.secrets"; do
    if [ -d "$d" ]; then common+=(--mount "type=tmpfs,destination=/src/${d#$SRC/},tmpfs-mode=0700"); fi
  done
fi
# envsetup keeps the previous build number unless these are set (phone builds set both)
[ -n "${BUILD_NUMBER:-}" ] && common+=(-e BUILD_NUMBER="$BUILD_NUMBER")
[ -n "${BUILD_DATETIME:-}" ] && common+=(-e BUILD_DATETIME="$BUILD_DATETIME")
# separate output trees per target skip soong's re-analysis when switching (e.g. out_husky)
[ -n "${OUT_DIR:-}" ] && common+=(-e OUT_DIR="$OUT_DIR")
[ -n "${OFFICIAL_BUILD:-}" ] && common+=(-e OFFICIAL_BUILD="$OFFICIAL_BUILD")
setup='source build/envsetup.sh >/dev/null && lunch "$LUNCH" >/dev/null'

run() { sudo docker run "${common[@]}" "$@"; }

# one block, read whole before it runs, so editing this file mid-build is safe
{
case "${1:-}" in
  image)
    sudo docker build -t "$IMAGE" "$HERE" ;;
  shell)
    run -it "$IMAGE" bash -c "$setup; exec bash" ;;
  build)
    shift
    run --name grapheneos-build "$IMAGE" bash -c "$setup; m -j\$JOBS $*; rc=\$?; echo M_EXIT=\$rc; exit \$rc" 2>&1 \
      | tee -a "$SRC/build.log" ;;
  emulator)
    # host network: the emulator binds adb to 127.0.0.1:5555 on n5 itself;
    # from m3max: ssh -L 5555:127.0.0.1:5555 n5, then adb connect 127.0.0.1:5555
    # an emulator killed with its container leaves locks that refuse the next start
    if ! sudo docker ps --format '{{.Names}}' | grep -qx grapheneos-emu; then
      rm -f "$SRC"/grapheneos-17/out/target/product/emu64x/*.lock
    fi
    run -d --name grapheneos-emu "$IMAGE" bash -c "$setup; exec emulator -no-window \
      -no-audio -no-boot-anim -gpu swiftshader_indirect -writable-system \
      -ports 5554,5555 \$EMU_ARGS" ;;
  emulator-stop)
    sudo docker stop grapheneos-emu ;;
  exec)
    shift
    # NAME=grapheneos-build makes it count as a build (guard.sh, the tracker's busy check)
    run ${NAME:+--name "$NAME"} "$IMAGE" bash -c "$setup; $*" ;;
  exec-it)
    shift
    run -it "$IMAGE" bash -c "$setup; $*" ;;
  *)
    sed -n 2,9p "$0"; exit 2 ;;
esac
exit
}
