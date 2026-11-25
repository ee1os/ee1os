#!/usr/bin/env bash
# Signed stable releases for every model with keys, published by a button (doc 08 *Buttons*).
#   release-models.sh build           build and sign each model (release.sh, PUBLISH=0), then ask
#                                     in the OS topic, open for 24 hours: Publish (at the level
#                                     proposed for the site, update_level.py), the other level, Not now.
#                                     track-upstream.sh ends in this once the source is pushed
#   release-models.sh publish <tag> [important|routine]
#                                     publish what build left ready (the Publish buttons)
#   release-models.sh drop <tag>      forget it (Not now); the signed files stay in releases/
# State: $STATE/ready = the upstream tag, then one "<model> <build number>" per line.
# Nothing is uploaded by build. Run it in tmux: every model is a full build.
set -uo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/ee1os/os
STATE=$WS/state
LOG=$WS/release-models.log
READY=$STATE/ready

log() { echo "$(date -Is) $*" >> "$LOG"; }
notify() { log "$*"; /mnt/tank/scripts/notify-telegram.sh "ee1os: $*" 890 || log "notify failed"; }
die() { notify "$*"; exit 1; }
# husky first, then every other model with keys
models() { { echo husky; command ls "$TREE/keys"; } | grep -E '^[a-z0-9]+$' | grep -vx archive | awk '!s[$0]++'; }

case "${1:-}" in
build)
    # the tracker's lock: the nightly run must not move the tree between two models
    # (track-upstream.sh hands its own over: TRACK_LOCKED=1, fd 9)
    if [ "${TRACK_LOCKED:-}" != 1 ]; then
        exec 9> "$STATE/track.lock"
        flock -n 9 || { echo "the tracker or release-models.sh is running"; exit 1; }
    fi
    tag=$(cat "$STATE/upstream-tag") && [[ $tag =~ ^[0-9]{10}$ ]] || die "release builds: no state/upstream-tag."
    [ ! -s "$STATE/held-tag" ] || die "release builds: $(cat "$STATE/held-tag") is held; decide that first."
    # without the saved passphrase release.sh asks in a terminal, which nobody is at
    [ -s "$WS/.secrets/key-passphrase" ] || die "release builds: no saved key passphrase; run scripts/release.sh by hand."
    rm -f "$READY"
    echo "$tag" > "$READY.tmp"
    built="" failed=""
    for d in $(models); do
        out=$WS/release-$d-$(date +%Y%m%d%H%M).log
        log "building $d on $tag ($out)"
        if DEVICE=$d PUBLISH=0 "$ENVS/scripts/release.sh" user > "$out" 2>&1 \
            && bn=$(sed -n 's/^== release \([0-9]\{10\}\) .*/\1/p' "$out" | head -1) && [ -n "$bn" ] \
            && [ -s "$TREE/releases/$bn/release-$d-$bn/$d-ota_update-$bn.zip" ] \
            && [ -s "$TREE/releases/$bn/changes/report.json" ]; then
            echo "$d $bn" >> "$READY.tmp"
            built+="$d $bn, "
            log "$d $bn built and signed"
        else
            failed+="$d "
            log "$d failed: $(tail -1 "$out")"
        fi
    done
    [ -n "$built" ] || { rm -f "$READY.tmp"; die "release builds on GrapheneOS $tag failed for: $failed(release-<model>-*.log). Nothing to publish."; }
    mv "$READY.tmp" "$READY"
    level=$(python3 -I "$ENVS/scripts/update_level.py" ask $(tail -n +2 "$READY" | tr ' ' ':') 2>> "$LOG") \
        || level=$'undecided\nFor the site: the level could not be worked out; decide it here.'
    text="signed releases on GrapheneOS $tag are built, not published: ${built%, }.${failed:+ FAILED: $failed(release-<model>-*.log).}
Not tried on a phone. Publishing puts them on the stable channel: phones on it update over the air.
$(tail -n +2 <<< "$level")
By hand: scripts/release-models.sh publish $tag [important|routine]"
    case $(head -1 <<< "$level") in
        important) buttons=("publish=Publish (important)" "publish-routine=Publish as routine") ;;
        routine) buttons=("publish=Publish (routine)" "publish-important=Publish as important") ;;
        *) buttons=("publish-important=Publish as important" "publish-routine=Publish as routine") ;;
    esac
    log "$text"
    printf 'ee1os: %s\nThe buttons are open for 24 hours.\n' "$text" | "$ENVS/scripts/press.py" ask "$tag" "${buttons[@]}" "keep=Not now" >> "$LOG" 2>&1 \
        || /mnt/tank/scripts/notify-telegram.sh "ee1os: $text" 890 || log "notify failed"
    ;;
publish|drop)
    tag=${2:-} LEVEL=${3:-}
    [[ $LEVEL =~ ^(important|routine|)$ ]] || { echo "the level is important or routine, not '$LEVEL'"; exit 2; }
    [ -s "$READY" ] && [ "$(head -1 "$READY")" = "$tag" ] || { echo "nothing ready for '$tag'"; exit 1; }
    # taken out of the way first: a second run finds nothing
    work=$READY.$1.$$
    mv "$READY" "$work" || exit 1
    if [ "$1" = drop ]; then
        notify "releases on GrapheneOS $tag not published: $(tail -n +2 "$work" | tr '\n' ' '). The signed files stay in releases/; DEVICE=<model> scripts/publish-release.sh <build number> publishes one."
        rm -f "$work"
        exit 0
    fi
    bad=""
    while read -r d bn; do
        [[ $d =~ ^[a-z0-9]+$ && $bn =~ ^[0-9]{10}$ ]] || { bad+="'$d $bn' "; continue; }
        # only a build made from the release these buttons were about
        base=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["upstream"]["tag"])' \
            "$TREE/releases/$bn/changes/report.json" 2>> "$LOG")
        if [ "$base" != "$tag" ]; then
            log "$d $bn is on '$base', not $tag; not published"; bad+="$d "; continue
        fi
        log "publishing $d $bn"
        DEVICE=$d LEVEL=$LEVEL "$ENVS/scripts/publish-release.sh" "$bn" user >> "$LOG" 2>&1 < /dev/null \
            || { log "publishing $d $bn failed"; bad+="$d "; }
    done < <(tail -n +2 "$work")
    rm -f "$work"
    # publish-release.sh uploads the OTA files first: a model named here may be partly out
    [ -z "$bad" ] || die "publishing on GrapheneOS $tag didn't finish for: $bad(release-models.log); its OTA files may already be out. Check, then DEVICE=<model> scripts/publish-release.sh <build number>. The rest is out."
    notify "releases on GrapheneOS $tag are published. The changes pages are copied into the site repo and the builds added to its updates.json; read that entry, then commit and deploy the site by hand. Until then the site doesn't mention this update."
    ;;
*)
    sed -n '2,10p' "$0"; exit 2 ;;
esac
