#!/usr/bin/env bash
# Check the build tree before anything from it runs or gets signed (release.sh, track-upstream.sh).
# Exits non-zero and prints every reason when the tree isn't what was reviewed:
#   forks      commits over the upstream tag in each fork (HEAD, what the tree really has) are
#              exactly the approved ones in patches/approved.txt (as committed, not the working
#              copy): no extra, none missing, no merge or empty commits
#   base       each fork sits on the upstream tag: tag signed by GrapheneOS, its commit the one
#              the tag's manifest pins, an ancestor of HEAD, and state/base/<repo>
#   projects   every other project at the revision of the tag's signed default.xml, and the tree
#              has no project the manifest doesn't list; .repo/local_manifests is only envs.xml
#   clean      no uncommitted or untracked change in any project (ignored files too, in the
#              forks), no assume-unchanged/skip-worktree entries, replace refs or grafts
#   files      linkfile/copyfile targets at the tree root match their sources; nothing else at the
#              root but projects, out*/, keys/, releases/
#   vendor     each generated module (vendor/google_devices/<model>) matches the hash recorded when
#              vendor-module.sh made it (state/vendor/<model>), for the adevtool the tree has
# Approvals: if $SIGNERS exists, the last commit that changed approved.txt must carry a good
# signature by a key in it. That file is root's, outside the repo.
#   TAG=<tag> verify-tree.sh   check against this upstream tag (track-upstream.sh, after its
#                              rebase); default: state/upstream-tag
#   VENDOR=<model> ...         check only the vendor modules of these models (the one being
#                              built); default: all. No way to skip a check.
set -uo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
STATE=$WS/state
SIGNERS=/mnt/tank/scripts/os-ivan-gg/allowed_signers
GOS=$ENVS/scripts/grapheneos-allowed-signers
REPO=$WS/bin/repo
source "$ENVS/scripts/forks.sh"
tag=${TAG:-$(cat "$STATE/upstream-tag")}
t0=$(date +%s)
bad=0
no() { echo "FAIL: $*"; bad=1; }
vtag() { xgit -C "$1" -c gpg.ssh.allowedSignersFile="$GOS" verify-tag "refs/tags/$tag" > /dev/null 2>&1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# approvals, from os-ivan-gg's HEAD
[ -z "$(xgit -C "$ENVS" status --porcelain -- scripts patches workspace/build-env)" ] \
    || no "os-ivan-gg has uncommitted changes in scripts/, patches/ or workspace/build-env/"
xgit -C "$ENVS" show HEAD:patches/approved.txt > "$tmp/approved" 2>/dev/null \
    || no "patches/approved.txt isn't committed in os-ivan-gg"
if [ -e "$SIGNERS" ]; then
    [ "$(stat -c %U "$SIGNERS")" = root ] || no "$SIGNERS isn't owned by root"
    c=$(xgit -C "$ENVS" log -1 --format=%H -- patches/approved.txt)
    xgit -C "$ENVS" -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-commit "$c" > /dev/null 2>&1 \
        || no "approved.txt: commit ${c:0:12} has no good signature from $SIGNERS"
else
    echo "note: no $SIGNERS, approvals aren't signature-checked"
fi

# the tag's manifest: signed, and what the tree was initialised from
M=$TREE/.repo/manifests
vtag "$M" || no "manifest tag $tag isn't signed by GrapheneOS ($GOS)"
[ "$(xgit -C "$M" rev-parse HEAD)" = "$(xgit -C "$M" rev-parse "refs/tags/$tag^{commit}" 2>/dev/null)" ] \
    || no ".repo/manifests isn't on $tag"
xgit -C "$M" show "refs/tags/$tag:default.xml" > "$tmp/default.xml" 2>/dev/null || no "no default.xml in $tag"
lm=$(command ls -A "$TREE/.repo/local_manifests" 2>/dev/null | tr '\n' ' ')
[ "$lm" = "envs.xml " ] || no ".repo/local_manifests holds '$lm', expected envs.xml only"
cmp -s "$TREE/.repo/local_manifests/envs.xml" "$ENVS/scripts/envs-local-manifest.xml" \
    || no ".repo/local_manifests/envs.xml differs from scripts/envs-local-manifest.xml"
# path revision, and linkfile/copyfile: link|copy <src path> <dest>
python3 -I - "$tmp/default.xml" > "$tmp/pinned" 2> "$tmp/err" <<'EOF' || no "default.xml of $tag: $(cat "$tmp/err")"
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
if root.find('include') is not None or root.find('remove-project') is not None:
    sys.exit("has include or remove-project, not handled")
for p in root.iter('project'):
    path = p.get('path', p.get('name'))
    print('P', path, p.get('revision', ''))
    for f in p:
        if f.tag in ('linkfile', 'copyfile'):
            print('F', f.tag, path + '/' + f.get('src'), f.get('dest'))
EOF

# every project's HEAD and state
cd "$TREE" || exit 1
"$REPO" forall -j12 -c 'printf "%s %s\n" "$REPO_PATH" "$(git rev-parse HEAD)"' > "$tmp/heads" 2>/dev/null \
    || no "repo forall failed"
"$REPO" forall -j12 -c '
    s=$(git status --porcelain --ignore-submodules=none 2>&1 | head -3)
    [ -z "$s" ] || printf "%s: uncommitted or untracked: %s\n" "$REPO_PATH" "$(echo $s)"
    git ls-files -v | grep -q "^[a-zS]" && echo "$REPO_PATH: assume-unchanged or skip-worktree entries"
    [ -z "$(git for-each-ref refs/replace)" ] || echo "$REPO_PATH: replace refs"
    [ ! -e "$(git rev-parse --git-path info/grafts)" ] || echo "$REPO_PATH: grafts"
    true' > "$tmp/dirty" 2>/dev/null
while read -r l; do no "$l"; done < "$tmp/dirty"

declare -A pin fork seen
while read -r k path rev; do [ "$k" = P ] && pin[$path]=$rev; done < "$tmp/pinned"
for e in "${FORKS[@]}"; do fork[${e%%:*}]=${e##*:}; done
n=0
while read -r path head; do
    n=$((n + 1)) seen[$path]=1
    [ -n "${fork[$path]:-}" ] && continue
    if [ -z "${pin[$path]+x}" ]; then no "$path: not in the $tag manifest"
    elif [ "${pin[$path]}" != "$head" ]; then no "$path: at ${head:0:12}, $tag pins ${pin[$path]:0:12}"; fi
done < "$tmp/heads"
for path in "${!pin[@]}"; do
    [ -n "${seen[$path]:-}" ] || no "$path: in the $tag manifest but not in the tree"
done

# forks
for e in "${FORKS[@]}"; do
    p=${e%%:*} name=${e##*:} g=(xgit -C "$TREE/$p")
    vtag "$TREE/$p" || { no "$p: tag $tag missing or not signed by GrapheneOS"; continue; }
    base=$("${g[@]}" rev-parse "refs/tags/$tag^{commit}")
    [ "$base" = "${pin[$p]:-}" ] || no "$p: tag $tag is ${base:0:12}, the manifest pins ${pin[$p]:-nothing}"
    "${g[@]}" merge-base --is-ancestor "$base" HEAD || { no "$p: HEAD isn't on $tag"; continue; }
    [ -n "${TAG:-}" ] || [ "$(cat "$STATE/base/$name" 2>/dev/null)" = "$base" ] \
        || no "$p: state/base/$name isn't the $tag commit"
    [ -z "$("${g[@]}" status --porcelain --ignored)" ] || no "$p: ignored files in the worktree"
    : > "$tmp/have"
    for c in $("${g[@]}" rev-list --reverse "$base..HEAD"); do
        if [ "$("${g[@]}" rev-list --parents -n1 "$c" | wc -w)" -gt 2 ]; then no "$p: merge commit ${c:0:12}"; continue; fi
        id=$(patch_id "$TREE/$p" "$c")
        if [ -z "$id" ]; then no "$p: empty commit ${c:0:12} $("${g[@]}" log -1 --format=%s "$c")"; continue; fi
        echo "$id ${c:0:12} $("${g[@]}" log -1 --format=%s "$c")" >> "$tmp/have"
    done
    awk -v r="$name" '$1 == r { print $2 }' "$tmp/approved" | sort > "$tmp/want"
    cut -d' ' -f1 "$tmp/have" | sort > "$tmp/haveids"
    comm -13 "$tmp/want" "$tmp/haveids" | while read -r id; do
        no "$p: commit not approved: $(grep "^$id " "$tmp/have" | cut -d' ' -f2-)"; done
    comm -23 "$tmp/want" "$tmp/haveids" | while read -r id; do
        no "$p: approved commit missing: $(awk -v r="$name" -v i="$id" '$1 == r && $2 == i { $1 = $2 = ""; print substr($0, 3) }' "$tmp/approved")"; done
done 2>&1 | tee "$tmp/forkout"
grep -q '^FAIL' "$tmp/forkout" && bad=1

# tree root: projects' top dirs, link/copy targets, outputs, keys, releases; nothing else
declare -A top
for path in "${!pin[@]}"; do top[${path%%/*}]=1; done
while read -r k kind src dest; do
    [ "$k" = F ] || continue
    top[${dest%%/*}]=1
    if [ "$kind" = linkfile ]; then
        [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ] || no "$dest: not a link to $src"
    else
        cmp -s "$src" "$dest" || no "$dest: differs from $src"
    fi
done < "$tmp/pinned"
for f in $(command ls -A "$TREE"); do
    case $f in .repo|out|out_*|keys|releases) continue ;; esac
    [ -n "${top[$f]:-}" ] || no "unexpected at the tree root: $f"
done

# generated vendor modules
at=$(xgit -C "$TREE/vendor/adevtool" rev-parse HEAD)
for d in ${VENDOR:-$(command ls "$TREE/vendor/google_devices")}; do
    rec=$STATE/vendor/$d
    [ -s "$rec" ] || { no "vendor module $d: no recorded hash ($rec)"; continue; }
    grep -qx "adevtool=$at" "$rec" || no "vendor module $d: recorded for another adevtool than the tree's ${at:0:12}"
    grep -qx "tree=$(module_hash "$TREE/vendor/google_devices/$d")" "$rec" \
        || no "vendor module $d: content differs from the recorded hash"
done

echo "checked $n projects against $tag in $(( $(date +%s) - t0 ))s"
[ "$bad" = 0 ] && echo "tree OK" || { echo "tree NOT OK: nothing from it may be signed"; exit 1; }
