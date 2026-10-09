# 04 — Alternate credentials → actions

Design draft. Generalises the duress hook (doc 03) from "one alternate pair, one action"
to "a small table of alternate credentials, each bound to an action".

Status: **proposal, nothing implemented.** Revision references: frameworks_base `84183aff`.

## Motivation

Today there are exactly two outcomes besides "wrong": unlock, and wipe. Upstream has an open
discussion about a third: a credential that returns the device to the Before-First-Unlock
state ([os-issue-tracker #8505](https://github.com/GrapheneOS/os-issue-tracker/issues/8505)
"Feature: BFU PIN", open since 2026-08-11, verified 2026-10-08; no team reply yet).
are in memory; today the owner reaches it with a reboot or the auto-reboot timer.

A dispatch table makes that a small addition instead of a second copy of the duress code.

### Maintainer positions (checked 2026-10-08)

Quotes are thestinger's.

- **Only a reboot reaches BFU.** Clearing memory without one is "fundamentally not possible"
  ([#4481](https://github.com/GrapheneOS/os-issue-tracker/issues/4481)). A request that
  specifies anything else "is not going to be accepted"
  ([#7207](https://github.com/GrapheneOS/os-issue-tracker/issues/7207)). So `REBOOT_BFU` has
  to be a real reboot (Q3 is only about which reboot call to use).
- **A reboot shortcut is welcome:**
  - "We'd rather add a shortcut for reboot instead of lockdown mode"
    ([#4612](https://github.com/GrapheneOS/os-issue-tracker/issues/4612)).
  - "There can be more complexity for duress PIN/password but not via fingerprints … it would
    make more sense just to have a better shortcut for rebooting"
    ([#6433](https://github.com/GrapheneOS/os-issue-tracker/issues/6433)).
  - The one counterpoint is about a power-button gesture, not a credential: "We wouldn't want to
    power off or reboot for something meant for duress"
    ([#4426](https://github.com/GrapheneOS/os-issue-tracker/issues/4426)).
- Multiple duress passwords:
  [#3839](https://github.com/GrapheneOS/os-issue-tracker/issues/3839) is open, but the
  delegated-wipe use case was called "very niche". That bears on Q1 (table vs. a fixed second pair).
- **A credential that switches to a secondary user was rejected**
  ([#8675](https://github.com/GrapheneOS/os-issue-tracker/issues/8675) closed as a duplicate,
  [#8409](https://github.com/GrapheneOS/os-issue-tracker/issues/8409),
  [#8412](https://github.com/GrapheneOS/os-issue-tracker/issues/8412)). "We aren't going to add
  features which depend on adversaries not knowing about them." This confirms that roadmap
  Stage 4 stays fork-only.
- Per-profile wipe "is something we could implement" but cannot be deniable
  ([#3598](https://github.com/GrapheneOS/os-issue-tracker/issues/3598),
  [#4497](https://github.com/GrapheneOS/os-issue-tracker/issues/4497)). The duress credential is
  global ([#7825](https://github.com/GrapheneOS/os-issue-tracker/issues/7825)).

## Actions considered

| Id | Action | Effect | Reversible | Stage |
|---|---|---|---|---|
| `WIPE` | existing duress | destroy all keys, power off | no | exists |
| `REBOOT_BFU` | reboot immediately | all CE keys leave memory; device asks for credential again | yes | roadmap Stage 2 |
| `END_SESSIONS` | stop all secondary users, lock | secondary users' CE keys evicted, owner stays AFU | yes | optional, after Stage 3 |
| `ENTER_USER` | start another user's unlock | never a row in this table (D2); see roadmap Stages 3–4 | yes | roadmap Stages 3–4 |

`REBOOT_BFU` is the recommended first target: no new storage semantics, trivially testable,
and directly useful on its own.

## Proposed shape

```
LS/AlternateCredentials.java      table: {type, salt, stretched, actionId}, versioned blob
LS/AlternateCredentialHelper.java replaces DuressPasswordHelper; same hook point
LS/actions/WipeAction.java        = today's DuressWipe.run
LS/actions/RebootBfuAction.java   PowerManagerService.lowLevelReboot(...)
```

- Hook stays where it is: `finally` of `LockSettingsService.doVerifyCredential` (`:2769`).
- `onVerifyCredentialResult` keeps its contract: return at once when the primary matched;
  otherwise duplicate the credential, check on the background thread, zeroize.
- Storage: bump `DuressCredentials` `VERSION` (currently `0`, `DuressCredentials.java:69`) and
  append an action byte per entry; version 0 blobs load as `{pin→WIPE, password→WIPE}`.
- Binder surface: keep `setDuressCredentials` / `hasDuressCredentials` for compatibility; add
  a parallel pair for the new action instead of a generic "set table" call, so each action
  can be permission-checked and reasoned about separately.
- Settings: one extra screen modelled on `DuressPasswordSetupActivity`.

`RebootBfuAction` sketch:

```java
static void run() {
    // no key destruction; a plain reboot is what puts the device back into BFU
    PowerManagerService.lowLevelReboot("alt-credential");
}
```

`lowLevelReboot` is at `PowerManagerService.java:5119`; the duress path uses its sibling
`lowLevelShutdown` (`:5105`). Whether a low-level reboot (skipping the orderly shutdown
sequence) is appropriate here, versus `PowerManager.reboot`, is open question Q3.

## Design rules

- **D1. Precedence.** Primary credential first, then alternates in a fixed order with `WIPE`
  evaluated before anything else. Never let a reversible action shadow the wipe.
- **D2. Software-checked alternates may only trigger actions that reduce access.**
  The alternate table is verified by `system_server` from data on `/data`, with no hardware
  rate limit. `WIPE`, `REBOOT_BFU` and `END_SESSIONS` are safe under that rule: learning the
  alternate gives an attacker nothing but the ability to lock the owner out or erase the
  device. Anything that *grants* access (`ENTER_USER`) must go through the target user's
  normal hardware-backed verification instead — it cannot be a row in this table.
- **D3. Collisions rejected at enrolment.** An alternate must differ from every other
  alternate of the same type. It cannot be compared with primary credentials of other users
  (those can't be read), which is why D1 matters. Also re-check when the owner changes their
  primary credential: an alternate equal to the new primary becomes unreachable (P1 in doc 03),
  which should at least be surfaced in Settings.
- **D4. Same observable response.** The binder result and its timing for a non-matching
  credential must not depend on whether alternates exist or matched (P3 in doc 03).
- **D5. Opt-in, off by default, owner credential required to enrol** (P4).
- **D6. One alternate per (type, action).** Keeps the UI explainable and the stretch cost per
  failed attempt bounded: each enrolled alternate adds one scrypt evaluation to every wrong
  entry.

  Cost (B4, 2026-10-08). Duress values are stretched with the same `stretchLskf` the owner's
  credential uses (`DuressCredential.java:23-33` → `SyntheticPasswordManager.java:2244-2252`):
  scrypt N=2^9, r=2^3, p=2^1 (`:213-215`), 32-byte output, 512 KiB of memory. AOSP picked these
  to stay under ~50 ms on the slowest form factors (`:200-211`). On n5 (x86, one thread) one
  evaluation takes 1.4 ms; a phone's efficiency core will be several times slower. Matching is
  type-specific: a wrong PIN is stretched once per enrolled *PIN* alternate, never against the
  password ones (`DuressPasswordHelper.java:108-118`), plus one storage read
  (`DuressCredentials.maybeGet`).
  - With duress plus `REBOOT_BFU`, a wrong PIN costs two stretches, under ~100 ms worst case.
  - This runs on the background thread (`:46-62`), after the response has gone back to the
    caller. So it does not change what the user sees when they type a wrong PIN (D4). It only
    delays when an action starts.
  - Giving every alternate its own salt keeps the cost linear in the number of alternates. A
    shared salt would mean one stretch and N comparisons, but the stored values could then be
    compared with each other. Per-entry salts and the D6 limit are the simpler choice.

## Settings flow (B8, read 2026-10-08)

Today's duress screens (paths under `packages/apps/Settings/`):

- **Entry.** Preference `duress_password` on the Safety Center *Device unlock* subpage
  (`res/xml/safety_center_device_unlock_subpage.xml:84-88`). Its controller is
  `src/com/android/settings/safetycenter/ui/DuressPasswordPrefController.java:20-31`. It is
  shown to the system user only (`src/com/android/settings/ext/ExtSettingControllerHelper.java:28-30`).
- **Main screen** `DuressPasswordMainActivity`:
  - Gets the owner credential through `ChooseLockSettingsHelper` with `setReturnCredentials(true)` (`:74-79`).
  - Lists Add, or Update/Delete, depending on `hasDuressCredentials` (`:86-104`).
  - Passes the owner credential to setup in the intent (`:120-125`).
  - The shared base `DuressPasswordActivity` sets `FLAG_SECURE` (`:21`) and finishes when the screen is backgrounded, so the credential has to be re-entered (`:32-43`).
- **Setup screen** `DuressPasswordSetupActivity` (`res/layout/duress_password_setup.xml`):
  - A PIN pair and a password pair, both required (`:125-131`).
  - Validation is `validateDuressCredential`: length ≥ 4, LOW complexity, no device-policy input (`LockPatternUtils.java:2231-2236`).
  - A warning dialog on first add (`:161-168`), then `setDuressCredentials` (`:142`).
- **Server:** `DuressPasswordHelper.setDuressCredentials` (`:81-100`) checks the owner credential and validates. **It does no collision check**: a duress PIN equal to the owner's PIN is stored, and can never fire (P1).

Draft for a *Reboot PIN* screen:

1. Preference `reboot_pin` after `duress_password`, with a `RebootPinPrefController` copied
   from the duress controller (system user only).
2. `RebootPinMainActivity extends DuressPasswordActivity`; the base class is reused as is. The
   owner-credential step and action list are copied, using `has/deleteRebootCredential`.
3. `RebootPinSetupActivity` + `reboot_pin_setup.xml` with one PIN pair (D6). Validation is
   shared, ideally with `validateDuressCredential` renamed `validateAlternateCredential`.
4. Block enrolment when the owner has no screen lock. Today duress enrolment proceeds with a
   none credential (Main `:71-72`), and a reboot PIN is meaningless without a lock.
5. **Collision checks run in system_server, after the owner check:**
   - against the duress values: `DuressCredential.verify`, as at `DuressPasswordHelper.java:113-114`;
   - against the owner's Primary credential: compare with the owner credential just verified;
   - against the owner's Secondary PIN: verify against that domain.

   **Never probe through `checkCredential`/`verifyCredential`.** They run the duress `finally`,
   so a candidate equal to the duress PIN would wipe the device. Calling the inner path
   (`doVerifyCredentialInner`) skips the hook but is no better. Every verification goes
   through the software rate limiter (`LockSettingsService.java:2816`) and the LSKF protector,
   i.e. Weaver (`:2838`). So a non-colliding candidate — the normal case — would be recorded as
   a failed attempt against the owner's second-factor PIN, and kept as a "wrong guess"
   (`SoftwareRateLimiter.java:400`). **Resolution (B9):** don't probe. When second-factor
   unlock is enabled, the enrolment screen also asks for the owner's second-factor PIN, which
   is verified once (a match costs nothing). The candidate is then compared in memory with both
   owner credentials, and all copies are zeroized.
   Run the same checks in reverse in `setDuressCredentials`. A collision raises an error with
   a reason code, shown in Settings as a fixed localized message (`reboot_pin_error_collision`),
   not as `e.toString()` the way the duress errors are shown today.
6. New strings in `strings_ext.xml`: `reboot_pin_pref_title`, `reboot_pin_description`, the
   enter/confirm labels, the action and toast strings, and `reboot_pin_save_error` /
   `reboot_pin_delete_error` / `reboot_pin_error_collision`. Button strings are reused from
   `duress_pwd_*`.

## Test plan (`REBOOT_BFU`, roadmap Stage 2)

1. Emulator / Cuttlefish build of GrapheneOS 17 with the patch.
2. `cmd lock_settings` shell command extended next to `set-duress-credentials`
   (`LockSettingsShellCommand.java:417`) for scripted enrolment.
3. Cases: primary unlock unaffected; alternate at lockscreen → reboot; alternate at an in-app
   credential confirmation → reboot; alternate equal to duress rejected at enrolment; duress
   still wipes; version-0 blob upgrade; wrong credential timing with 0 / 1 / 2 alternates.
4. Tests (B6, checked 2026-10-08 in the full tree; paths relative to `frameworks/base/`):
   - **No unit test covers duress today.** Every locksettings unit test gets a bare Mockito
     mock from `MockInjector.getDuressPasswordHelper`
     (`services/tests/servicestests/src/com/android/server/locksettings/LockSettingsServiceTestable.java:186-191`).
     That is the hook a unit test would change to return a real helper, or a spy, wired to
     `MockSyntheticPasswordManager` (Weaver fake, `MockSyntheticPasswordManager.java:33-75`). The
     production injector is at `LockSettingsService.java:645-650`. The harness to copy is
     `BaseLockSettingsServiceTests.java:94` (`:211-230`). Run with
     `atest FrameworksServicesTests:com.android.server.locksettings`.
   - **End-to-end template:** GrapheneOS's host test `tests/DuressPasswordTest/`
     (`java_test_host` `DuressPasswordTest`, `atest DuressPasswordTest`). It enrols through
     `cmd lock_settings set-duress-credentials` (`DuressPasswordTest.java:75-79`), types the
     credential with `input text` (`:92`), and checks Weaver reads via `WeaverOpCapturer`
     output (`:59`). A `RebootBfuTest` should copy this test.

## Open questions

- Q1. Does upstream want a table, or a second hard-coded pair? Ask before building the table.
- Q2. Should `REBOOT_BFU` also fire for secondary users' prompts, as duress does?
- Q3. `lowLevelReboot` vs orderly reboot: speed against clean unmount.
- Q4. Interaction with the auto-reboot timer and with PIN scrambling / two-factor fingerprint
  unlock (the `Secondary` lock domain in `doVerifyCredentialInner`, `:2781`).
  **Partly answered (B5, 2026-10-08):**
  - `LockDomain {Primary, Secondary}` is defined in `core/java/com/android/internal/widget/LockDomain.java:17-18`.
    `Secondary` is the PIN asked for after a fingerprint match (`KeyguardSecurityModel.java:137-141`).
  - In `doVerifyCredentialInner`, `Secondary`:
    - rejects any flag (`:2787-2788`);
    - uses its own protector and its own rate-limiter identity (`:2814-2816`);
    - on a match, returns before keystore/CE unlock (`:3604-3615`). It only ever runs after first unlock.
  - **Duress fires for `Secondary` today.** The `finally` passes neither domain nor user, so typing
    the duress PIN at the second-factor prompt wipes the device. A `REBOOT_BFU` row beside it
    would also fire there, and that is probably wanted: the prompt appears exactly when someone is
    being forced to unlock a device that is already after first unlock. Restricting it to Primary
    would mean passing `lockDomain` into `onVerifyCredentialResult`.
  - A `Secondary` match returns before the alternate check (`DuressPasswordHelper.java:38`). So an
    alternate equal to the owner's second-factor PIN can never fire from that prompt. D3 needs
    the same enrolment-time check against the Secondary PIN. As with other users' credentials, it
    can't be read, so the check means submitting the candidate once.
  - The auto-reboot timer is independent of LSS: `services/core/java/com/android/server/policy/keyguard/AutoReboot.java:24-38`
    is driven by keyguard visibility (`KeyguardServiceDelegate.java:227`, `sys.auto_reboot_ctl`).
    A failed attempt keeps the keyguard up, so there is no race; `REBOOT_BFU` only comes earlier.
  - Still open: PIN scrambling (UI only, presumably no effect).
- Q5. Should a matched reversible alternate count toward the failed-attempt counter?
