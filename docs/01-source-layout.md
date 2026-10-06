# 01 — Source layout

All sources are **sparse, blobless, depth-1** clones of GrapheneOS GitHub repos, branch `17`,
under `src/` (git-ignored). Recreate or refresh with:

```sh
scripts/sync-src.sh        # branch 17
scripts/sync-src.sh 16     # older branch, for comparison
```

To pull in more paths, edit the `REPOS` table in `scripts/sync-src.sh` and re-run.

## Pinned revisions (2026-10-06)

Upstream base per `src/platform_manifest/default.xml:8`: `android-17.0.0_r1`.

| Dir | GrapheneOS repo | SHA | Sparse paths |
|---|---|---|---|
| `frameworks_base` | platform_frameworks_base | `84183aff` | locksettings, pm, internal/widget, android/os, power, ext, keyguard, admin, devicepolicy, recoverysystem, StorageManagerService, UserController |
| `system_vold` | platform_system_vold | `a47ab7c` | all |
| `packages_apps_Settings` | platform_packages_apps_Settings | `e5c0d9d` | settings/password, settings/security, settings/ext, strings.xml |
| `system_core` | platform_system_core | `322ff51` | fs_mgr, init, rootdir |
| `hardware_interfaces` | platform_hardware_interfaces | `10f50d7` | boot, weaver, gatekeeper |
| `system_update_engine` | platform_system_update_engine | `79f478a` | all |
| `bootable_recovery` | platform_bootable_recovery | `4201242` | all |
| `platform_manifest` | platform_manifest | `0493b9e` | all |

Not pulled yet (add when needed): `system/security` (keystore2), `external/avb`,
`device/google/*` (per-device fstab and partition layout), `packages/apps/Launcher3`,
SystemUI outside `keyguard/`.

## Where to look for what

| Topic | Path under `src/` |
|---|---|
| Credential verify / unlock | `frameworks_base/services/core/java/com/android/server/locksettings/LockSettingsService.java` |
| Synthetic password, protectors, Weaver | `…/locksettings/SyntheticPasswordManager.java` |
| On-disk lock state | `…/locksettings/LockSettingsStorage.java` |
| Duress | `…/locksettings/Duress{PasswordHelper,Credential,Credentials,Wipe}.java` |
| Duress shell command | `…/locksettings/LockSettingsShellCommand.java:82,417` |
| Duress settings UI | `packages_apps_Settings/src/com/android/settings/security/DuressPassword*.java` |
| Secret deletion | `frameworks_base/…/server/recoverysystem/RecoverySystemService.java:556` |
| GrapheneOS wipe without reboot | `frameworks_base/…/server/recoverysystem/ExtendedWipeWithoutReboot.java` |
| Users | `frameworks_base/…/server/pm/UserManagerService.java`, `…/server/am/UserController.java` |
| Per-user storage keys | `system_vold/FsCrypt.cpp` |
| Boot slots HAL | `hardware_interfaces/boot/aidl/android/hardware/boot/IBootControl.aidl` |
| OTA slot switching | `system_update_engine/aosp/boot_control_android.cc`, `aosp/update_attempter_android.cc` |
| GrapheneOS system_server hooks | `frameworks_base/services/core/java/com/android/server/ext/` |

## Grep recipes

```sh
cd src
grep -rni 'duress' --exclude-dir=.git .
grep -n 'doVerifyCredential\|onCredentialVerified' \
  frameworks_base/services/core/java/com/android/server/locksettings/LockSettingsService.java
grep -n '^bool fscrypt_' system_vold/FsCrypt.cpp
```
