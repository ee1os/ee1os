#!/usr/bin/env bash
# Nightly on n5: follow GrapheneOS stable releases.
#   1. detect a new stable tag for husky (releases.grapheneos.org)
#   2. sync the tree to it
#   3. rebase our envs-17 branches onto it (stops on a conflict)
#   3b. regenerate the vendor modules (adevtool generate-all) if the sync moved adevtool
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
ORG=https://github.com/ee1os
UPSTREAM=https://github.com/GrapheneOS
source "$ENVS/scripts/forks.sh"   # FORKS: tree path : repo name, for every project we change
DRY=${DRY_RUN:-0}
RESTORE=0   # 1 while forks are rebased locally and a failure should put them back

log() { [ "$DRY" = 1 ] || echo "$(date -Is) $*" >> "$LOG"; }
notify() {
    if [ "$DRY" = 1 ]; then echo "$*"; return; fi
    log "$*"
    /mnt/tank/scripts/notify-telegram.sh "ee1os: $*" 890 || log "notify failed"
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
# the adevtool commit a vendor module was generated with (its adevtool-version-check.mk)
module_rev() { sed -n 's/.*rev-parse HEAD),\([0-9a-f]\{40\}\)).*/\1/p' \
    "$TREE/vendor/google_devices/$1/adevtool-version-check.mk" 2>/dev/null; }
# the models to keep buildable, $DEVICE first: every one with keys or a vendor module (release.sh
# builds them from this tree)
models() { { echo "$DEVICE"; command ls "$TREE/keys" "$TREE/vendor/google_devices"; } 2>/dev/null \
    | grep -E '^[a-z0-9]+$' | grep -vx archive | awk '!s[$0]++'; }
dry() { if [ "$DRY" = 1 ]; then echo "DRY_RUN: $*"; exit 0; fi; }

# 5. publish the source: rebased branches with a <tag>.os tag each, then the manifest. Returns
# non-zero if anything wasn't pushed; the release then counts as not done.
publish() {
    # only a tree that is exactly what was reviewed (verify-tree.sh); approving a held release
    # comes through here too
    out=$(TAG=$tag VENDOR=$DEVICE "$ENVS/scripts/verify-tree.sh" 2>&1) \
        || { notify "tree check for $tag failed, not pushed:
$(echo "$out" | grep '^FAIL' | head -15)"; return 1; }
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
        git -C "$m" add envs.xml default.xml && git -C "$m" commit -q -m "Use the ee1os forks" \
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
    notify "build $bn on GrapheneOS $tag is ready: built, $gated, source pushed. $packed Release it after a phone check: scripts/release.sh builds and signs a fresh one (doc 08)."
}

# 3b-5 for the rebased forks of $tag: vendor modules, tree check, build, gate, then hold (strategic,
# $wrc) or push. Run by the nightly path, and by APPROVE= for a release held before its build.
build_and_push() {
    # nothing from the tree runs before this (both ways in: the nightly path and APPROVE=)
    vout=$(TAG=$tag VENDOR=- "$ENVS/scripts/verify-tree.sh" 2>&1) \
        || fail "tree check for $tag failed, not built:
$(echo "$vout" | grep '^FAIL' | head -15)"
    # 3b. vendor modules (vendor/google_devices/<model>) are generated, not synced, and refuse to
    # build once the tree's adevtool moves past the commit they were made with. Regenerate them in
    # the build container (doc 08 Stage 6); the stock factory image goes to vendor/adevtool/dl/.
    at=$(git -C "$TREE/vendor/adevtool" rev-parse HEAD) || fail "no vendor/adevtool in the tree."
    for d in $(models); do
        [ "$(module_rev "$d")" = "$at" ] && continue
        # a new factory image (~5 GB) plus its unpacked copy (~6 GB) and the module
        free=$(df -BG --output=avail "$TREE" | tail -1 | tr -dc 0-9)
        [ "$free" -ge 25 ] || fail "only ${free} GB free in scratch; the $d vendor module for $tag needs about 25."
        log "regenerating the $d vendor module for adevtool $at"
        trap 'sudo docker start ollama > /dev/null' EXIT
        sudo docker stop ollama > /dev/null && echo "$(date +%T) ollama stopped for adevtool $d" >> "$WS/mem.log"
        (cd "$WS" && ./guard.sh) &
        NAME=grapheneos-build JOBS=12 HIGHMEM=2 MEM=44g MEMSWAP=68g "$ENVS/workspace/build-env/run.sh" exec \
            "$ENVS/scripts/vendor-module.sh $d" > "$WS/vendor-$d-$tag.log" 2>&1; vrc=$?
        wait
        if sudo docker start ollama > /dev/null; then
            echo "$(date +%T) ollama restarted after adevtool $d" >> "$WS/mem.log"; trap - EXIT
        else
            notify "ollama didn't start again after the $d vendor module; start it by hand."
        fi
        if [ "$vrc" = 0 ] && [ "$(module_rev "$d")" = "$at" ]; then
            log "$d vendor module regenerated"
        elif [ "$d" = "$DEVICE" ]; then
            fail "adevtool generate-all for $tag failed for $d (exit $vrc); see vendor-$d-$tag.log. Not pushed."
        else
            # another model doesn't hold up this build; it stays on its old module until fixed
            notify "adevtool generate-all for $tag failed for $d (exit $vrc); see vendor-$d-$tag.log. Its old module is kept, so DEVICE=$d release.sh won't build until that is fixed. $DEVICE goes on."
        fi
    done

    # 3c. the whole tree, vendor modules included, before any of it is built
    vout=$(TAG=$tag VENDOR=$DEVICE "$ENVS/scripts/verify-tree.sh" 2>&1) \
        || fail "tree check for $tag failed, not built:
    $(echo "$vout" | grep '^FAIL' | head -15)"

    # 4. build and gate
    bn=$(date -u +%Y%m%d%H)
    label="husky $bn on GrapheneOS $tag at $(date +%s)"
    cd "$WS" || fail "no workspace."
    LUNCH=$DEVICE-cur-userdebug OUT_DIR=out BUILD_NUMBER=$bn BUILD_DATETIME=$(date +%s) \
        ./emu-build.sh "$label" droid > "$WS/husky-build-$bn.log" 2>&1
    # the first BUILD_EXIT after this run's header (as in release.sh)
    rc=$(awk -v m="=== $label " 'index($0, m) == 1 { f = 1; r = "" } f && r == "" && /^BUILD_EXIT=/ { r = $0 } END { print r }' build.log)
    [ "$rc" = BUILD_EXIT=0 ] || fail "build $bn on GrapheneOS $tag failed ($rc); see build.log. Not pushed."
    # no boot animation zip may ship: it would replace our setup logo and the stock one (doc 00)
    zips=$(find "$TREE/out/target/product/$DEVICE"/{system,product,system_ext,vendor,oem}/media \
        -maxdepth 1 -name 'bootanimation*.zip' 2>/dev/null | sed "s|$TREE/out/target/product/$DEVICE/||")
    [ -z "$zips" ] || fail "build $bn on GrapheneOS $tag ships a boot animation ($zips); not pushed."
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
    rm -rf "$STATE/held-tag" "$STATE/held-bn" "$STATE/held"
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
        tag=$held
        for e in "${FORKS[@]}"; do
            p=${e%%:*} name=${e##*:}
            [ "$(git -C "$TREE/$p" rev-parse envs-17)" = "$(cat "$STATE/held/$name")" ] \
                || fail "approval of $tag: envs-17 in $p moved since it was held; not pushed"
        done
        if [ ! -s "$STATE/held-bn" ]; then
            # held before its build for commits to approve: check, build and push now (the owner's
            # approval covers strategic changes too)
            dry "would check, build and push held $tag"
            notify "$tag approved, checking and building."
            wrc=0 watch=""
            build_and_push
            exit 0
        fi
        bn=$(cat "$STATE/held-bn")
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
if [ "$DRY" = 1 ]; then
    # the adevtool the tag pins, from its manifest; the sync would move the tree to it
    at=$(curl -fsS -m 30 "https://raw.githubusercontent.com/GrapheneOS/platform_manifest/refs/tags/$tag/default.xml" \
        | sed -n 's/.*path="vendor\/adevtool"[^>]*revision="\([0-9a-f]\{40\}\)".*/\1/p')
    for d in $(models); do
        [ "$(module_rev "$d")" = "${at:-?}" ] || echo "DRY_RUN: would regenerate the $d vendor module (adevtool ${at:-unknown})"
    done
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
trap 'fail "track-upstream for $tag was stopped."' INT TERM HUP

# 2. sync everything to the tag; the forks follow envs-17 (local manifest) and are rebased below
cd "$TREE" || fail "no tree."
"$WS/bin/repo" init -b "refs/tags/$tag" >> "$LOG" 2>&1 || fail "repo init to $tag failed."
"$WS/bin/repo" sync -j8 --force-sync >> "$WS/sync.log" 2>&1 || fail "repo sync to $tag failed (sync.log)."
# a project whose objects didn't all arrive checks out with files missing, and repo still
# reports success (external/talkback for 2026101600); a fresh sync of it fixes that
broken=$("$WS/bin/repo" forall -j8 -c '[ -z "$(git ls-files --deleted | head -1)" ] || echo "$REPO_PATH"' 2>/dev/null | tr '\n' ' ')
[ -z "$broken" ] || fail "sync to $tag left files missing in: $broken. Delete those projects (worktree and .repo/projects, .repo/project-objects) and sync them again."

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

# 3a. the rebased forks against the approvals, before anything from the tree runs (vendor
# modules come after). Commits whose patch-id the rebase changed, or new ones, hold the release
# unbuilt until the owner approves them; any other failure stops here.
vout=$(TAG=$tag VENDOR=- "$ENVS/scripts/verify-tree.sh" 2>&1); vrc=$?
log "verify-tree $tag (before the build): exit $vrc"
if [ "$vrc" != 0 ]; then
    fails=$(echo "$vout" | grep '^FAIL: ')
    other=$(echo "$fails" | grep -v ': commit not approved: \|: approved commit missing: ')
    if [ -z "$fails" ] || [ -n "$other" ]; then
        fail "tree check after the rebase onto $tag failed, not built:
$(echo "${other:-$vout}" | head -15)"
    fi
    echo "$tag" > "$STATE/held-tag"; rm -f "$STATE/held-bn"; mkdir -p "$STATE/held"
    for e in "${FORKS[@]}"; do
        git -C "$TREE/${e%%:*}" rev-parse envs-17 > "$STATE/held/${e##*:}"
    done
    [ "$wrc" = 0 ] || touch "$STATE/held/strategic"
    RESTORE=0
    notify "GrapheneOS $tag: after the rebase some fork commits need approval; not built, not pushed.
$(echo "$fails" | sed 's/^FAIL: //' | head -15)
Approve: TAG=$tag scripts/approve.sh <repo> <commit>..., drop stale lines: TAG=$tag scripts/approve.sh --prune, commit approved.txt, then APPROVE=$tag scripts/track-upstream.sh (builds and pushes). Or SKIP=$tag.$([ "$wrc" = 0 ] || echo " It also has strategic changes: $(echo "$watch" | head -1)")"
    exit 0
fi

build_and_push
