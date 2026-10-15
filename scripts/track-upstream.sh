#!/usr/bin/env bash
# Nightly on n5: follow GrapheneOS stable releases.
#   1. detect a new stable tag for husky (releases.grapheneos.org)
#   2. sync the tree to it
#   3. rebase our envs-17 branches onto it (stops on a conflict)
#   4. build husky userdebug, run the gate (tests/gate.sh, if present)
#   5. push the rebased branches and the manifest, tag them <tag>.os
# A release with strategic changes (scripts/upstream-watch.py check: new projects, branding,
# areas we depend on, files our forks change) stops after step 4, built but not pushed, until
# the owner decides. Every outcome goes to klava hq (OS topic, 890). Signing and publishing
# stay manual: release.sh.
#   DRY_RUN=1 track-upstream.sh   only say what would happen; changes nothing
#   FORCE_TAG=<tag>               process this tag even if it was done or skipped before
#   APPROVE=<tag>                 push a release held for approval
#   SKIP=<tag>                    drop a held release: forks back to what the fork has
#
# State in $STATE: upstream-tag (release the forks are on), base/<repo> (upstream commit under
# the fork's envs-17), pre/<repo> (envs-17 before this run's rebase, the expected remote),
# held-tag, held-bn and held/<repo> (a release waiting for the owner), skipped-tag.
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
RESTORE=0   # 1 while forks are rebased locally and a failure should put them back

