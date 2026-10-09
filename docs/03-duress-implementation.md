# 03 — The existing duress feature, as implemented

Revision: frameworks_base `84183aff`, Settings `e5c0d9d`. `LS/` below means
`src/frameworks_base/services/core/java/com/android/server/locksettings/`.

This is the only "second credential" mechanism in GrapheneOS today. Everything in doc 04
is a generalisation of it, so the details matter.

## Files

| File | Lines | Role |
|---|---|---|
| `LS/DuressPasswordHelper.java` | 119 | hook, enrolment, matching |
| `LS/DuressCredential.java` | 66 | one credential: salt + stretched value, (de)serialisation, validation |
| `LS/DuressCredentials.java` | 104 | the PIN + password pair, persistence |
| `LS/DuressWipe.java` | 77 | the action |
| `LS/LockSettingsService.java` | — | wiring: `:645`, `:811`, `:2769-2779`, `:4488-4510` |
| `LS/LockSettingsShellCommand.java` | — | `set-duress-credentials` (`:82`, `:224`, `:417`) |
| `core/java/com/android/internal/widget/ILockSettings.aidl:118-119` | — | binder surface |
| `core/java/com/android/internal/widget/LockPatternUtils.java:2231-2255` | — | client wrappers + validation rule |
| `packages_apps_Settings/…/security/DuressPassword{Activity,MainActivity,SetupActivity}.java` | — | Settings UI |

## Enrolment

- UI: `DuressPasswordSetupActivity.java:142` calls `LockPatternUtils.setDuressCredentials(owner, pin, password)`.
- Binder: `LockSettingsService.setDuressCredentials` (`:4491`) checks the write permission,
  delegates, and zeroizes all three credentials in `finally`.
- `DuressPasswordHelper.setDuressCredentials` (`:81`):
  - verifies the **owner's** (user 0) credential first (`checkOwnerCredential`, `:64`);
  - both a PIN and a password are always set together; passing both as "none" deletes the pair;
  - validation is `LockPatternUtils.validateDuressCredential` (`:2231`): minimum length 4,
    low complexity.
- Persistence: one hex string under key `duress_credentials` for `USER_SYSTEM`
  (`DuressCredentials.java:41-46`). Format: version byte, then for each credential a
  length-prefixed salt block and a length-prefixed stretched value (`DuressCredential.java:39-51`).
- Device-wide: there is one duress pair for the whole device, not one per user.

## Matching

`LockSettingsService.doVerifyCredential` (`:2769`) wraps the real verification:

```java
try {
    res = doVerifyCredentialInner(credential, lockDomain, userId, progressCallback, flags);
    return res;
} finally {
    duressPasswordHelper.onVerifyCredentialResult(res, credential);
}
```

Consequences worth remembering:

1. **Every credential prompt is covered**, not just the lockscreen: all 7 call sites of
   `doVerifyCredential` (`:1812`, `:2206`, `:2694`, `:2719`, `:2939`, `:2952`, `:4047`) pass
   through the `finally`. Any user's prompt counts, since the pair is device-wide. That includes
   the fingerprint second-factor PIN (`Secondary` domain, see doc 04 Q4). See *Who reaches the
   hook* below.
2. **The primary credential wins.** `onVerifyCredentialResult` returns immediately when the
   real verification matched (`DuressPasswordHelper.java:38`). The duress check only runs on
   a non-match, and also when the inner call threw (`res == null`).
3. **Asynchronous.** The credential is duplicated and checked on a dedicated `HandlerThread`
   (`:46-62`), because stretching is slow. The caller gets its ordinary "wrong credential"
   response first; the copy is zeroized after the check.
4. **Type-matched.** A typed PIN is compared only with the duress PIN, a password only with
   the duress password; patterns never match (`:108-118`).

## Who reaches the hook (B2, verified 2026-10-08)

Paths relative to the full tree; `LSS` = `LockSettingsService.java`, `LPU` =
`frameworks/base/core/java/com/android/internal/widget/LockPatternUtils.java`.

