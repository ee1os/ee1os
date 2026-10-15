#!/usr/bin/env bash
# Nightly on n5: follow GrapheneOS stable releases.
#   1. detect a new stable tag for husky (releases.grapheneos.org)
#   2. sync the tree to it
#   3. rebase our envs-17 branches onto it (stops on a conflict)
#   4. build husky userdebug, run the gate (tests/gate.sh, if present)
#   5. push the rebased branches and the manifest, tag them <tag>.os
# Every outcome goes to klava hq (NET topic). Signing and publishing stay manual: release.sh.
#   DRY_RUN=1 track-upstream.sh   only detect and print, no notification, no changes
#   FORCE_TAG=<tag>               process this tag even if it was done before
set -uo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
STATE=$WS/state
LOG=$WS/track-upstream.log
DEVICE=husky
ORG=https://github.com/os-ivan-gg
UPSTREAM=https://github.com/GrapheneOS
# tree path : repo name, for every project we change
FORKS=(build/make:platform_build
       frameworks/base:platform_frameworks_base
       packages/apps/Settings:platform_packages_apps_Settings
       packages/apps/SetupWizard2:platform_packages_apps_SetupWizard2
       packages/apps/Updater:platform_packages_apps_Updater
       system/sepolicy:platform_system_sepolicy)
DRY=${DRY_RUN:-0}

mkdir -p "$STATE/base"
log() { echo "$(date -Is) $*" >> "$LOG"; }
notify() {
    log "$*"
    if [ "$DRY" = 1 ]; then echo "$*"; return; fi
    /mnt/tank/scripts/notify-telegram.sh "os.ivan.gg: $*" || log "notify failed"
}
fail() { notify "$*"; exit 1; }

exec 9> "$STATE/track.lock"
flock -n 9 || exit 0
# never start next to a running build
if sudo docker ps --format '{{.Names}}' | grep -qx grapheneos-build; then
    log "a build is running, skipped"
    exit 0
fi

# 1. detect
tag=${FORCE_TAG:-$(curl -fsS -m 30 "https://releases.grapheneos.org/$DEVICE-stable" | awk '{print $1}')}
[[ $tag =~ ^[0-9]{10}$ ]] || fail "upstream check failed (got '$tag')"
last=$(cat "$STATE/upstream-tag" 2>/dev/null || echo none)
if [ "$tag" = "$last" ] && [ -z "${FORCE_TAG:-}" ]; then
    log "no new release ($tag)"
    exit 0
fi
[ "$DRY" = 1 ] && { echo "new GrapheneOS release $tag (last done: $last)"; exit 0; }
notify "GrapheneOS $tag is out (ours is on $last). Syncing, rebasing, building."

# uncommitted work in a fork would be lost or mixed in
for e in "${FORKS[@]}"; do
    p=${e%%:*}
    [ -z "$(git -C "$TREE/$p" status --porcelain --untracked-files=no)" ] \
        || fail "stopped before syncing $tag: uncommitted changes in $p"
done

# 2. sync everything to the tag; the forks follow envs-17 (local manifest) and are rebased below
cd "$TREE" || exit 1
"$WS/bin/repo" init -b "refs/tags/$tag" >> "$LOG" 2>&1 || fail "repo init to $tag failed"
"$WS/bin/repo" sync -j8 --force-sync >> "$WS/sync.log" 2>&1 || fail "repo sync to $tag failed (sync.log)"

# 3. rebase each fork's envs-17 from its old upstream base onto the tag
for e in "${FORKS[@]}"; do
    p=${e%%:*} name=${e##*:}
    cd "$TREE/$p" || fail "missing $p"
    git checkout -q envs-17 || fail "no envs-17 branch in $p"
    git fetch -q "$UPSTREAM/$name" "refs/tags/$tag:refs/tags/$tag" || fail "fetching $tag for $p failed"
    if [ ! -s "$STATE/base/$name" ]; then
        # first run: our commits sit on upstream branch 17 as it was then
        git fetch -q "$UPSTREAM/$name" 17 || fail "fetching upstream 17 for $p failed"
        git merge-base HEAD FETCH_HEAD > "$STATE/base/$name"
    fi
    old=$(cat "$STATE/base/$name")
    if ! git rebase -q --onto "refs/tags/$tag" "$old" envs-17 >> "$LOG" 2>&1; then
        files=$(git diff --name-only --diff-filter=U | head -5 | tr '\n' ' ')
        git rebase --abort
        fail "rebase onto $tag conflicts in $p: $files. Branch left as it was; needs a hand."
    fi
    log "$p rebased onto $tag ($(git rev-list --count "refs/tags/$tag"..HEAD) commits)"
done

# 4. build and gate
bn=$(date -u +%Y%m%d%H)
cd "$WS" || exit 1
LUNCH=$DEVICE-cur-userdebug OUT_DIR=out BUILD_NUMBER=$bn BUILD_DATETIME=$(date +%s) \
    ./emu-build.sh "husky $bn on GrapheneOS $tag" droid > "$WS/husky-build-$bn.log" 2>&1
sed -n "/=== husky $bn on GrapheneOS $tag/,\$p" build.log | grep -q 'BUILD_EXIT=0' \
    || fail "build $bn on GrapheneOS $tag failed; see build.log. Branches are rebased locally, not pushed."
if [ -x "$ENVS/tests/gate.sh" ]; then
    "$ENVS/tests/gate.sh" >> "$LOG" 2>&1 \
        || fail "build $bn on GrapheneOS $tag built but the test gate failed; not pushed."
fi

# 5. publish the source: rebased branches, a tag per upstream release, the manifest
for e in "${FORKS[@]}"; do
    p=${e%%:*} name=${e##*:}
    cd "$TREE/$p" || exit 1
    git tag -f "$tag.os" envs-17 > /dev/null
    git push -q --force "$ORG/$name.git" envs-17 "refs/tags/$tag.os" >> "$LOG" 2>&1 \
        || fail "push of $p failed"
    git rev-parse "refs/tags/$tag" > "$STATE/base/$name"
done
m=$(mktemp -d)
# A release tag's default.xml is a fully pinned rewrite, so our commits don't rebase onto it.
# Rebuild instead: the tag's manifest, our envs.xml, and an include of it at the end.
remanifest() {
    git -C "$m" fetch -q "$UPSTREAM/platform_manifest" "refs/tags/$tag" || return 1
    git -C "$m" show HEAD:envs.xml > "$m.envs" || return 1
    git -C "$m" checkout -q -B envs-17 FETCH_HEAD || return 1
    mv "$m.envs" "$m/envs.xml"
    grep -q '<include name="envs.xml"/>' "$m/default.xml" \
        || sed -i 's|</manifest>|\n  <include name="envs.xml"/>\n</manifest>|' "$m/default.xml"
    git -C "$m" add envs.xml default.xml && git -C "$m" commit -q -m "Use the os-ivan-gg forks"
}
if git clone -q -b envs-17 "$ORG/manifest.git" "$m" \
    && remanifest \
    && git -C "$m" tag -f "$tag.os" \
    && git -C "$m" push -q --force origin envs-17 "refs/tags/$tag.os"; then
    log "manifest rebased onto $tag"
else
    notify "manifest rebase onto $tag failed; the forks are pushed"
fi
rm -rf "$m"

echo "$tag" > "$STATE/upstream-tag"
"$ENVS/scripts/pack-flash.sh" >> "$LOG" 2>&1
notify "build $bn on GrapheneOS $tag is ready: built, gate passed, source pushed. Flash archive: husky-flash.tar.gz. Release with scripts/release.sh $bn after a phone check."
