#!/usr/bin/env bash
# After a key rotation (generate-keys.sh --rotate): put the new verified boot key fingerprint
# everywhere it is published, in this repo and the site repo. Doesn't commit or deploy.
#   scripts/set-fingerprint.sh [avb_pkmd.bin]    default: the tree's keys/husky/avb_pkmd.bin
# The old fingerprint is read from scripts/publish-release.sh. Test results keep the old one.
set -euo pipefail

WS=/mnt/flash/scratch/grapheneos
ENVS=/mnt/flash/home/faeton/work/ee1os
SITE=/mnt/flash/home/faeton/work/ee1os-site
PKMD=${1:-$WS/grapheneos-17/keys/husky/avb_pkmd.bin}

[ -s "$PKMD" ] || { echo "no $PKMD"; exit 1; }
new=$(sha256sum "$PKMD" | cut -d' ' -f1)
old=$(grep -oE '[0-9a-f]{64}' "$ENVS/scripts/publish-release.sh" | head -n 1)
[ -n "$old" ] || { echo "no fingerprint found in scripts/publish-release.sh"; exit 1; }
[ "$old" != "$new" ] || { echo "already $new, nothing done"; exit 0; }
echo "old: $old"
echo "new: $new"

python3 - "$old" "$new" "$(date +%F)" "$ENVS" "$SITE" <<'EOF'
import pathlib, re, sys
old, new, today, envs, site = sys.argv[1:]
groups = lambda h: [h[i:i + 8] for i in range(0, 64, 8)]
subs = [
    (" ".join(f"<span>{g}</span>" for g in groups(old)), " ".join(f"<span>{g}</span>" for g in groups(new))),
    (old, new),
    (" ".join(groups(old)[:4]), " ".join(groups(new)[:4])),   # install tests
]
# short forms like 65894abf…f161
short = re.compile(re.escape(old[:8]) + "…([0-9a-f]{3,12})")
files = [f"{site}/{f}" for f in ("install.html", "lock.html", "lock/index.html", "scripts/install.sh",
         "scripts/install.ps1", "scripts/tests/run.sh", "PRODUCT.md", "README.md", ".impeccable/design.json")]
files += [f"{envs}/{f}" for f in ("scripts/publish-release.sh", "docs/08-development-and-testing.md")]
para = re.compile(r"Builds are signed with our own keys, generated on [0-9-]+\. Their certificates use\n"
                  r"    <code>CN=[^<]*</code>[^\n]*?(?= These are not)")
if not para.search(pathlib.Path(f"{site}/install.html").read_text()):
    sys.exit("install.html: the keys paragraph didn't match; nothing changed")
for f in files:
    p = pathlib.Path(f)
    if not p.exists():
        continue
    s = t = p.read_text()
    for a, b in subs:
        t = t.replace(a, b)
    t = short.sub(lambda m: new[:8] + "…" + new[-len(m.group(1)):], t)
    if t != s:
        p.write_text(t); print("updated", f)
# the install page says when the keys were made and what came before
p = pathlib.Path(f"{site}/install.html"); s = p.read_text()
t = para.sub(
           f"Builds are signed with our own keys, generated on {today}. Their certificates use\n"
           f"    <code>CN=ee1os</code>. Builds before {today} used an earlier key ({old[:8]}…{old[-4:]}); a\n"
           f"    phone on that key needs a fresh install (unlock, which erases it) to move to this one.\n   ", s)
p.write_text(t); print("updated install.html keys paragraph")
EOF
cp "$PKMD" "$SITE/scripts/tests/fixtures/avb_pkmd.bin"   # public key; the install tests check it

left=$(grep -rln "$old" "$SITE" "$ENVS" --exclude-dir=.git --exclude-dir=dist --exclude-dir=.wrangler \
    --exclude-dir=results 2>/dev/null | grep -v "/install.html$" || true)
[ -z "$left" ] || { echo "old fingerprint still in:"; echo "$left"; }
echo "next: run the site's install tests (scripts/tests/run.sh, KIND=ps), commit both repos;"
echo "deploy the site only when the first release on the new key is published (doc 08 Key rotation)."
