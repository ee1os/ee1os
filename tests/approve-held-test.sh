#!/usr/bin/env bash
# scripts/approve-held.sh on a throwaway fork: one repo with two approved commits, rebased onto
# a new tag that changes one of them. Works on copies of the scripts with their paths pointed
# into a temp directory; the real tree, approved.txt and state are not touched.
# Run:  tests/approve-held-test.sh     PASS or FAIL per check, exit 1 if any failed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OLD=2026110100 NEW=2026120100
FAILS=0
pass() { echo "    PASS: $*"; }
fail() { echo "    FAIL: $*"; FAILS=$((FAILS + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Owner GIT_AUTHOR_EMAIL=owner@example.org
export GIT_COMMITTER_NAME=Owner GIT_COMMITTER_EMAIL=owner@example.org
g() { git -C "$F" "$@"; }

# a fresh fixture in $T/<n>: WS (tree with the fork, state), ENVS (scripts, patches), held $NEW
setup() {
    R=$T/$1; WS=$R/ws; ENVS=$R/envs; F=$WS/grapheneos-17/frk; S=$WS/state
    mkdir -p "$F" "$S/pre" "$S/base" "$S/held" "$ENVS/scripts" "$ENVS/patches"
    for f in approve-held.sh approve.sh forks.sh ledger.py; do
        sed -e "s|^WS=.*|WS=$WS|" -e "s|^ENVS=.*|ENVS=$ENVS|" "$HERE/../scripts/$f" > "$ENVS/scripts/$f"
    done
    # one fork instead of the six
    python3 - "$ENVS/scripts/forks.sh" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s, n = re.subn(r"FORKS=\(.*?\)\n", "FORKS=(frk:myrepo)\n", s, count=1, flags=re.S)
assert n == 1
open(p, "w").write(s)
EOF
    chmod +x "$ENVS"/scripts/*
    printf '[groups.g1]\norder = 1\ntitle = "One"\nwhat = "w"\nwhy = "y"\n' > "$ENVS/patches/changes.toml"
    : > "$ENVS/patches/approved.txt"
    git -C "$ENVS" init -q && git -C "$ENVS" add -A && git -C "$ENVS" commit -q -m start
    git -C "$F" init -q
    printf '1\n2\n3\n4\nfive\n6\n7\n8\n9\n' > "$F/file"; g add file; g commit -q -m upstream1
    g tag $OLD; g rev-parse HEAD > "$S/base/myrepo"
    g checkout -q -b envs-17
    echo a > "$F/a"; g add a; g commit -q -m "Add a"
    sed -i 's/five/five ours/' "$F/file"; g commit -q -am "Change three"
    TAG=$OLD "$ENVS/scripts/approve.sh" -g g1 myrepo HEAD~1 HEAD > /dev/null
    git -C "$ENVS" commit -q -am approve
    g rev-parse envs-17 > "$S/pre/myrepo"
    # upstream changes a line near ours: the rebase goes through, the second patch changes
    g checkout -q -b up $OLD; sed -i 's/^3$/3 changed/' "$F/file"; g commit -q -am upstream2; g tag $NEW
    g checkout -q envs-17; g rebase -q --onto $NEW "$(cat "$S/base/myrepo")" envs-17
    echo $NEW > "$S/held-tag"; g rev-parse envs-17 > "$S/held/myrepo"
}
held() { g rev-parse envs-17 > "$S/held/myrepo"; }
run() { "$ENVS/scripts/approve-held.sh" "$@" 2>&1; }
list() { "$ENVS/scripts/approve-held.sh" --list "$@" 2> /dev/null; }
clean() { [ -z "$(git -C "$ENVS" status --porcelain)" ]; }
lines() { wc -l < "$ENVS/patches/approved.txt"; }

echo "## approve-held.sh"
setup 1
out=$(list $NEW)
[ "$(echo "$out" | wc -l)" = 1 ] && [[ "$out" == "myrepo "*" g1 Change three" ]] \
    && pass "--list names the one commit the rebase changed, with its group" || fail "--list: $out"
before=$(cat "$ENVS/patches/approved.txt")
out=$(run $NEW); rc=$?
new=$(g rev-parse --short=12 envs-17)
[ "$rc" = 0 ] && grep -q "^myrepo [0-9a-f]* $new g1 Change three$" "$ENVS/patches/approved.txt" \
    && [ "$(lines)" = 2 ] && clean && [ "$(cat "$ENVS/patches/approved.txt")" != "$before" ] \
    && pass "it approves that commit, drops the stale line and commits approved.txt" \
    || fail "approve: rc=$rc $out"
out=$(run $NEW); [ $? != 0 ] && pass "a second run has nothing to approve" || fail "second run: $out"

refused() {   # refused <what>: --list prints nothing, the run fails, approved.txt is as it was
    before=$(cat "$ENVS/patches/approved.txt")
    l=$(list $NEW); out=$(run $NEW); rc=$?
    [ -z "$l" ] && [ "$rc" != 0 ] && [ "$(cat "$ENVS/patches/approved.txt")" = "$before" ] && clean \
        && pass "$1" || fail "$1: list='$l' rc=$rc $out"
}
setup 2; echo x > "$F/x"; g add x; g commit -q -m "Add x"; held
refused "a commit added after the rebase: nothing is approved"
setup 3; echo b >> "$F/a"; g commit -q -a --amend -m "Change three" --author "Other <o@example.org>"; held
refused "the same subject from another author: nothing is approved"
setup 4; g commit -q --amend -m "Change four"; held
refused "another subject in that place: nothing is approved"
setup 5; grep -v "Change three" "$ENVS/patches/approved.txt" > "$R/a"; cp "$R/a" "$ENVS/patches/approved.txt"
git -C "$ENVS" commit -q -am drop
refused "the commit it replaces was never approved: nothing is approved"
setup 6; echo y >> "$F/a"; g commit -q -a --amend --no-edit
refused "envs-17 moved since the release was held: nothing is approved"
setup 7; g reset -q --hard HEAD~1; held
refused "a commit the rebase dropped: nothing is approved here"
setup 8; rm -rf "$S/pre"
refused "no record of the branch before the rebase: nothing is approved"
setup 9; echo 2026120105 > "$S/held-bn"
refused "a release that is already built: nothing is approved"
setup 10; echo 2026120200 > "$S/held-tag"
refused "a tag that isn't the held one: nothing is approved"
setup 11; printf '#!/bin/sh\nexit 1\n' > "$ENVS/.git/hooks/pre-commit"; chmod +x "$ENVS/.git/hooks/pre-commit"
before=$(cat "$ENVS/patches/approved.txt"); out=$(run $NEW); rc=$?
[ "$rc" != 0 ] && [ "$(cat "$ENVS/patches/approved.txt")" = "$before" ] && clean \
    && pass "when the commit of approved.txt fails the file is put back" || fail "failed commit: rc=$rc $out"

echo
if [ "$FAILS" = 0 ]; then echo "approve-held: all passed"; else echo "approve-held: $FAILS failed"; fi
[ "$FAILS" = 0 ]
