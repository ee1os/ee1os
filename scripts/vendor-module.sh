#!/bin/bash
# Regenerate one model's vendor module with adevtool, inside the build container (doc 08
# Stage 6): run.sh exec scripts/vendor-module.sh <codename>
# Its helper tools come from the main out/ (lunch is the emulator target: the model's own
# product config refuses to load while its module is outdated). adevtool downloads the stock
# factory image into vendor/adevtool/dl/ when it isn't there yet; older images of the model
# are removed after a good run. adevtool deletes the module before writing it, so the old one
# is kept aside and put back if this fails.
set -euo pipefail
d=${1:?codename}
export PATH=/src/tools/node24/bin:$PATH COREPACK_ENABLE_DOWNLOAD_PROMPT=0
cd /src/grapheneos-17
mod=vendor/google_devices/$d keep=out_adevtool_deps/old-$d
rm -rf "$keep"
[ -d "$mod" ] && cp -a "$mod" "$keep"
trap 'rc=$?; if [ $rc != 0 ] && [ -d "$keep" ]; then rm -rf "$mod"; mv "$keep" "$mod"; echo "old $mod put back"; fi' EXIT

m -j"${JOBS:-8}" aapt2 apksigner aprotoc arsclib debugfs dispol fsck.erofs lpdump lpunpack lz4 \
    ota_extractor simg2img sqlite3 toybox
mkdir -p out_adevtool_deps/host
ln -sfn /src/grapheneos-17/out/host/linux-x86 out_adevtool_deps/host/linux-x86
export ADEVTOOL_SKIP_DEP_BUILD=1
corepack yarn install --cwd vendor/adevtool --frozen-lockfile
vendor/adevtool/bin/run generate-all -d "$d"
rm -rf "$keep"

# the image just used is the newest; drop the older ones of this model
cd vendor/adevtool/dl
ls -t "$d"-*-factory-*.zip 2>/dev/null | tail -n +2 | xargs -r rm -f
ls -td unpacked/"$d"-* 2>/dev/null | tail -n +2 | xargs -r rm -rf
