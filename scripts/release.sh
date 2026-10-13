#!/usr/bin/env bash
# Build, sign and publish a release of os.ivan.gg for husky. Run by the owner in a terminal:
# signing asks for the key passphrase. Keys live in grapheneos-17/keys/husky (encrypted;
# created once with script/generate-keys, doc 08 Stage 6).
#   release.sh [variant]     user (default; testers) or userdebug (the test phone's dev channel)
# Steps:
#   1. build target files and OTA tools with a fresh build number
#   2. finalize + generate-release (signing; prompts)  -> releases/<bn>/release-husky-<bn>/
#   3. upload: the OTA zip and channel metadata replace the rolling "updates" release; the
#      install zip gets a release of its own (github.com/os-ivan-gg/releases)
#   4. notify klava hq
# PUBLISH=0 stops after step 2.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
RUN=$ENVS/workspace/build-env/run.sh
DEVICE=husky
VARIANT=${1:-user}
REPO=os-ivan-gg/releases
CHANNEL=$([ "$VARIANT" = user ] && echo stable || echo testing)

[ -d "$TREE/keys/$DEVICE" ] || { echo "no keys in $TREE/keys/$DEVICE (script/generate-keys first)"; exit 1; }
if sudo docker ps --format '{{.Names}}' | grep -qx grapheneos-build; then
    echo "a build is running"; exit 1
fi

bn=$(date -u +%Y%m%d%H)
export LUNCH=$DEVICE-cur-$VARIANT OUT_DIR=out_release BUILD_NUMBER=$bn BUILD_DATETIME=$(date +%s)
echo "== release $bn ($VARIANT, channel $CHANNEL)"

# 1. build (ollama paused by emu-build.sh)
cd "$WS"
./emu-build.sh "release $bn $VARIANT" target-files-package otatools-package
sed -n "/=== release $bn $VARIANT/,\$p" build.log | grep -q 'BUILD_EXIT=0' || { echo "build failed"; exit 1; }

# 2. finalize and sign (interactive: key passphrase)
"$RUN" exec-it bash -c "cd /src/grapheneos-17 && script/finalize.sh && script/generate-release.sh $DEVICE $bn"
out=$TREE/releases/$bn/release-$DEVICE-$bn
ls -la "$out"/$DEVICE-ota_update-$bn.zip "$out"/$DEVICE-install-$bn.zip
[ "${PUBLISH:-1}" = 1 ] || exit 0

# 3. upload
gh release view updates -R "$REPO" > /dev/null 2>&1 \
    || gh release create updates -R "$REPO" --title "Over-the-air updates" \
        --notes "Files the phone's Updater reads. Replaced on every release."
gh release upload updates -R "$REPO" --clobber \
    "$out/$DEVICE-ota_update-$bn.zip" "$out/$DEVICE-$CHANNEL"
if [ "$VARIANT" = user ]; then
    gh release create "$bn" -R "$REPO" --title "os.ivan.gg $bn" \
        --notes "Factory image for $DEVICE. Based on GrapheneOS $(cat "$WS/state/upstream-tag" 2>/dev/null || echo '?')." \
        "$out/$DEVICE-install-$bn.zip" $(ls "$out/$DEVICE-install-$bn.zip.sig" 2>/dev/null)
fi

# 4. notify
/mnt/tank/scripts/notify-telegram.sh "os.ivan.gg: release $bn ($VARIANT) published on the $CHANNEL channel." || true