log() { [ "$DRY" = 1 ] || echo "$(date -Is) $*" >> "$LOG"; }
notify() {
    if [ "$DRY" = 1 ]; then echo "$*"; return; fi
    log "$*"
    /mnt/tank/scripts/notify-telegram.sh "os.ivan.gg: $*" 890 || log "notify failed"
}
# put every fork's envs-17 back where it was before this run's rebase
restore() {
    for e in "${FORKS[@]}"; do
        p=${e%%:*} name=${e##*:}
        [ -s "$STATE/pre/$name" ] || continue
        git -C "$TREE/$p" rebase --abort 2>/dev/null
        git -C "$TREE/$p" checkout -q envs-17 2>/dev/null
        git -C "$TREE/$p" reset -q --hard "$(cat "$STATE/pre/$name")" && log "$p back on $(cat "$STATE/pre/$name")"
    done
    rm -rf "$STATE/pre"
}
fail() {
    if [ "$RESTORE" = 1 ]; then restore; notify "$* Forks put back as they were."; else notify "$*"; fi
    exit 1
}
dry() { if [ "$DRY" = 1 ]; then echo "DRY_RUN: $*"; exit 0; fi; }

# 5. publish the source: rebased branches with a <tag>.os tag each, then the manifest. Returns
# non-zero if anything wasn't pushed; the release then counts as not done.
publish() {
    for e in "${FORKS[@]}"; do
        p=${e%%:*} name=${e##*:}
        cd "$TREE/$p" || return 1
        git tag -f "$tag.os" envs-17 > /dev/null
        # only if the fork still has what we rebased from
        git push -q --atomic --force-with-lease="refs/heads/envs-17:$(cat "$STATE/pre/$name")" \
            "$ORG/$name.git" envs-17:refs/heads/envs-17 "+refs/tags/$tag.os:refs/tags/$tag.os" \
            >> "$LOG" 2>&1 || { notify "push of $p failed (did the fork move?)"; return 1; }
        git rev-parse "refs/tags/$tag^{commit}" > "$STATE/base/$name"
        log "$p pushed as $tag.os"
    done
    m=$(mktemp -d)
    # A release tag's default.xml is a fully pinned rewrite, so our commits don't rebase onto it.
    # Rebuild instead: the tag's manifest, our envs.xml, and an include of it at the end. The
    # branch follows envs-17; the <tag>.os tag sits on a commit pinning the forks to <tag>.os.
    remanifest() {
        mold=$(git -C "$m" rev-parse HEAD) || return 1
        git -C "$m" fetch -q "$UPSTREAM/platform_manifest" "refs/tags/$tag" || return 1
        git -C "$m" show HEAD:envs.xml > "$m.envs" || return 1
        git -C "$m" checkout -q -B envs-17 FETCH_HEAD || return 1
        mv "$m.envs" "$m/envs.xml"
        grep -q '<include name="envs.xml"/>' "$m/default.xml" \
            || sed -i 's|</manifest>|\n  <include name="envs.xml"/>\n</manifest>|' "$m/default.xml"
        git -C "$m" add envs.xml default.xml && git -C "$m" commit -q -m "Use the os-ivan-gg forks" \
            || return 1
        git -C "$m" checkout -q --detach || return 1
        sed -i "s|revision=\"refs/heads/envs-17\"|revision=\"refs/tags/$tag.os\"|" "$m/envs.xml"
        git -C "$m" commit -q -am "Pin the forks to $tag.os" && git -C "$m" tag -f "$tag.os" > /dev/null
    }
    if git clone -q -b envs-17 "$ORG/manifest.git" "$m" \
        && remanifest \
        && git -C "$m" push -q --atomic --force-with-lease="refs/heads/envs-17:$mold" origin \
            envs-17:refs/heads/envs-17 "+refs/tags/$tag.os:refs/tags/$tag.os" >> "$LOG" 2>&1; then
        log "manifest rebuilt on $tag"
        rm -rf "$m"
    else
        rm -rf "$m"
        notify "manifest for $tag wasn't pushed; the forks are pushed. Rerun with FORCE_TAG=$tag after fixing."
        return 1
    fi

    echo "$tag" > "$STATE/upstream-tag"
    rm -rf "$STATE/pre"
    packed="Flash archive: husky-flash.tar.gz."
    "$ENVS/scripts/pack-flash.sh" >> "$LOG" 2>&1 || packed="Packing the flash archive FAILED (track-upstream.log)."
    if [ -x "$ENVS/tests/gate.sh" ]; then gated="gate passed"; else gated="no test gate yet"; fi
    notify "build $bn on GrapheneOS $tag is ready: built, $gated, source pushed. $packed Release with scripts/release.sh $bn after a phone check."
}

if [ "$DRY" != 1 ]; then
    mkdir -p "$STATE/base"
    exec 9> "$STATE/track.lock"
    flock -n 9 || exit 0
fi
# never start next to a running build
if sudo docker ps --format '{{.Names}}' | grep -qx grapheneos-build; then
    log "a build is running, skipped"
    exit 0
fi

# a release held for the owner: approve, skip, or keep waiting
if [ -s "$STATE/held-tag" ]; then
    held=$(cat "$STATE/held-tag")
    if [ "${SKIP:-}" = "$held" ]; then
        dry "would drop held $held and put the forks back"
        restore
        echo "$held" > "$STATE/skipped-tag"
        rm -rf "$STATE/held-tag" "$STATE/held-bn" "$STATE/held"
        notify "$held skipped; forks are back on $(cat "$STATE/upstream-tag"). The next release will be picked up as usual."
        exit 0
    fi
    if [ "${APPROVE:-}" = "$held" ]; then
        tag=$held bn=$(cat "$STATE/held-bn")
        for e in "${FORKS[@]}"; do
            p=${e%%:*} name=${e##*:}
            [ "$(git -C "$TREE/$p" rev-parse envs-17)" = "$(cat "$STATE/held/$name")" ] \
                || fail "approval of $tag: envs-17 in $p moved since the build; not pushed"
        done
        # the flash archive is packed from out/: it has to be this build
        grep -qx "ro.build.version.incremental=$bn" "$TREE/out/target/product/$DEVICE/system/build.prop" \
            || fail "approval of $tag: out/ no longer holds build $bn; rebuild before approving"
        dry "would push held $tag (build $bn)"
        notify "$tag approved, pushing."
        publish || exit 1
        rm -rf "$STATE/held-tag" "$STATE/held-bn" "$STATE/held"
        exit 0
    fi
    # say once when a newer release arrives while one is held
    new=$(curl -fsS -m 30 "https://releases.grapheneos.org/$DEVICE-stable" | awk '{print $1}')
    if [[ $new =~ ^[0-9]{10}$ ]] && [ "$new" != "$held" ] && [ ! -e "$STATE/held/told-$new" ]; then
        dry "would say that $new is out while $held is held"
        notify "GrapheneOS $new is out, but $held is still held for approval. APPROVE=$held or SKIP=$held scripts/track-upstream.sh first."
        touch "$STATE/held/told-$new"
    fi
    dry "$held is held for approval"
    log "$held is held for approval"
    exit 0
fi

# 1. detect
tag=${FORCE_TAG:-$(curl -fsS -m 30 "https://releases.grapheneos.org/$DEVICE-stable" | awk '{print $1}')}
[[ $tag =~ ^[0-9]{10}$ ]] || fail "upstream check failed (got '$tag')"
last=$(cat "$STATE/upstream-tag" 2>/dev/null || echo none)
if [ -z "${FORCE_TAG:-}" ]; then
    if [ "$tag" = "$last" ]; then dry "no new release ($tag)"; log "no new release ($tag)"; exit 0; fi
    if [ "$tag" = "$(cat "$STATE/skipped-tag" 2>/dev/null)" ]; then log "$tag was skipped"; exit 0; fi
fi
dry "new GrapheneOS release $tag (ours: $last)"
notify "GrapheneOS $tag is out (ours is on $last). Syncing, rebasing, building."

# strategic changes hold the push for the owner (step 4b); a failed check counts as strategic
watch=$("$ENVS/scripts/upstream-watch.py" check "$tag" 2>> "$LOG"); wrc=$?
log "upstream-watch check $tag: exit $wrc, $(echo $watch)"

# each fork: clean, and local envs-17 exactly what the fork has (else a push would drop work)
mkdir -p "$STATE/pre"
for e in "${FORKS[@]}"; do
    p=${e%%:*} name=${e##*:}
    [ -s "$STATE/base/$name" ] || fail "no $STATE/base/$name (the upstream commit under envs-17)"
    [ -z "$(git -C "$TREE/$p" status --porcelain --untracked-files=no)" ] \
        || fail "stopped before syncing $tag: uncommitted changes in $p"
    git -C "$TREE/$p" fetch -q "$ORG/$name.git" envs-17 || fail "fetching our $name failed"
    [ "$(git -C "$TREE/$p" rev-parse envs-17)" = "$(git -C "$TREE/$p" rev-parse FETCH_HEAD)" ] \
        || fail "stopped before syncing $tag: envs-17 in $p differs from the fork; push or reset it first"
    git -C "$TREE/$p" rev-parse envs-17 > "$STATE/pre/$name"
done
RESTORE=1

# 2. sync everything to the tag; the forks follow envs-17 (local manifest) and are rebased below
cd "$TREE" || fail "no tree."
"$WS/bin/repo" init -b "refs/tags/$tag" >> "$LOG" 2>&1 || fail "repo init to $tag failed."
"$WS/bin/repo" sync -j8 --force-sync >> "$WS/sync.log" 2>&1 || fail "repo sync to $tag failed (sync.log)."

# 3. rebase each fork's envs-17 from its upstream base onto the tag
for e in "${FORKS[@]}"; do
    p=${e%%:*} name=${e##*:}
    cd "$TREE/$p" || fail "missing $p."
    git checkout -q envs-17 || fail "no envs-17 branch in $p."
    git reset -q --hard "$(cat "$STATE/pre/$name")"   # in case sync moved it
    git fetch -q "$UPSTREAM/$name" "refs/tags/$tag:refs/tags/$tag" || fail "fetching $tag for $p failed."
    if ! git rebase -q --onto "refs/tags/$tag^{commit}" "$(cat "$STATE/base/$name")" envs-17 >> "$LOG" 2>&1; then
        files=$(git diff --name-only --diff-filter=U | head -5 | tr '\n' ' ')
        fail "rebase onto $tag conflicts in $p: $files. Needs a hand."
    fi
    log "$p rebased onto $tag ($(git rev-list --count "refs/tags/$tag"..HEAD) commits)"
done

# 4. build and gate
bn=$(date -u +%Y%m%d%H)
label="husky $bn on GrapheneOS $tag at $(date +%s)"
cd "$WS" || fail "no workspace."
LUNCH=$DEVICE-cur-userdebug OUT_DIR=out BUILD_NUMBER=$bn BUILD_DATETIME=$(date +%s) \
    ./emu-build.sh "$label" droid > "$WS/husky-build-$bn.log" 2>&1
# the first BUILD_EXIT after this run's header (as in release.sh)
rc=$(awk -v m="=== $label " 'index($0, m) == 1 { f = 1; r = "" } f && r == "" && /^BUILD_EXIT=/ { r = $0 } END { print r }' build.log)
[ "$rc" = BUILD_EXIT=0 ] || fail "build $bn on GrapheneOS $tag failed ($rc); see build.log. Not pushed."
if [ -x "$ENVS/tests/gate.sh" ]; then
    "$ENVS/tests/gate.sh" >> "$LOG" 2>&1 \
        || fail "build $bn on GrapheneOS $tag built but the test gate failed; not pushed."
fi

# 4b. hold strategic releases for the owner; the rebased branches stay as they are
if [ "$wrc" != 0 ]; then
    echo "$tag" > "$STATE/held-tag"; echo "$bn" > "$STATE/held-bn"; mkdir -p "$STATE/held"
    for e in "${FORKS[@]}"; do
        git -C "$TREE/${e%%:*}" rev-parse envs-17 > "$STATE/held/${e##*:}"
    done
    RESTORE=0
    review=$(echo "$watch" | grep -- '-review.md$' | head -1)
    sum=""
    [ -n "$review" ] && sum=$(awk '/^#/{n++} n==2{exit} {print}' "$review" | head -c 2000)
    if [ "$wrc" = 10 ]; then why="has changes that need a decision"; else why="could not be checked (exit $wrc)"; fi
    notify "build $bn on GrapheneOS $tag is built, but the release $why. Not pushed.
$sum
Report: $(echo "$watch" | head -1)
Push: APPROVE=$tag scripts/track-upstream.sh, or drop: SKIP=$tag scripts/track-upstream.sh"
    exit 0
fi

# 5. publish. A failure here leaves the rebased branches as they are: some may be pushed.
RESTORE=0
publish || fail "publishing $tag failed; see track-upstream.log."
