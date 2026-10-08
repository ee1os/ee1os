#!/usr/bin/env bash
# Phase W1/W2 helper: build the image, open a shell, or build the emulator target.
# Runs as faeton via sudo docker; nothing is installed on the TrueNAS host itself.
#   run.sh image     build the container image (once)
#   run.sh shell     interactive shell in the build container
#   run.sh build     lunch + m for the emulator target (log: /src/build.log)
#   run.sh emulator  start the emulator headless; adb on host 127.0.0.1:5555
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=/mnt/flash/scratch/grapheneos
IMAGE=grapheneos-build:24.04
NAME=grapheneos-build
JOBS="${JOBS:-12}"            # roadmap: cap at -j12, n5 runs other services
MEM="${MEM:-48g}"             # container memory cap; AOSP needs ~32 GB at -j12
TARGET="${TARGET:-sdk_phone64_x86_64}"
VARIANT="${VARIANT:-userdebug}"

KVM_GID="$(stat -c %g /dev/kvm)"
common=(--rm --name "$NAME" --memory "$MEM" --memory-swap "$MEM"
        -v "$SRC:/src" --device /dev/kvm --group-add "$KVM_GID"
        -e JOBS="$JOBS" -e TARGET="$TARGET" -e VARIANT="$VARIANT")

case "${1:-}" in
  image)
    sudo docker build -t "$IMAGE" "$HERE" ;;
  shell)
    sudo docker run -it "${common[@]}" "$IMAGE" bash ;;
  build)
    sudo docker run "${common[@]}" "$IMAGE" bash -c '
      set -e; source build/envsetup.sh
      lunch "$TARGET-cur-$VARIANT"
      m -j"$JOBS"' 2>&1 | tee -a "$SRC/build.log" ;;
  emulator)
    # host network: the emulator binds adb to 127.0.0.1:5555, which is then the host's
    # loopback (reach it from m3max with: ssh -L 5555:127.0.0.1:5555 n5)
    sudo docker run -d "${common[@]}" --network host "$IMAGE" bash -c '
      set -e; source build/envsetup.sh
      lunch "$TARGET-cur-$VARIANT"
      emulator -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -writable-system \
        -ports 5554,5555' ;;
  *)
    sed -n 2,7p "$0"; exit 2 ;;
esac
