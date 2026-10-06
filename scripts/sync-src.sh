#!/usr/bin/env bash
# Recreate / refresh the sparse, blobless GrapheneOS checkouts under src/.
# Usage: scripts/sync-src.sh [branch]   (default: 17)
set -euo pipefail
BRANCH="${1:-17}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/src"; cd "$ROOT/src"

# name|dir|sparse paths ('/*' = everything)
REPOS=(
  "platform_frameworks_base|frameworks_base|/services/core/java/com/android/server/locksettings/ /services/core/java/com/android/server/pm/ /core/java/com/android/internal/widget/ /core/java/android/os/ /services/core/java/com/android/server/power/ /services/core/java/com/android/server/StorageManagerService.java /core/java/android/ext/ /services/core/java/com/android/server/ext/ /packages/SystemUI/src/com/android/keyguard/ /core/java/android/app/admin/ /services/devicepolicy/ /services/core/java/com/android/server/am/UserController.java /services/core/java/com/android/server/recoverysystem/"
  "platform_system_vold|system_vold|/*"
  "platform_packages_apps_Settings|packages_apps_Settings|/src/com/android/settings/password/ /src/com/android/settings/security/ /src/com/android/settings/ext/ /res/values/strings.xml"
  "platform_system_core|system_core|/fs_mgr/ /init/ /rootdir/"
  "platform_hardware_interfaces|hardware_interfaces|/boot/ /weaver/ /gatekeeper/"
  "platform_system_update_engine|system_update_engine|/*"
  "platform_bootable_recovery|bootable_recovery|/*"
  "platform_manifest|platform_manifest|/*"
)

for entry in "${REPOS[@]}"; do
  IFS='|' read -r name dir paths <<<"$entry"
  (
    if [[ ! -d "$dir/.git" ]]; then
      git clone -q --depth 1 --branch "$BRANCH" --filter=blob:none --sparse \
        "https://github.com/GrapheneOS/$name.git" "$dir"
    else
      git -C "$dir" fetch -q --depth 1 origin "$BRANCH"
      git -C "$dir" checkout -q -B "$BRANCH" FETCH_HEAD
    fi
    set -f  # keep "/*" literal, word-split only
    # shellcheck disable=SC2086
    git -C "$dir" sparse-checkout set --no-cone $paths
    echo "$dir $(git -C "$dir" rev-parse --short HEAD)"
  ) &
done
wait
