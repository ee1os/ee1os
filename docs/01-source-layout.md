# 01 — Source layout

**Primary reference (since 2026-10-08): the full tree** on n5,
`/mnt/flash/scratch/grapheneos/grapheneos-17` (repo checkout, doc 08 *Layout on n5*). The forks
are on branch `envs-17` over the GrapheneOS release tag in `state/upstream-tag` next to the
tree (`2026110200` on 2026-11-10); every other project is at that tag's manifest revision.

**How to read the line references in docs 01–03 and 06.** They are a snapshot of upstream
branch `17` at the SHAs in the table below (frameworks_base `84183aff`, 2026-10-06, re-checked
2026-10-08). They are not updated with each rebase (doc 07 B1), so in the current tree the
lines have moved, and in the forked projects our commits add code around them. To find one
today, search for the named method or string in that project, or read the old line with
`git show 84183aff:<path>` in the project (the SHA is in its history). Current locations of
the duress hook and the dispatch: doc 03 *In the fork today*.

The sparse clones are optional: `src/` doesn't exist on n5 any more. They were **sparse,
blobless, depth-1** clones of GrapheneOS GitHub repos, branch `17`, under `src/`
(git-ignored), and a path written `src/<dir>/…` maps to the full tree as in the table below
(`frameworks_base` = `frameworks/base`, `system_vold` = `system/vold`, …). Recreate or
refresh them with:

```sh
scripts/sync-src.sh        # branch 17
scripts/sync-src.sh 16     # older branch, for comparison
```

To pull in more paths, edit the `REPOS` table in `scripts/sync-src.sh` and re-run.

## Pinned revisions (2026-10-06)

The snapshot the line references use. Every SHA here is still in its project's history in the
full tree (checked 2026-11-10), so `git show <sha>:<path>` works.

Upstream base per `src/platform_manifest/default.xml:8`: `android-17.0.0_r1`.

| Dir | GrapheneOS repo | SHA | Sparse paths |
|---|---|---|---|
| `frameworks_base` | platform_frameworks_base | `84183aff` | locksettings (+ its servicestests), `tests/DuressPasswordTest`, `UserControllerHelper`, pm, internal/widget, android/os, power, ext, keyguard, admin, devicepolicy, recoverysystem, StorageManagerService, UserController |
| `system_vold` | platform_system_vold | `a47ab7c` | all |
| `packages_apps_Settings` | platform_packages_apps_Settings | `e5c0d9d` | settings/password, settings/security, settings/ext, strings.xml |
| `system_core` | platform_system_core | `322ff51` | init, rootdir |
| `system_fs_fs_mgr` | platform_system_fs_fs_mgr | `f2de922` | all (fs_mgr moved out of system_core on `17`; added 2026-10-08) |
| `hardware_interfaces` | platform_hardware_interfaces | `10f50d7` | boot, weaver, gatekeeper |
| `system_update_engine` | platform_system_update_engine | `79f478a` | all |
| `bootable_recovery` | platform_bootable_recovery | `4201242` | all |
| `platform_manifest` | platform_manifest | `0493b9e` | all |

Not pulled yet (add when needed): `system/security` (keystore2), `external/avb`,
`device/google/*` (per-device fstab and partition layout), `packages/apps/Launcher3`,
SystemUI outside `keyguard/`.

## Where to look for what

Paths under `src/`; in the full tree, the dir names map as in the table above.

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

In the full tree, one project at a time (never the whole tree in one grep):

```sh
cd /mnt/flash/scratch/grapheneos/grapheneos-17/frameworks/base
git grep -n 'doVerifyCredential\|dispatchCredential' -- services/core/java/com/android/server/locksettings/
```

In the sparse clones, if recreated:

```sh
cd src
grep -rni 'duress' --exclude-dir=.git .
grep -n 'doVerifyCredential\|onCredentialVerified' \
  frameworks_base/services/core/java/com/android/server/locksettings/LockSettingsService.java
grep -n '^bool fscrypt_' system_vold/FsCrypt.cpp
```