| LSS entry | Domain / flags | Reached from |
|---|---|---|
| `checkCredential` binder `:2689-2694` | caller's domain, flags 0 | keyguard PIN/password bouncer (`packages/SystemUI/src/com/android/keyguard/KeyguardAbsKeyInputViewController.java:300`; domain `Secondary` for `BiometricSecondFactorPin`, `:120-124`), pattern bouncer (`KeyguardPatternViewController.java:145`), compose bouncer (`AuthenticationRepository.kt:392`), Settings `ConfirmLockPassword.java:715` / `ConfirmLockPattern`, `cmd lock_settings` (`LockSettingsShellCommand.java:386`), duress enrolment's owner check (`DuressPasswordHelper.java:72`) |
| `verifyCredential` binder `:2709-2719` (needs keyguard/lockscreen permission, `:2711`) | caller's | BiometricPrompt credential fallback (`CredentialInteractor.kt:85-95`, `VERIFY_FLAG_REQUEST_GK_PW_HANDLE`), Settings confirm when a GK handle is wanted (`ConfirmLockPassword.java:706-708`), ChooseLock save (`SaveAndFinishWorker.java:144`, only flags ≠ 0), `KeyguardManager.checkLock` TestApi (`KeyguardManager.java:1283`) |
| in-process `verifyCredential` `:2702` | Primary | `RecoverableKeyStoreManager.java:1081` |
| `verifyTiedProfileChallenge` → `:2939` (parent) + `:2952` (profile's random password) | Primary | work-profile challenge (LPU `:615`, BiometricPrompt fallback) |
| `tryUnlockWithCachedUnifiedChallenge` `:4041-4047` | Primary, 0 | `UserManagerService.java:2268` via LPU `:2163` |
| `unlockChildProfile` `:1809-1812` | Primary, 0 | system only, during parent unlock (`:1882`) |
| `setLockCredential` `:2206` | Primary, 0 | re-verifies the parent for tied profiles when Settings saves a credential |

Two call sites check random, system-generated profile passwords (`:1812`, `:2952`), so they can
never match an alternate. Every other site carries something a person typed.

## The action

`DuressWipe.run` (`DuressWipe.java:19`):

1. start eSIM wipe on a separate thread (`EuiccWipe.run(…, RESET_FLAG_IS_FOR_DURESS_WIPE)`);
2. `RecoverySystemService.deleteSecrets()` (`RecoverySystemService.java:556`):
   - `AndroidKeyStoreMaintenance.deleteAllKeys()`,
   - `ISecretkeeper.deleteAll()` if present,
   - `ExtendedWipeWithoutReboot.run()` (GrapheneOS addition): triggers secure-element erase
     via `sys.erase_secure_element`, then asks vold to destroy every user's storage keys,
     the system storage key and the `/data` metadata key;
3. wait up to 3 s for the eSIM thread;
4. `PowerManagerService.lowLevelShutdown(null)` → `sys.powerctl=shutdown,` (`PowerManagerService.java:5105`).

No reboot into recovery is needed: the keys are gone before power-off.

## Changes since 16 (B3, 2026-10-09)

Compared with GrapheneOS tag `2026061602`, the last Android 16 release (frameworks_base
`7d409cf5`, Settings `f96d94cb`). `platform_frameworks_base` has no `16` branch any more.
Reference clones are in `/mnt/flash/scratch/grapheneos/ref-16/` on n5.

- **The duress code itself is byte-identical.** That covers `DuressPasswordHelper`,
  `DuressCredential(s)`, `DuressWipe`, `ExtendedWipeWithoutReboot`, the body of
  `deleteSecrets`, `tests/DuressPasswordTest`, `LockDomain`, and the Settings
  `DuressPassword*Activity`. The hook is the same `try/finally` (16 `LockSettingsService.java:2554-2564`,
  17 `:2769-2779`). GrapheneOS rebases the feature as four commits that keep their 2024 author
  dates.
- The changes are in the surrounding code:
  - `checkCredential` now returns `VerifyCredentialResponse` instead of a boolean plus an
    exception (`LockPatternUtils.java:580`). The shell command's `--old` check was moved to that API.
  - The software rate limiter used to sit behind a flag and is now always on.
  - The default scrypt `logN` is now always 9 (in 16 it was 11 without
    `scryptParameterChange`). Each record stores its own `logN`, so duress values enrolled on 16
    still verify on 17.
  - `doVerifyCredentialInner` now zeroizes the synthetic password in its own `finally`. An
    action in the outer hook can't see it, which is fine for actions that only reduce access.
  - In Settings, the duress screen is also reachable from Safety Center
    (`DuressPasswordPrefController`, `safety_center_device_unlock_subpage.xml:85`).
- For patches: anything touching the duress files should carry over between releases
  unchanged; callers of `checkCredential` need the 17 API.
- Applies to both releases: `checkOwnerCredential` itself goes through `checkCredential`
  (`DuressPasswordHelper.java:72`). So a credential typed into the owner-confirmation field
  during duress setup is also checked against the duress values, and typing the duress PIN there
  wipes the device. The same will hold for the `REBOOT_BFU` enrolment screen.

## Properties to preserve in any extension

- P1. Primary credential always takes precedence over alternates.
- P2. Alternates are checked for every prompt that reaches `doVerifyCredential`.
- P3. The caller cannot distinguish "wrong" from "alternate matched" by the binder result.
- P4. Enrolment requires the owner credential.
- P5. Plaintext credential copies are zeroized on every path.

## Observations for design work

- The stored duress value is checked in software by `system_server`; it is not bound to a
  Weaver slot. That is acceptable for an action whose only effect is destruction. It would
  **not** be acceptable for a credential that grants access to anything (see doc 04, D2).
- Timing: the non-match response returns before the alternate check finishes, so the action
  starts a moment after the "wrong PIN" UI. An extension must not make the *response* time
  depend on whether alternates are enrolled.
- `DuressWipe.sleep5sBeforePoweroff` is a test hook guarded by the owner credential.
