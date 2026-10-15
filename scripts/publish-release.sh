#!/usr/bin/env bash
# Publish a release that release.sh built and signed with PUBLISH=0.
#   [DEVICE=shiba] [NOTE=text] publish-release.sh <build number> [user|userdebug]
# NOTE, when set, goes under the model's heading in the release notes (e.g. that a model hasn't been tried on a phone yet).
# Same upload as release.sh step 3 and 4: the OTA zip and channel file replace the rolling
# "updates" release; a user build also gets its own release with the install zip and checksums.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
DEVICE=${DEVICE:-husky}
REPO=os-ivan-gg/releases
bn=${1:?build number}
VARIANT=${2:-user}
CHANNEL=$([ "$VARIANT" = user ] && echo stable || echo testing)
out=$TREE/releases/$bn/release-$DEVICE-$bn

for f in "$DEVICE-ota_update-$bn.zip" "$DEVICE-install-$bn.zip" "$DEVICE-$CHANNEL"; do
    [ -s "$out/$f" ] || { echo "missing $out/$f"; exit 1; }
done
# a phone without the Updater can't take the next release over the air (T9 U1). unzip
# itself checks for the file: a pipe into grep -q fails under pipefail when unzip gets SIGPIPE
unzip -qql "$out/$DEVICE-target_files.zip" SYSTEM/priv-app/Updater/Updater.apk > /dev/null \
    || { echo "no Updater in $DEVICE-target_files.zip (OFFICIAL_BUILD unset?), not published"; exit 1; }
# GitHub refuses files over 2 GiB. An install zip over that goes up in parts (.zip.part1, ...),
# listed in order in SHA256SUMS before the whole zip; the install scripts join them. The OTA
# zip can't be split: the Updater reads it in one piece.
[ "$(stat -c %s "$out/$DEVICE-ota_update-$bn.zip")" -lt 2147483648 ] \
    || { echo "$DEVICE-ota_update-$bn.zip is over 2 GiB, GitHub won't take it; not published"; exit 1; }
inst=$DEVICE-install-$bn.zip
rm -f "$out/$inst".part[0-9]
uploads=("$inst")
if [ "$(stat -c %s "$out/$inst")" -gt 2000000000 ]; then
    (cd "$out" && split -b 1900M --numeric-suffixes=1 -a 1 "$inst" "$inst.part")
    uploads=()
    for f in "$out/$inst".part[0-9]; do uploads+=("$(basename "$f")"); done
fi
(cd "$out" && sha256sum $DEVICE-ota_update-$bn.zip \
    $([ "${uploads[0]}" = "$inst" ] || echo "${uploads[@]}") "$inst" > SHA256SUMS-$bn)
sums=$(cat "$out/SHA256SUMS-$bn")
echo "$sums"
# the tag the tracking script last synced to; before its first run, branch 17 after the
# newest tag in the tree
base=$(cat "$WS/state/upstream-tag" 2>/dev/null) \
    || base="17 (branch, after $(git -C "$TREE/build/make" describe --tags --abbrev=0 2>/dev/null))"
# what the build was made from: the manifest and each fork's commit
src="manifest $(git -C "$TREE/.repo/manifests" rev-parse --short=12 HEAD)"
for p in build/make frameworks/base packages/apps/Settings packages/apps/SetupWizard2 packages/apps/Updater \
         system/sepolicy; do
    src+=$'\n'"$p $(git -C "$TREE/$p" rev-parse --short=12 HEAD)"
done

gh release view updates -R "$REPO" > /dev/null 2>&1 \
    || gh release create updates -R "$REPO" --title "Over-the-air updates" \
        --notes "Files the phone's Updater reads. Replaced on every release."
gh release upload updates -R "$REPO" --clobber \
    "$out/$DEVICE-ota_update-$bn.zip" "$out/$DEVICE-$CHANNEL"
# One release per build number holds every model built with it: the install script fetches
# <codename>-install-<bn>.zip and one SHA256SUMS-<bn> from the release tagged <bn>.
section="## $DEVICE
${NOTE:+
$NOTE
}
\`\`\`
$sums
\`\`\`"
if [ "$VARIANT" = user ] && gh release view "$bn" -R "$REPO" > /dev/null 2>&1; then
    tmp=$(mktemp -d)
    gh release download "$bn" -R "$REPO" -p "SHA256SUMS-$bn" -D "$tmp"
    { grep -v " $DEVICE-" "$tmp/SHA256SUMS-$bn" || true; echo "$sums"; } > "$out/SHA256SUMS-$bn"
    body=$(gh release view "$bn" -R "$REPO" --json body -q .body)
    gh release upload "$bn" -R "$REPO" --clobber "${uploads[@]/#/$out/}" "$out/SHA256SUMS-$bn"
    gh release edit "$bn" -R "$REPO" --notes "$body

$section"
    rm -rf "$tmp"
elif [ "$VARIANT" = user ]; then
    gh release create "$bn" -R "$REPO" --title "os.ivan.gg $bn" \
        --notes "Factory images. Based on GrapheneOS $base.

Verified boot key fingerprint (SHA-256 of avb_pkmd.bin), the same for every model:
\`65894abf95040084e7f27ff8cb8e0d291b04abc266103fb88cef5e0c8c8bf161\`

Source:
\`\`\`
$src
\`\`\`

$section" \
        "${uploads[@]/#/$out/}" "$out/SHA256SUMS-$bn"
fi

/mnt/tank/scripts/notify-telegram.sh "os.ivan.gg $bn $DEVICE ($VARIANT) published: https://github.com/$REPO/releases/tag/$bn" 890 \
    > /dev/null 2>&1 || true
echo "published $bn"
