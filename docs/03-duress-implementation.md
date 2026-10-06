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

1. **Every credential prompt is covered**, not just the lockscreen: `checkCredential` (`:2689`),
   `verifyCredential` (`:2709`) and the internal callers at `:1812` and `:2206` all go through
   `doVerifyCredential`. Any user's prompt counts, since the pair is device-wide.
2. **The primary credential wins.** `onVerifyCredentialResult` returns immediately when the
   real verification matched (`DuressPasswordHelper.java:38`). The duress check only runs on
   a non-match, and also when the inner call threw (`res == null`).
3. **Asynchronous.** The credential is duplicated and checked on a dedicated `HandlerThread`
   (`:46-62`), because stretching is slow. The caller gets its ordinary "wrong credential"
   response first; the copy is zeroized after the check.
4. **Type-matched.** A typed PIN is compared only with the duress PIN, a password only with
   the duress password; patterns never match (`:108-118`).

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
