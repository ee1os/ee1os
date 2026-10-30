#!/usr/bin/env bash
# Approve fork commits for release (verify-tree.sh checks the tree against patches/approved.txt).
#   approve.sh <repo> <commit>...   add these commits of one fork (repo name, e.g.
#                                   platform_frameworks_base) to approved.txt
#   approve.sh --draft              print a line for every commit over the upstream tag in all forks
# Lines: <repo> <patch-id> <short-sha> <subject>. Only <repo> <patch-id> are checked; the SHA and
# subject say what was approved. This doesn't commit: the owner reviews and commits approved.txt,
# signed, from m3max.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
TREE=$WS/grapheneos-17
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
LIST=$ENVS/patches/approved.txt
source "$ENVS/scripts/forks.sh"
tag=${TAG:-$(cat "$WS/state/upstream-tag")}   # TAG=<tag>: over another tag (a held rebase)

line() {   # line <path> <repo> <commit>
    c=$(xgit -C "$TREE/$1" rev-parse --verify "$3^{commit}")
    [ "$(xgit -C "$TREE/$1" rev-list --parents -n1 "$c" | wc -w)" -le 2 ] \
        || { echo "$2 ${c:0:12}: a merge commit; rebase it into plain commits" >&2; return 1; }
    id=$(patch_id "$TREE/$1" "$c")
    [ -n "$id" ] || { echo "$2 ${c:0:12}: empty commit; drop it" >&2; return 1; }
    echo "$2 $id ${c:0:12} $(xgit -C "$TREE/$1" log -1 --format=%s "$c")"
}
path_of() {
    for e in "${FORKS[@]}"; do [ "${e##*:}" = "$1" ] && { echo "${e%%:*}"; return; }; done
    echo "$1 is not a fork: ${FORKS[*]##*:}" >&2; return 1
}

if [ "${1:-}" = --draft ]; then
    for e in "${FORKS[@]}"; do
        p=${e%%:*} name=${e##*:}
        for c in $(xgit -C "$TREE/$p" rev-list --reverse "refs/tags/$tag..HEAD"); do
            line "$p" "$name" "$c"
        done
    done
    exit 0
fi

name=${1:?usage: approve.sh <repo> <commit>... | --draft}; shift
[ $# -gt 0 ] || { echo "usage: approve.sh <repo> <commit>..."; exit 2; }
p=$(path_of "$name")
for c in "$@"; do
    l=$(line "$p" "$name" "$c")
    id=$(echo "$l" | cut -d' ' -f2)
    if grep -q "^$name $id " "$LIST" 2>/dev/null; then echo "already approved: $l"; continue; fi
    echo "$l" >> "$LIST"
    echo "added: $l"
done
echo "Review and commit patches/approved.txt (signed) from m3max."
