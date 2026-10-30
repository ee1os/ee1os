#!/usr/bin/env bash
# Generate the release signing keys for husky on n5. Owner-run.
#   scripts/generate-keys.sh            first keys; refuses if any exist
#   scripts/generate-keys.sh --rotate   move the current keys to an archive, then make new ones
#                                       (doc 08 *Key rotation*; a locked phone needs a wipe)
# Asks for one passphrase (hidden, typed twice) and uses it for every key, then copies the keys
# to a backed-up folder and prints the fingerprint of the AVB public key for the install page.
#   keys:   grapheneos-17/keys/husky/     (tree on flash/scratch, not backed up)
#   backup: ~/work/os-ivan-gg-keys/husky/ (flash/home: snapshots, tank, vv)
# Never deletes keys. --rotate moves, for the current key fingerprint <fp>:
#   grapheneos-17/keys/<model>/   -> grapheneos-17/keys/archive/<date>-<fp>/<model>/
#   ~/work/os-ivan-gg-keys/husky/ -> ~/work/os-ivan-gg-keys/archive/<date>-<fp>/husky/
#   .secrets/key-passphrase       -> .secrets/archive/<date>-<fp>-key-passphrase
# (keys/ and .secrets/ are hidden from builds, run.sh). All models get a copy of the new husky
# keys (doc 08 Stage 6). Keep one more copy offline, old and new.
set -euo pipefail
DEVICE=husky
# The first keys (2026-10-13, 65894abf...) said CN=os.ivan.gg, the project's earlier name
CN=ee1os
WS=/mnt/flash/scratch/grapheneos
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
BACKUP=/mnt/flash/home/faeton/work/os-ivan-gg-keys

if [ "${1:-}" = --rotate ]; then
    keys=$WS/grapheneos-17/keys
    [ -s "$keys/$DEVICE/avb_pkmd.bin" ] || { echo "no current keys in $keys/$DEVICE, nothing done"; exit 1; }
    [ -s "$BACKUP/$DEVICE/avb_pkmd.bin" ] || { echo "no backup in $BACKUP/$DEVICE, nothing done"; exit 1; }
    cmp -s "$keys/$DEVICE/avb_pkmd.bin" "$BACKUP/$DEVICE/avb_pkmd.bin" \
        || { echo "the tree's keys and the backup differ, nothing done"; exit 1; }
    label=$(date +%F)-$(sha256sum "$keys/$DEVICE/avb_pkmd.bin" | cut -c1-8)
    [ -e "$keys/archive/$label" ] || [ -e "$BACKUP/archive/$label" ] \
        && { echo "archive $label already exists, nothing done"; exit 1; }
    echo "Archiving the current keys as $label."
    read -rp "Type ROTATE to continue: " answer
    [ "$answer" = ROTATE ] || { echo "nothing done"; exit 1; }
    mkdir -p "$keys/archive/$label" "$BACKUP/archive/$label"
    chmod 700 "$keys/archive" "$BACKUP/archive"
    for d in "$keys"/*/; do
        d=${d%/}
        [ "${d##*/}" = archive ] || mv "$d" "$keys/archive/$label/"
    done
    mv "$BACKUP/$DEVICE" "$BACKUP/archive/$label/"
    if [ -e "$WS/.secrets/key-passphrase" ]; then
        mkdir -p "$WS/.secrets/archive" && chmod 700 "$WS/.secrets/archive"
        mv "$WS/.secrets/key-passphrase" "$WS/.secrets/archive/$label-key-passphrase"
    fi
    echo "archived: $keys/archive/$label, $BACKUP/archive/$label"
    models=$(command ls "$keys/archive/$label")
    "$ENVS/scripts/generate-keys.sh"
    for m in $models; do
        [ "$m" = "$DEVICE" ] || cp -a "$keys/$DEVICE" "$keys/$m"
    done
    echo "copied the new keys for: $models"
    echo "release.sh reads the passphrase from $WS/.secrets/key-passphrase (owner-only, 600) or asks."
    exit 0
fi

if [ "${1:-}" != --inside ]; then
    keys=$WS/grapheneos-17/keys/$DEVICE
    [ -e "$keys" ] && { echo "$keys already exists, nothing done"; exit 1; }
    [ -e "$BACKUP/$DEVICE" ] && { echo "$BACKUP/$DEVICE already exists, nothing done"; exit 1; }
    # the tools need the build container; this script is mounted there at the same path
    "$ENVS/workspace/build-env/run.sh" exec-it "bash $ENVS/scripts/generate-keys.sh --inside" \
        || { echo "key generation failed; remove $keys before trying again"; exit 1; }
    [ -s "$keys/avb_pkmd.bin" ] || { echo "no keys were made"; exit 1; }
    mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
    cp -a "$keys" "$BACKUP/"
    echo
    echo "keys:   $keys"
    echo "backup: $BACKUP/$DEVICE"
    echo "AVB public key (avb_pkmd.bin) sha256, for the install page:"
    sha256sum "$keys/avb_pkmd.bin" | cut -d' ' -f1
    exit 0
fi

# --- inside the container ---
cd /src/grapheneos-17
source script/common.sh   # signing_keys
read -rsp "Key passphrase: " password; echo
read -rsp "Same again: " again; echo
[ "$password" = "$again" ] || { echo "the two don't match, nothing done"; exit 1; }
[ ${#password} -ge 12 ] || { echo "use at least 12 characters, nothing done"; exit 1; }
umask 077
mkdir -p keys/$DEVICE
cd keys/$DEVICE
for key in "${signing_keys[@]}"; do
    # make_key reads the passphrase from stdin and prints it back; keep that off the screen.
    # It exits 1 even when it worked (its EXIT trap), so check the files instead
    printf '%s\n' "$password" | ../../development/tools/make_key "$key" "/CN=$CN/" \
        > /dev/null || true
    [ -s "$key.pk8" ] && [ -s "$key.x509.pem" ] || { echo "making $key failed"; exit 1; }
    echo "made $key"
done
export password
openssl genrsa 4096 2>/dev/null | openssl pkcs8 -topk8 -scrypt -passout env:password -out avb.pem
unset password
../../external/avb/avbtool.py extract_public_key --key avb.pem --output avb_pkmd.bin
echo "made avb.pem and avb_pkmd.bin"
