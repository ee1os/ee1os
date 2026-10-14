#!/usr/bin/env bash
# Build, sign and publish a release of os.ivan.gg for one model (DEVICE=<codename>, default husky).
# Signing reads the key passphrase from /mnt/flash/scratch/grapheneos/.secrets/key-passphrase, or asks for it in a terminal.
# All models share the husky keys (doc 08 Stage 6); keys/<codename> is a copy of keys/husky.
#   [DEVICE=shiba] release.sh [variant]     user (default; testers) or userdebug (the test phone's dev channel)
# Steps:
#   1. build target files and OTA tools with a fresh build number
#   2. finalize + generate-release (signing; prompts)  -> releases/<bn>/release-<codename>-<bn>/
#   3. upload: the OTA zip and channel metadata replace the rolling "updates" release; the
#      install zip gets a release of its own (github.com/os-ivan-gg/releases)
#   4. notify klava hq
# PUBLISH=0 stops after step 2.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
RUN=$ENVS/workspace/build-env/run.sh
DEVICE=${DEVICE:-husky}
VARIANT=${1:-user}
REPO=os-ivan-gg/releases
CHANNEL=$([ "$VARIANT" = user ] && echo stable || echo testing)
PWFILE=$WS/.secrets/key-passphrase

[ -d "$TREE/keys/$DEVICE" ] || { echo "no keys in $TREE/keys/$DEVICE; copy them: cp -a $TREE/keys/husky $TREE/keys/$DEVICE"; exit 1; }
if sudo docker ps --format '{{.Names}}' | grep -qx grapheneos-build; then
    echo "a build is running"; exit 1
fi

bn=$(date -u +%Y%m%d%H)
# OFFICIAL_BUILD adds the Updater (build/make/target/product/media_system.mk:39-41)
export OFFICIAL_BUILD=true LUNCH=$DEVICE-cur-$VARIANT OUT_DIR=out_release BUILD_NUMBER=$bn BUILD_DATETIME=$(date +%s)
label="release $bn $DEVICE $VARIANT"
echo "== release $bn $DEVICE ($VARIANT, channel $CHANNEL)"

# 1. build (ollama paused by emu-build.sh)
cd "$WS"
./emu-build.sh "$label" target-files-package otatools-package
# the first BUILD_EXIT after this run's header (no grep -q in a pipe: pipefail and SIGPIPE)
rc=$(awk -v m="=== $label " 'index($0, m) == 1 { f = 1; r = "" } f && r == "" && /^BUILD_EXIT=/ { r = $0 } END { print r }' build.log)
[ "$rc" = BUILD_EXIT=0 ] || { echo "build failed ($rc)"; exit 1; }

# 2. finalize and sign. The key passphrase comes from $PWFILE when it exists (owner-only file
#    on flash/scratch, kept out of the backups that hold the encrypted keys), else it is asked.
sign="cd /src/grapheneos-17 && script/finalize.sh && script/generate-release.sh $DEVICE $bn"
if [ -s "$PWFILE" ]; then
    # the passphrase is read inside the container, never put on a command line
    "$RUN" exec "password=\$(cat /src/${PWFILE#$WS/}); export password; $sign"
else
    "$RUN" exec-it "$sign"
fi
out=$TREE/releases/$bn/release-$DEVICE-$bn
ls -la "$out"/$DEVICE-ota_update-$bn.zip "$out"/$DEVICE-install-$bn.zip
[ "${PUBLISH:-1}" = 1 ] || exit 0

# 3. and 4. upload and notify
DEVICE=$DEVICE "$ENVS/scripts/publish-release.sh" "$bn" "$VARIANT"
