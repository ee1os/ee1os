#!/usr/bin/env bash
# Approve what a rebase changed, for the tag held before its build (the Approve button of
# track-upstream.sh; scripts/press.py).
#   approve-held.sh <tag>          approve, prune, commit approved.txt
#   approve-held.sh --list <tag>   only print what it would approve: <repo> <sha> <group> <subject>
#                                  (nothing, exit 0, when there is nothing it can approve)
# A commit is approved here only as the rebased form of an approved one. In each fork the
# commits before the rebase (state/base..state/pre) and after it (<tag>..envs-17) must pair up
# one to one, in order, with the same subject and author; a commit whose patch-id changed is
# approved if the one it is paired with was, and keeps that line's group. Anything else (a
# commit added, dropped or reordered, a new subject, a branch that moved since it was held) is
# not approved here: that needs approve.sh -g by hand. Nothing is written unless every waiting
# commit can be approved, and approved.txt is put back if the commit of it doesn't happen.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/ee1os/os
LIST=$ENVS/patches/approved.txt
STATE=$WS/state
source "$ENVS/scripts/forks.sh"

list=0
[ "${1:-}" = --list ] && { list=1; shift; }
tag=${1:-}
[[ $tag =~ ^[0-9]{10}$ ]] || { echo "usage: approve-held.sh [--list] <tag>"; exit 2; }
# --list: stdout is the plan and nothing else; what can't be approved goes to stderr
[ "$list" = 0 ] || exec 3>&1 1>&2
[ "$(cat "$STATE/held-tag" 2>/dev/null)" = "$tag" ] || { echo "$tag is not held"; exit 1; }
[ ! -e "$STATE/held-bn" ] || { echo "$tag is already built"; exit 1; }
if [ "$list" = 0 ]; then
    [ -z "$(xgit -C "$ENVS" status --porcelain -- scripts patches workspace/build-env)" ] \
        || { echo "uncommitted changes in scripts/, patches/ or workspace/build-env/"; exit 1; }
fi

plan=$(mktemp); trap 'rm -f "$plan"' EXIT
bad=0
no() { echo "by hand: $*"; bad=1; }
for e in "${FORKS[@]}"; do
    p=${e%%:*} name=${e##*:}
    d=$TREE/$p
    pre=$(cat "$STATE/pre/$name" 2>/dev/null) base=$(cat "$STATE/base/$name" 2>/dev/null)
    [ -n "$pre" ] && [ -n "$base" ] || { no "$name: no record of the branch before the rebase"; continue; }
    [ "$(xgit -C "$d" rev-parse envs-17)" = "$(cat "$STATE/held/$name" 2>/dev/null)" ] \
        || { no "$name: envs-17 moved since $tag was held"; continue; }
    mapfile -t old < <(xgit -C "$d" rev-list --reverse "$base..$pre")
    mapfile -t new < <(xgit -C "$d" rev-list --reverse "refs/tags/$tag..envs-17")
    [ "${#old[@]}" = "${#new[@]}" ] \
        || { no "$name: ${#old[@]} commits before the rebase, ${#new[@]} after"; continue; }
    for i in "${!new[@]}"; do
        c=${new[$i]} o=${old[$i]}
        id=$(patch_id "$d" "$c")
        [ -n "$id" ] || { no "$name ${c:0:12}: empty commit"; continue; }
        grep -q "^$name $id " "$LIST" && continue
        subject=$(xgit -C "$d" log -1 --format=%s "$c")
        [ "$(xgit -C "$d" log -1 --format='%an <%ae>%n%s' "$c")" = "$(xgit -C "$d" log -1 --format='%an <%ae>%n%s' "$o")" ] \
            || { no "$name ${c:0:12} $subject: not the commit that was in its place before the rebase"; continue; }
        oid=$(patch_id "$d" "$o")
        group=$(awk -v r="$name" -v i="$oid" '$1 == r && $2 == i { print $4; exit }' "$LIST")
        [ -n "$oid" ] && [ -n "$group" ] \
            || { no "$name ${c:0:12} $subject: the commit it replaces wasn't approved"; continue; }
        echo "$name ${c:0:12} $group $subject" >> "$plan"
    done
done
if [ "$list" = 1 ]; then
    # for the caller's message: the plan, or nothing when the button would be of no use
    [ "$bad" != 0 ] || cat "$plan" >&3
    exit 0
fi
[ "$bad" = 0 ] || exit 1
[ -s "$plan" ] || { echo "nothing to approve for $tag"; exit 1; }

undo() { xgit -C "$ENVS" reset -q -- patches/approved.txt; xgit -C "$ENVS" checkout -q -- patches/approved.txt; rm -f "$plan"; }
trap undo EXIT
while read -r name sha group _; do
    TAG=$tag "$ENVS/scripts/approve.sh" -g "$group" "$name" "$sha" > /dev/null
done < "$plan"
TAG=$tag "$ENVS/scripts/approve.sh" --prune 2> /dev/null
git -C "$ENVS" add patches/approved.txt
git -C "$ENVS" commit -q -m "Approve the commits rebased onto $tag" -- patches/approved.txt
trap 'rm -f "$plan"' EXIT
timeout 120 git -C "$ENVS" push -q || echo "note: approved.txt is committed but not pushed"
echo "approved for $tag:"; cat "$plan"
