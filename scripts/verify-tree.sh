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
#   clean      no uncommitted, untracked or ignored file in any project (but adevtool's dl/ and
#              node_modules/), no assume-unchanged/skip-worktree entries, replace refs or
#              grafts; each fork's HEAD is its envs-17 branch
#   files      linkfile/copyfile targets match their sources; the dirs holding projects hold
#              nothing else (at the root also out*/, keys/, releases/)
#   vendor     each generated module (vendor/google_devices/<model>) matches the hash recorded when
#              vendor-module.sh made it (state/vendor/<model>), for the adevtool the tree has
# Approvals: if $SIGNERS exists, the last commit that changed approved.txt must carry a good
# signature by a key in it. That file is root's, outside the repo.
#   TAG=<tag> verify-tree.sh   check against this upstream tag (track-upstream.sh, after its
#                              rebase); default: state/upstream-tag
#   VENDOR=<model> ...         require the tree's adevtool only for these models' modules (the
#                              one being built; "-": none, before regenerating them); default:
#                              all. Every module's content is checked always. No way to skip a
#                              check.
set -uo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
STATE=$WS/state
SIGNERS=/mnt/tank/scripts/os-ivan-gg/allowed_signers
GOS=$ENVS/scripts/grapheneos-allowed-signers
REPO=$WS/bin/repo
source "$ENVS/scripts/forks.sh"
# every git here, repo forall's too, without user or system config and replace objects
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1
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
# ignored files count too, except adevtool's downloads and its node_modules
"$REPO" forall -j12 -c '
    s=$(git status --porcelain --untracked-files=all --ignored=traditional --ignore-submodules=none 2>&1 \
        | if [ "$REPO_PATH" = vendor/adevtool ]; then grep -Ev "^!! (dl|node_modules)/"; else cat; fi | head -3)
    [ -z "$s" ] || printf "%s: uncommitted, untracked or ignored: %s\n" "$REPO_PATH" "$(echo "$s" | tr "\n" " ")"
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
    # publish pushes envs-17: it has to be what was checked
    [ "$("${g[@]}" symbolic-ref -q HEAD)" = refs/heads/envs-17 ] || no "$p: HEAD isn't the envs-17 branch"
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

# files outside every project: linkfile/copyfile targets must match their sources, and the
# dirs that hold projects (the root, device/, vendor/, ...) nothing else. At the root also
# out*/, keys/, releases/; vendor/google_devices is checked below.
while read -r k kind src dest; do
    [ "$k" = F ] || continue
    if [ "$kind" = linkfile ]; then
        [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ] || no "$dest: not a link to $src"
    else
        cmp -s "$src" "$dest" || no "$dest: differs from $src"
    fi
done < "$tmp/pinned"
python3 -I - "$TREE" "$tmp/pinned" > "$tmp/stray" 2>&1 <<'EOF' || no "walking the tree failed: $(cat "$tmp/stray")"
import os, sys
tree, pinned = sys.argv[1], sys.argv[2]
P, D = set(), set()
for l in open(pinned):
    f = l.split()
    if f[0] == 'P': P.add(f[1])
    else: D.add(f[3])
A = {''}
for x in P | D:
    parts = x.split('/')
    for i in range(1, len(parts)):
        A.add('/'.join(parts[:i]))
A -= P
for a in sorted(A):
    for e in sorted(os.listdir(os.path.join(tree, a) if a else tree)):
        rel = a + '/' + e if a else e
        if rel in P or rel in A or rel in D or rel == 'vendor/google_devices':
            continue
        if not a and (e in ('.repo', 'keys', 'releases', 'out') or e.startswith('out_')):
            continue
        print(rel)
EOF
while read -r l; do no "outside every project: $l"; done < "$tmp/stray"

# generated vendor modules
# generated vendor modules: every one is read by every build (soong parses the whole tree), so
# each must match its record; the adevtool commit only for the models in $VENDOR
at=$(xgit -C "$TREE/vendor/adevtool" rev-parse HEAD)
for d in $(command ls -A "$TREE/vendor/google_devices"); do
    rec=$STATE/vendor/$d
    [ -s "$rec" ] || { no "vendor module $d: no recorded hash ($rec)"; continue; }
    grep -qx "tree=$(module_hash "$TREE/vendor/google_devices/$d")" "$rec" \
        || no "vendor module $d: content differs from the recorded hash"
done
for d in ${VENDOR:-$(command ls -A "$TREE/vendor/google_devices")}; do
    [ "$d" = - ] && continue
    grep -qx "adevtool=$at" "$STATE/vendor/$d" 2>/dev/null \
        || no "vendor module $d: not made with the tree's adevtool ${at:0:12}"
done

echo "checked $n projects against $tag in $(( $(date +%s) - t0 ))s"
[ "$bad" = 0 ] && echo "tree OK" || { echo "tree NOT OK: nothing from it may be signed"; exit 1; }
