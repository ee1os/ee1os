#!/usr/bin/env bash
# Build container for the GrapheneOS 17 tree on n5. See docs/08-development-and-testing.md.
#   run.sh image              build the container image (once, or after Dockerfile changes)
#   run.sh shell              interactive shell, lunch already done
#   run.sh build [targets]    m -j$JOBS [targets]          (log: /src/build.log)
#   run.sh emulator           start the emulator headless; adb at 127.0.0.1:5555 on n5
#   run.sh emulator-stop      stop it
#   run.sh exec <cmd...>      run a command with lunch done (adb, atest, tests/*.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=/mnt/flash/scratch/grapheneos
ENVS=/mnt/flash/home/faeton/work/grapheneos-envs   # grapheneos-envs symlinks here
IMAGE=grapheneos-build:24.04
JOBS="${JOBS:-8}"
MEM="${MEM:-28g}"
# soong sizes its highmem pool (metalava, R8, ...) from host RAM, not the container cap
HIGHMEM="${HIGHMEM:-1}"
LUNCH="${LUNCH:-sdk_phone64_x86_64-cur-userdebug}"
EMU_ARGS="${EMU_ARGS:-}"      # e.g. EMU_ARGS=-wipe-data after a duress test

KVM_GID="$(stat -c %g /dev/kvm)"
common=(--rm --memory "$MEM" --memory-swap "$MEM" --network host
        -v "$SRC:/src" -v "$ENVS:$ENVS"
        --device /dev/kvm --group-add "$KVM_GID"
        -e JOBS="$JOBS" -e NINJA_HIGHMEM_NUM_JOBS="$HIGHMEM" -e LUNCH="$LUNCH" -e EMU_ARGS="$EMU_ARGS")
setup='source build/envsetup.sh >/dev/null && lunch "$LUNCH" >/dev/null'

run() { sudo docker run "${common[@]}" "$@"; }

case "${1:-}" in
  image)
    sudo docker build -t "$IMAGE" "$HERE" ;;
  shell)
    run -it "$IMAGE" bash -c "$setup; exec bash" ;;
  build)
    shift
    run --name grapheneos-build "$IMAGE" bash -c "$setup; m -j\$JOBS $*" 2>&1 \
      | tee -a "$SRC/build.log" ;;
  emulator)
    # host network: the emulator binds adb to 127.0.0.1:5555 on n5 itself;
    # from m3max: ssh -L 5555:127.0.0.1:5555 n5, then adb connect 127.0.0.1:5555
    run -d --name grapheneos-emu "$IMAGE" bash -c "$setup; exec emulator -no-window \
      -no-audio -no-boot-anim -gpu swiftshader_indirect -writable-system \
      -ports 5554,5555 \$EMU_ARGS" ;;
  emulator-stop)
    sudo docker stop grapheneos-emu ;;
  exec)
    shift
    run "$IMAGE" bash -c "$setup; $*" ;;
  *)
    sed -n 2,8p "$0"; exit 2 ;;
esac
