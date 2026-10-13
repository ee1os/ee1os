#!/usr/bin/env bash
# Generate the release signing keys for husky, once, on n5. Owner-run.
#   scripts/generate-keys.sh
# Asks for one passphrase (hidden, typed twice) and uses it for every key, then copies the keys
# to a backed-up folder and prints the fingerprint of the AVB public key for the install page.
#   keys:   grapheneos-17/keys/husky/     (tree on flash/scratch, not backed up)
#   backup: ~/work/os-ivan-gg-keys/husky/ (flash/home: snapshots, tank, vv)
# Refuses to touch existing keys. Keep one more copy offline.
set -euo pipefail
DEVICE=husky
CN=os.ivan.gg
WS=/mnt/flash/scratch/grapheneos
ENVS=/mnt/flash/home/faeton/work/os-ivan-gg
BACKUP=/mnt/flash/home/faeton/work/os-ivan-gg-keys

if [ "${1:-}" != --inside ]; then
    keys=$WS/grapheneos-17/keys/$DEVICE
    [ -e "$keys" ] && { echo "$keys already exists, nothing done"; exit 1; }
    [ -e "$BACKUP/$DEVICE" ] && { echo "$BACKUP/$DEVICE already exists, nothing done"; exit 1; }
    # the tools need the build container; this script is mounted there at the same path
    "$ENVS/workspace/build-env/run.sh" exec-it "bash $ENVS/scripts/generate-keys.sh --inside"
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
    # make_key reads the passphrase from stdin and prints it back; keep that off the screen
    printf '%s\n' "$password" | ../../development/tools/make_key "$key" "/CN=$CN/" > /dev/null
    echo "made $key"
done
export password
openssl genrsa 4096 2>/dev/null | openssl pkcs8 -topk8 -scrypt -passout env:password -out avb.pem
unset password
../../external/avb/avbtool.py extract_public_key --key avb.pem --output avb_pkmd.bin
echo "made avb.pem and avb_pkmd.bin"
