#!/usr/bin/env bash
# Pack the images of the last husky build for `fastboot flashall` on another machine.
#   pack-flash.sh [out-dir]    default: grapheneos-17/out/target/product/husky
# Writes husky-flash.tar.gz next to the tree and prints its sha256.
set -euo pipefail
WS=/mnt/flash/scratch/grapheneos
P="${1:-$WS/grapheneos-17/out/target/product/husky}"
cd "$P"
F=(android-info.txt bootloader.img radio.img boot.img init_boot.img dtbo.img vendor_boot.img
   vendor_kernel_boot.img pvmfw.img vbmeta.img super_empty.img system.img system_ext.img
   product.img vendor.img system_dlkm.img vendor_dlkm.img)
sha256sum "${F[@]}" > husky-SHA256SUMS
tar czf "$WS/husky-flash.tar.gz.tmp" "${F[@]}" husky-SHA256SUMS
mv "$WS/husky-flash.tar.gz.tmp" "$WS/husky-flash.tar.gz"
sha256sum "$WS/husky-flash.tar.gz"
