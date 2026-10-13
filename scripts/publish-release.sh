#!/usr/bin/env bash
# Publish a release that release.sh built and signed with PUBLISH=0.
#   publish-release.sh <build number> [user|userdebug]
# Same upload as release.sh step 3 and 4: the OTA zip and channel file replace the rolling
# "updates" release; a user build also gets its own release with the install zip and checksums.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
DEVICE=husky
REPO=os-ivan-gg/releases
bn=${1:?build number}
VARIANT=${2:-user}
CHANNEL=$([ "$VARIANT" = user ] && echo stable || echo testing)
out=$TREE/releases/$bn/release-$DEVICE-$bn

for f in "$DEVICE-ota_update-$bn.zip" "$DEVICE-install-$bn.zip" "$DEVICE-$CHANNEL"; do
    [ -s "$out/$f" ] || { echo "missing $out/$f"; exit 1; }
done
(cd "$out" && sha256sum $DEVICE-ota_update-$bn.zip $DEVICE-install-$bn.zip > SHA256SUMS-$bn)
sums=$(cat "$out/SHA256SUMS-$bn")
echo "$sums"
# the tag the tracking script last synced to; before its first run, branch 17 after the
# newest tag in the tree
base=$(cat "$WS/state/upstream-tag" 2>/dev/null) \
    || base="17 (branch, after $(git -C "$TREE/build/make" describe --tags --abbrev=0 2>/dev/null))"

gh release view updates -R "$REPO" > /dev/null 2>&1 \
    || gh release create updates -R "$REPO" --title "Over-the-air updates" \
        --notes "Files the phone's Updater reads. Replaced on every release."
gh release upload updates -R "$REPO" --clobber \
    "$out/$DEVICE-ota_update-$bn.zip" "$out/$DEVICE-$CHANNEL"
if [ "$VARIANT" = user ]; then
    gh release create "$bn" -R "$REPO" --title "os.ivan.gg $bn" \
        --notes "Factory image for $DEVICE. Based on GrapheneOS $base.

Verified boot key fingerprint (SHA-256 of avb_pkmd.bin):
\`65894abf95040084e7f27ff8cb8e0d291b04abc266103fb88cef5e0c8c8bf161\`

SHA-256:
\`\`\`
$sums
\`\`\`" \
        "$out/$DEVICE-install-$bn.zip" "$out/SHA256SUMS-$bn"
fi

/mnt/tank/scripts/notify-telegram.sh "os.ivan.gg $bn ($VARIANT) published: https://github.com/$REPO/releases/tag/$bn" \
    > /dev/null 2>&1 || true
echo "published $bn"
