#!/usr/bin/env bash
# Publish a release that release.sh built and signed with PUBLISH=0.
#   [DEVICE=shiba] [NOTE=text] publish-release.sh <build number> [user|userdebug]
# NOTE, when set, goes under the model's heading in the release notes (e.g. that a model hasn't been tried on a phone yet).
# Same upload as release.sh step 3 and 4: the OTA zip and channel file replace the rolling
# "updates" release; a user build also gets its own release with the install zip and checksums,
# tags ee1os-<bn> in the forks, the file list on the release and its changes page in the site
# repo (site/changes/<bn>/, committed and deployed by hand after a look).
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/ee1os/os
SITE=/mnt/flash/home/faeton/work/ee1os/site
DEVICE=${DEVICE:-husky}
REPO=ee1os/releases
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
# GitHub refuses files over 2 GiB. An install zip over 2.14 GB (7 MB short of that) goes up in
# parts (.zip.part1, ...), listed in order in SHA256SUMS before the whole zip; the install
# scripts join them. The OTA zip can't be split: the Updater reads it in one piece.
[ "$(stat -c %s "$out/$DEVICE-ota_update-$bn.zip")" -lt 2147483648 ] \
    || { echo "$DEVICE-ota_update-$bn.zip is over 2 GiB, GitHub won't take it; not published"; exit 1; }
inst=$DEVICE-install-$bn.zip
rm -f "$out/$inst".part[0-9]
uploads=("$inst")
if [ "$(stat -c %s "$out/$inst")" -gt 2140000000 ]; then
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

# A stable release's changes page (release.sh made it): tag the commits it describes in each
# fork as ee1os-<bn>, never moved, so its links keep working; then the page goes to the site.
changes=$TREE/releases/$bn/changes
if [ "$VARIANT" = user ]; then
    for f in report.json index.html "files-$bn.tsv.gz"; do
        [ -s "$changes/$f" ] || { echo "no $changes/$f (release.sh makes it); not published"; exit 1; }
    done
    [ -d "$SITE/.git" ] || { echo "no site repo at $SITE; not published"; exit 1; }
    python3 -I -c 'import json, sys
for f in json.load(open(sys.argv[1]))["forks"]: print(f["path"], f["name"], f["commit"])' \
        "$changes/report.json" > "$changes/.forks"
    while read -r p name c; do
        g=(git -C "$TREE/$p")
        if have=$("${g[@]}" rev-parse -q --verify "refs/tags/ee1os-$bn^{commit}"); then
            [ "$have" = "$c" ] || { echo "$p: tag ee1os-$bn is at ${have:0:12}, the report has ${c:0:12}"; exit 1; }
        else
            "${g[@]}" tag "ee1os-$bn" "$c"
        fi
        remote=$("${g[@]}" ls-remote "https://github.com/ee1os/$name.git" "refs/tags/ee1os-$bn" | cut -f1)
        if [ -z "$remote" ]; then
            "${g[@]}" push -q "https://github.com/ee1os/$name.git" "refs/tags/ee1os-$bn:refs/tags/ee1os-$bn"
        elif [ "$("${g[@]}" rev-parse "refs/tags/ee1os-$bn")" != "$remote" ]; then
            echo "$p: github has another ee1os-$bn; not published"; exit 1
        fi
    done < "$changes/.forks"
    rm -f "$changes/.forks"
fi

gh release view updates -R "$REPO" > /dev/null 2>&1 \
    || gh release create updates -R "$REPO" --title "Over-the-air updates" \
        --notes "Files the phone's Updater reads. Replaced on every release."
# Every channel file the Updater can ask for: its stable, beta and alpha choices (all the same
# build here), or testing for userdebug. 2026101406 offered a security preview opt-in, and
# phones that took it ask for <channel>-security-preview, so those are published too (T9 U2).
if [ "$VARIANT" = user ]; then chans=(stable beta alpha); else chans=(testing); fi
chanfiles=()
for c in "${chans[@]}"; do
    [ -s "$out/$DEVICE-$c" ] || { echo "missing $out/$DEVICE-$c"; exit 1; }
    sed "s/ $c\$/ $c-security-preview/" "$out/$DEVICE-$c" > "$out/$DEVICE-$c-security-preview"
    chanfiles+=("$out/$DEVICE-$c" "$out/$DEVICE-$c-security-preview")
done
gh release upload updates -R "$REPO" --clobber \
    "$out/$DEVICE-ota_update-$bn.zip" "${chanfiles[@]}"
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
    gh release create "$bn" -R "$REPO" --title "ee1os $bn" \
        --notes "Factory images. Based on GrapheneOS $base.

What differs from GrapheneOS, file by file: https://ee1os.com/changes/$bn/

Verified boot key fingerprint (SHA-256 of avb_pkmd.bin), the same for every model:
\`70b98fe0d9925692af9afc29981d3a58ec076ca4a056d53ff4ca14d1f0d0669f\`

Source:
\`\`\`
$src
\`\`\`

$section" \
        "${uploads[@]/#/$out/}" "$out/SHA256SUMS-$bn"
fi

if [ "$VARIANT" = user ]; then
    tsv=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["downloads"]["tsv"])' "$changes/report.json")
    gh release upload "$bn" -R "$REPO" --clobber "$changes/$tsv"
    mkdir -p "$SITE/changes/$bn"
    cp "$changes/index.html" "$changes/report.json" "$SITE/changes/$bn/"
    python3 -I "$ENVS/scripts/fork_report.py" --index "$SITE/changes"
    echo "Changes page in $SITE/changes/$bn/. Look at it (cd $SITE && ./deploy.sh --local), then:"
    echo "  cd $SITE && git add changes && git commit -m 'Add the changes page for $bn' && git push && ./deploy.sh"
fi

/mnt/tank/scripts/notify-telegram.sh "ee1os $bn $DEVICE ($VARIANT) published: https://github.com/$REPO/releases/tag/$bn" 890 \
    > /dev/null 2>&1 || true
echo "published $bn"
