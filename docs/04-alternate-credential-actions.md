# 04 — Alternate credentials → actions

Design draft. Generalises the duress hook (doc 03) from "one alternate pair, one action"
to "a small table of alternate credentials, each bound to an action".

Status: **`REBOOT_BFU` implemented as a fork PoC** (roadmap Stage 2, see *Decisions*); the
table and the other actions are still a proposal. Revision references: frameworks_base `84183aff`.

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

**Built 2026-10-11** (Settings fork `envs-17`), following the draft with these differences:

- Names: preference `reboot_credential`, `RebootCredentialPrefController`,
  `RebootCredentialMainActivity`, `RebootCredentialSetupActivity`,
  `res/layout/reboot_credential_setup.xml`, strings `reboot_cred_*`.
- One credential, PIN **or** password (a radio choice), matching the service (*Decisions*,
  one credential). The second-factor PIN field shows only when the owner has one.
- Add needs a screen lock; Delete is offered without one, and is the only action for a record
  that can't be read (`reboot_cred_corrupt`).
- Collision errors map the service's fixed `collision: …` messages to strings; the duress
  screen maps `collision: reboot credential` the same way.
- The description says in general terms when the reboot credential is deleted automatically.
  Telling the owner *that* it happened needs a stored reason from the service: not built.
- Cleanup: the shared base class still runs its delayed `System.gc()`; on top of that the
  setup screen zeroizes the credentials it creates in a `finally`, clears its fields when it
  goes away and keeps them out of the saved state. The owner credential travels in the intent,
  as in the duress screens, and is removed from it when setup ends; unlike the duress screen,
  it isn't kept in the saved instance state (a recreated screen asks again), and the main
  screen zeroizes it when it finishes. Strings that Android copies internally can't be wiped.
- Both screens finish at once for anyone but the system user (the service always checks user
  0's credential). Status errors other than a corrupt record are shown as errors, not as
  corruption; no screen lock and no record shows "Set a screen lock first".

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

## Weaver-backed alternates (design draft, 2026-10-11, reviewed twice)

Follows the doc 00 decision of 2026-10-11: the reboot credential gets hardware throttling
instead of an offline-checkable scrypt record. Paths are under `frameworks/base/` unless
they start with `hardware/`; Java files without a directory are in
`services/core/java/com/android/server/locksettings/`. Not implemented.

**What Weaver gives** (`hardware/interfaces/weaver/aidl/android/hardware/weaver/IWeaver.aidl`):
an array of slots, each a key and a value; `read(slot, key)` returns the value only for the
right key. Throttling is per slot (`:65`): a read past a timeout first counts a failure, a
correct key resets that slot's count (`:90`), a wrong one returns the next timeout (`:95`),
and a read during a timeout tests nothing (`:79`). `write` replaces key and value and leaves
no timeout (`:116-120`); whether it also clears the failure count is not stated. The slot
count comes from `getConfig().slots`: at least 64 recommended (`:33`), 16 in the reference
service (`hardware/interfaces/weaver/aidl/default/Weaver.cpp:31`, volatile, never throttles).

**Slot budget.** The Pixel 8 Pro (Titan M2) has 64 slots, 16-byte keys and values (measured
2026-10-12, see below); 17 logs the count at debug level only
(`SyntheticPasswordManager.java:733`). Other devices may have fewer; the reference service
has 16. Slots in
use: one per primary LSKF protector of every user, with or without a lock
(`SyntheticPasswordManager.java:1137-1146`; `config_disableWeaverOnUnsecuredUsers` is false,
`core/res/res/values/config.xml:1535`); a second one for the moment a credential change
creates the new protector before destroying the old; one per activated escrow token
(`SyntheticPasswordManager.java:1491`). FRP points at the owner's existing slot and is only
held until provisioning (`:1097-1102`). Secondary protectors stay out of Weaver because of slot
pressure (`:582-584`, `false` at `LockSettingsService.java:632`). Running out throws
`"Run out of weaver slots."` (`SyntheticPasswordManager.java:1109`), which breaks a credential
change or user creation.

- W1. One reboot credential, owner only: one slot.
- W2. Enrolment is refused unless, after it, free slots ≥ (existing users and profiles + 1
  for a change in progress + activated tokens + a fixed headroom of 2). Reserving for every
  user that *could* still be created (base cap 32, `config.xml:3288`) never fits in 16 slots,
  so the rule counts what exists. Creating a user later can still fail; then the reboot
  credential has to be deleted first. If the measured count leaves no room on the test
  device, doc 00 option (a) applies.

**Slot ownership (the critical part).** `PasswordSlotManager` rebuilds its map from
`getUsedWeaverSlots()` on every Weaver start (`SyntheticPasswordManager.java:734`,
`PasswordSlotManager.java:76-90`), and that only lists protector files
(`SyntheticPasswordManager.java:1077`). A slot only passed to `markSlotInUse`
(`PasswordSlotManager.java:105`) is forgotten after the next `system_server` start and handed
to the next protector or escrow token; the next alternate write would then destroy that
user's key. `destroyWeaverSlot` erases a slot that no listed protector holds
(`SyntheticPasswordManager.java:1047-1064`), so it would also erase the alternate's slot.

- W3. A reservation file next to the reboot record holds the slot id and a generation, with
  a state (pending, active, deleting). `getUsedWeaverSlots` includes it, and a bad record must
  not throw there (it runs during Weaver start). Allocation, reservation, Weaver write and
  free all run under `mSpManager`, like every current caller of `getNextAvailableWeaverSlot`.
  Order: reserve (pending, fsync), write, mark active. On start, a pending reservation is
  erased and dropped; a deleting one is erased again. Free only after the erase succeeded.
  Every later write first rechecks slot and generation.
- W4. Every delete path frees the slot through W3, not just the database row: delete from
  Settings or the shell, owner lock removal, and "new owner credential equals the reboot
  credential" in `onLockCredentialChanged` (today all call `RebootCredential.delete`).
  Factory reset wipes the reservation with `/data`; the chip slot is reused later, as with an
  orphaned protector today.

**Record and check.**

- W5. Weaver key: same shape as `stretchedLskfToWeaverKey` (`SyntheticPasswordManager.java:2259`,
  personalized hash cut to `keySize`) with its own personalization string. Value: random,
  not stored. Record: a new version with slot, generation, salt, scrypt parameters and the
  Weaver key wrapped (authenticated) under a key derived from the owner's synthetic password.
  No hash. A version-0 record (today's scrypt hash) is migrated at the next owner unlock and
  the hash deleted in the same write; until then the offline verifier is still on disk, and
  copies in old backups stay guessable.
- W6. When the slot is read: only for user 0, primary domain, after the owner's own Weaver
  read returned a real wrong-key result. Not for software rate limiting, duplicate guesses,
  too-short input or a Weaver `THROTTLE` (the rate limiter answers before the owner read,
  `LockSettingsService.java:2818`, and the hook sees every result, `:2779`), not for other users, not for the second factor,
  and not after a duress match (duress stays first). Then the reboot slot's failures follow
  the owner's: no guess reaches it that the owner slot didn't count.
- W7. Accepted limitation: during the owner's lockout the lock screen tries nothing, so the
  reboot credential doesn't work then either; the scrypt version did. "Reboot on any wrong
  guess while throttled" is rejected: it would give every wrong guess the action.
- W8. After a successful owner unlock with the primary credential (not a token, not reboot
  escrow), the slot is rewritten with the same key and a new value, then read once with that
  key (a correct read resets the count, `IWeaver.aidl:90`, in case `write` doesn't). The SP
  only exists inside the verify call and is zeroized before it returns
  (`LockSettingsService.java:2840`, `:2880-2882`), so the hook sits in the owner-primary
  success branch: unwrap the Weaver key there, zeroize the SP, queue the write. Rewrite and
  every alternate read run on one queue (the helper's background thread); a read checks the
  generation and the success counter before touching the chip, so a guess queued before the
  unlock is dropped instead of undoing the rewrite. No record update on this path, so a crash
  after the write leaves a working slot. A failed rewrite leaves the credential throttled,
  never fails the owner unlock. Lock order: never `alternatesLock` then `mSpManager`.
- W9. Collision checks (enrolment, duress enrolment, owner credential change) compare the
  candidate's derived Weaver key in memory with the unwrapped one, which needs the owner's
  SP: enrolment uses an internal verify that hands back the SP, `checkCredential` can't. The
  owner change keeps the SP (`LockSettingsService.java:3651`), so the wrap survives it.
- W10. Leaks. Debug builds with verbose logging print Weaver keys and values
  (`WeaverOpCapturer.java:16`, `:66-69`); the alternate path must not go through it. Failed
  reads log the slot (`SyntheticPasswordManager.java:845-855`); the alternate uses a quiet
  read. The extra read stays off the binder thread, as the scrypt check is today; timing of
  later requests and chip contention still show that an alternate exists. Not hidden in this
  stage; the same problem holds Stage 4.
- W11. Scope: the reboot credential only. GrapheneOS's duress credentials stay as upstream
  stores them.

**Testing.** `services/tests/servicestests/src/com/android/server/locksettings/MockWeaverService.java`
has 8 slots (`:18`) and per-slot counters (`:73-76`), but never returns a timeout, resets the
count on every write (`:55`) and only injects one-shot responses (`:119`). It gets per-slot
timeouts, count-before-compare and a switch for whether write clears the count; then W3-W9 are
unit tests, including a restart between reserve and write. On the Pixel 8 Pro (Stage 6, own
userdebug build): `getConfig()` slots and sizes; the timeout table; five wrong reads, write,
`getTimeout`, one wrong read (does write clear the count); counter and timeout across a
reboot; time of one read against two.

**Measured on the Pixel 8 Pro, 2026-10-12** (our 17 userdebug build, bootloader unlocked;
raw `IWeaver` calls as root on spare slots 61-63, owner on slot 0):

| Question | Result |
|---|---|
| `getConfig()` | 64 slots, key 16 B, value 16 B |
| Timeout table | failures 1-4: none; 5th: 60 s; 6th: 300 s |
| Read during a timeout | `THROTTLE`, not counted |
| Same wrong key again | not counted (7 identical wrong keys, no timeout) |
| `write` with failures pending | clears the count (one wrong read after it: no timeout) |
| Correct read | clears the count |
| Reboot during a 60 s timeout | timeout kept, keeps counting down (32 s left 36 s later) |

So W2 has room on this device, and the W8 rewrite clears an alternate's count here. The
duplicate-key rule means the chip, like `SoftwareRateLimiter`, does not count repeats; a
probe must still skip rate-limited and duplicate guesses (W6). Not measured yet: read
latency (one read against two) and behaviour with the bootloader locked.

## A/B/duress layout (design draft, 2026-10-11, reviewed twice; first build 2026-10-12)

Doc 00 goal 6. First build below under *Built 2026-10-12*. "Alternates" means the duress and reboot credentials. Paths:
`F` = `frameworks/base`, `S` = `packages/apps/Settings/src/com/android/settings`,
`U` = `F/packages/SystemUI/src`, `W` = `packages/apps/SetupWizard2`; Java files without a
directory are in `F/services/core/java/com/android/server/locksettings/`.

**Roles.** A = user 0, the everyday profile. B = a full secondary user, the protected space,
recorded as the *protected user id* in device-protected storage. Duress stays device-wide.
A must be user 0: user 0 can't be stopped (`UserController.java:1323-1324`), so the profile
that stays in memory is the everyday one. Nothing here is deniable (doc 00 *Non-goals*).

**Authority is the protected user id, not the admin flag.** User 0 stays an admin: revoking
it is refused (`F/services/core/java/com/android/server/pm/UserManagerService.java:2645`), so
"any admin's credential" would let A set the alternates. The alternates don't need B to be
an admin; managing users from B does (Settings gates it on the admin flag), so B is an admin
too, and the protected user id, not the flag, decides who may touch the alternates.

- The alternate APIs (`LockSettingsService.java:4495`, `:4510`, `:4520`, `:4536`) check the
  caller's own credential against the protected user id, taken from the caller identity before
  it is cleared, never from a supplied user id. Today they check user 0
  (`DuressPasswordHelper.java:198`, `:275`) and follow user 0's credential changes (`:152`,
  `:167`); both move to B.
- The reboot credential's Weaver design (section above) follows B: its key is wrapped under
  B's synthetic password, collision checks need B's, and the slot is rewritten after B's
  successful unlock (W5, W8, W9 with B for "owner").
- User restrictions on A are set by the system at provisioning, not by B:
  `no_remove_user` on user 0 (checked for the caller, `UserManagerService.java:7119`; the bypass
  paths at `:7191` audited), and B's `no_run_in_background` can't be cleared from A. Setting
  restrictions needs `MANAGE_USERS` (`:4070`), so they are written by a privileged component.
  Uninstall for all users is hidden and refused in A (`S/applications/appinfo/AppInfoDashboardFragment.java:595`,
  `F/services/core/java/com/android/server/pm/DeletePackageHelper.java:783`).
- Nothing in the layout provisions a token that could reset A's credential, so B can't reset
  A's PIN (token resets exist in general, `LockSettingsService.java:3932`). A forgotten A PIN
  is a reset, as today.

**Credential lengths (owner decision 2026-10-11).** All four are PINs of 6 digits or more
(A, B, duress, reboot); no length ranges. A disjoint-length split was considered (A 6 digits,
the others 8 or more): it removed the enrolment oracle and most Weaver coupling but made every
non-A PIN long, and the owner preferred 6-digit PINs throughout. A and B must be PINs while
the layout is on; the rule is enforced in `LockSettingsService` for every credential write
(`:2169`, `:2269`, `:3932`), not only in Settings (`S/password/ChooseLockGeneric.java`,
`ChooseLockPassword.java`), including the second-factor PIN
(`ChooseBiometricSecondFactorPin.java`). The validation ceiling is 128
(`F/core/java/android/app/admin/DevicePolicyManager.java:3950`).

- Accepted: changing A's PIN inside A is checked against B and the alternates, and a refusal
  tells A's holder that the PIN is taken. Checking against B or the reboot credential is a
  Weaver read on their slot (costs a failure, throttled); checking against duress is a scrypt
  compare and not throttled. Refusals in A's change-PIN screen therefore count as wrong
  guesses for a delay, as at the lock screen. The refusal text is the generic "choose a
  different PIN".
- Auto-confirm submits at the selected user's stored PIN length
  (`U/com/android/keyguard/KeyguardPinViewController.java:91`, `:117`). It is offered only while
  every PIN of the layout has A's length; otherwise it is off for both users, and the pad shows
  an OK key, as stock Android does with auto-confirm off. Stored `pinLength` is refreshed when
  it is turned off (`SyntheticPasswordManager.java:1253`, `:1766`).
- In-app prompts in A (confirm credential, second factor) don't dispatch: another PIN there is
  a wrong A guess, and still reaches the duress check as today.

**Lock screen (Stage 4).** One PIN pad, no user switcher.

- Order: A, then duress, then B, then reboot. A wrong A guess therefore also costs B's and
  the reboot slot one failure each, and every B entry costs A's slot one; each slot's count is
  cleared by its own next correct unlock (W8 for the reboot slot). An attacker's guesses throttle
  all three slots together, so each target gets the same number of guesses as a single PIN
  would. A target whose slot is in timeout is skipped, not allowed to block the others. Trying
  the last-used user first (Stage 4c) would cut A's failures from B entries. Measured on the
  Pixel: the timeout table and whether these coupled counts stay usable in daily use.
- Per-target admission happens after submission and before that target's software limiter or
  Weaver read (the limiter doesn't know about targets, `SoftwareRateLimiter.java:211`).
- Lockout is per target: today a timeout disables the whole entry field and verification
  stops (`U/com/android/keyguard/KeyguardAbsKeyInputViewController.java:174`, `:277`; newer
  path `U/com/android/systemui/authentication/data/repository/AuthenticationRepository.kt:360`,
  `:386`). The pad stays usable; a target in timeout refuses its own group only. Duress stays
  usable during any target's lockout.
- A PIN that matches nobody shows the usual "Wrong PIN". A successful B or reboot entry is
  not reported to A's failure counters in SystemUI (`KeyguardAbsKeyInputViewController.java:255`
  reports every failure for the selected user today).
- Dispatch is one privileged operation in `LockSettingsService`, not an extra
  `checkCredential` from SystemUI: a successful check already starts the user's unlock
  (`LockSettingsService.java:2862`), and the keyguard dismisses only for the selected user
  (`KeyguardAbsKeyInputViewController.java:209`, `:308`). The operation authenticates its
  caller, finishes the duress check first, returns target, result and timeout, then SystemUI
  switches, waits for the switch to finish and dismisses for that user only. Cancel, screen
  off and a competing switch must not leave an unintended user unlocked.
- Leaving B (lock or End session) returns to A's lock screen. Eviction is asynchronous and is
  skipped if B restarts first (`UserController.java:1709`), so re-entering B waits until the
  previous stop has locked B's key.

**After a reboot (Stage 5, now required).** B's PIN opens B while A stays locked. On top of the
emulator patches this needs `allow_user_switching_when_system_user_locked`, default 0
(`UserManagerService.java:3365`), and hardware tests of B's first boot, storage, media,
backup, telephony, Bluetooth, Wi-Fi, notifications, then A's unlock and an update reboot. The
protected user id lives in DE storage and is checked against user-id reuse.

**Biometrics.** A only. B can't enrol and the keyguard doesn't offer them for B: hiding
enrolment isn't enough (`U/com/android/keyguard/KeyguardUpdateMonitor.java:3238`, `:3335`).

**Kept out of A's screens** (each also refused server-side where it acts):

| Surface | Where |
|---|---|
| Users screen, its search entry and direct access | `S/users/MultiUserPreferenceController.java:35`, `UserSettings.java:2000`, `UserDetailsSettings.java` |
| Duress and reboot screens | `S/safetycenter/ui/DuressPasswordPrefController.java:20`, `RebootCredentialPrefController.java:20`, the `S/security/*MainActivity`/`*SetupActivity` entries; not via the shared `S/ext/ExtSettingControllerHelper.java:28` |
| User switcher on keyguard, QS, shade | `U/com/android/systemui/user/domain/interactor/UserSwitcherInteractor.kt:129`, `user/data/repository/UserSwitcherRepository.kt:144`, `qs/footer/ui/viewmodel/FooterActionsViewModel.kt:321`, `U/com/android/keyguard/KeyguardSecurityContainer.java` |
| Power-menu users (End session stays for B) | `U/com/android/systemui/globalactions/GlobalActionsDialogLite.java:1568` |
| B's name and icon in the switch transition | `F/services/core/java/com/android/server/am/UserSwitchingDialog.java:92` |
| Storage breakdown | `S/deviceinfo/storage/NonCurrentUserController.java:74`, `StorageAsyncLoader.java:82`, `UserIconLoader.java:69` |
| B's notifications forwarded to A | `F/services/core/java/com/android/server/notification/NotificationManagerService.java:11221`, `:11237` |
| Running services of other users | `S/applications/RunningState.java:874`, `:1243` |

Accounts already stay per profile group (`S/accounts/AccountPreferenceController.java:201`,
`:297`); battery entries of other users are filtered (`S/fuelgauge/batteryusage/DataProcessor.java:666`,
`:1567`), to be checked on every screen.

**Still visible to A's holder** with all of the above: storage and battery totals, shared app
versions and updates, device-wide radios, networks and VPN, the delay of a user switch, the
timing of a wrong PIN (several Weaver reads) and lockouts after B entries, the OK key when
auto-confirm is off, refusals in the change-PIN screen, apps that count users.
"Plain Android" means how A looks, not that nothing changed.

**Duress.** GrapheneOS sets a duress PIN and a duress password together so every prompt type
can wipe. Setup asks for both and keeps it that way.

**Setup** (`W`). Add a step right after `SecurityActivity`
(`W/java/app/grapheneos/setupwizard/action/SetupWizard.kt:30`). The current security step
launches biometric enrolment (`W/java/app/grapheneos/setupwizard/action/SecurityActions.kt:19`),
which can leave a credential the layout doesn't allow, so the layout is chosen first:

1. "Protected space?" yes or no. No: stock setup, no layout, nothing hidden.
2. A's 6-digit PIN (then fingerprints, for A).
3. B's PIN, duress PIN and password, optional reboot PIN, checked against each other.
4. A privileged provisioning service (SetupWizard2 has no user or credential permissions,
   `W/AndroidManifest.xml:7`, `W/etc/permissions/app.grapheneos.setupwizard.xml:4`) creates B
   as `USER_TYPE_FULL_SECONDARY` (`F/core/java/android/os/UserManager.java:4595`), sets
   `no_run_in_background` and B's PIN (`F/core/java/com/android/internal/widget/LockPatternUtils.java:889`),
   records the protected user id, enrols the alternates under B's authority and sets A's
   restrictions. The layout counts as on only when all of it succeeded; an interrupted run is
   resumed or rolled back.
5. Setup ends in A. B's own setup runs at its first unlock and offers no lock or user step
   (its security step already skips when a lock exists, `W/java/app/grapheneos/setupwizard/view/activity/SecurityActivity.kt:18`).

**Measure on the Pixel 8 Pro** besides the Weaver list: pad behaviour during a lockout;
maximum PIN length the keyguard accepts; time of a short against a long wrong PIN; whether
`createUser` and `setLockCredential` work before provisioning ends; whether `no_remove_user` on
user 0 can be cleared from A's Settings; B-first boot; storage and battery screens with two
users; B's CE files after a stop.

**Built 2026-10-12** (`F` envs-17 `4fabd4a924e4`, `ea63797e97d9`, `a72acdcbf1b2`; Settings
`13375d0bd60`, `3e537a7f8a7`; SetupWizard2 local branch `envs-17` `a44f589`). Tested on the
emulator (`tests/results/2026-10-12-layout-T3.md`), reviewed once with two reviewers; the
fixes from that review are in.

- Authority: `setAlternatesAuthority` (trusted callers only) moves duress and reboot to a
  full user with a lock; the binder calls act for the caller's own user; the authority id is
  hidden from other users (they get `USER_NULL`); the stored keys can't be read or written
  through the generic calls.
- Dispatch: `LockSettingsService.dispatchCredential` (user 0 callers with the keyguard
  permission) checks user 0, then the protected user, then runs the duress and reboot hook
  once for user 0. It returns the shorter of the two lockouts. SystemUI calls it from user
  0's primary pad (`KeyguardAbsKeyInputViewController`); on a protected-user match it marks
  that user in `KeyguardUpdateMonitor` and switches, and the protected user's bouncer then
  completes through `showNextSecurityScreenOrFinish` (SIM, secure lock device and admin
  steps still apply). A cancelled check that already matched still switches. On user 0's pad
  a lockout shows its message but doesn't disable input, so duress stays enterable.
- Leaving B: screen off while a non-zero user is in front switches back to user 0
  (`KeyguardViewMediator.onStartedGoingToSleep`); B can't run in the background, so it stops.
- Setup: `provisionProtectedSpace` (user 0's system UID before provisioning, or the shell)
  checks lengths and owner collisions, verifies A's PIN, creates B as a full secondary user,
  sets `no_run_in_background` and B's PIN, makes B the authority, enrols duress and the
  optional reboot PIN under B, locks B's storage, then sets `no_remove_user` on user 0,
  `user_switcher_enabled=0` and `allow_user_switching_when_system_user_locked=1`. Any failure
  removes B and the alternates and restores the settings. UI: Settings
  `ProtectedSpaceSetupActivity` (action `com.android.settings.SETUP_PROTECTED_SPACE`),
  launched by SetupWizard2 right after the screen lock step when A has a lock.
- Hidden in A: every user switcher (via `user_switcher_enabled=0`; switching itself only
  checks `no_user_switch`, `UserManagerService.java:3357`), the Users entry and pages, other
  users in the storage breakdown. Biometric settings are off in B.

Not done yet: the reboot PIN is still the scrypt record (Weaver section above); the 6-digit
rule is checked at setup only, not on later changes; auto-confirm length; notifications,
running services and the user-switch dialog's name and icon (table above); B is not an
admin; SystemUI unit tests for the keyguard classes are not updated. Observed: every wrong
entry on user 0's pad counts for A and B, so six wrong PINs lock both (as designed under
*Lock screen*), and the lockout survives a reboot.

**On the Pixel 8 Pro, 2026-10-12** (build `2026101212`, `tests/results/2026-10-12-layout-T5.md`):
setup by hand, B by its PIN, screen off in B with A unlocked and with A before first unlock,
B first after a reboot all passed. B stops within a second of screen off and its key is
evicted. Found: B's red preset was gone after B's own setup ran, so B looked like A; the
owner's PIN was asked again right after the lock step; the duress password had no
explanation and couldn't be skipped; the Security summary in A still listed the duress entry
that A no longer shows. Every wrong entry runs Weaver reads on A's and B's slots and counts
for both users; B's count only resets when B is opened, so A's typos add up on B (one free
read per typo up to four, then the hardware lockouts). A keypad flicker when B opens is not
explained yet: the bouncer is a secure surface and the setup run predates the captured logs.
Fixed in build `2026101218` (`F` `32a53a59c590`, Settings `bf7c48583b8`, `6032943a6eb`, `8244972324b`,
SetupWizard2 `9738860`); decisions below.

## Decisions

- **2026-10-10, storage: a second fixed slot, not a table (Q1 for the fork).** The reboot
  credential is one `DuressCredential` (salt + stretched value) under its own storage key
  `reboot_credential` (`RebootCredential.java`); the duress blob and its `VERSION` stay as they
  are. Reason: no format change and no v0 upgrade path that could break an existing duress
  enrolment; D6 allows one reboot credential anyway. A table is worth it only once a third
  action exists.
- **2026-10-10, one credential, PIN or password.** Matching is type-specific, so a reboot PIN
  fires only where a PIN is entered: with a password lock screen the typed text is a password
  credential and never matches. Settings has to say so.
- **2026-10-10, Q3: `lowLevelReboot`, no orderly shutdown.** It sets `sys.powerctl`, so init
  still kills processes, syncs and unmounts (`system/core/init/reboot.cpp:937`, `:955`, `:972`);
  it skips `ShutdownThread` (no `ACTION_SHUTDOWN` to apps, no dialog). "Data intact" therefore
  means committed data survives; app writes still in flight get no chance to finish.
  *Changed 2026-10-11:* the reason is `userrequested` (`PowerManager.SHUTDOWN_USER_REQUESTED`),
  the one the power menu passes (`WindowManagerService.java:4155-4159`), instead of none: a plain
  `reboot,` matched neither a power-menu restart nor a crash, so it stood out.
- **2026-10-11, reboot escrow is cleared first.** An escrow armed for a resume-on-reboot update
  restores the users' synthetic passwords on the next boot (`RebootEscrowManager.java:935`,
  `LockSettingsService.java:4476`), so the reboot would not end in BFU. `RebootBfu` calls
  `RebootEscrowManager.clearRebootEscrow()` before rebooting; a failure there is logged and the
  reboot still happens. The emulator's escrow HAL fails: the armed case is a Stage 6 check.
  *Tightened 2026-10-11:* `RebootEscrowManager.clearRebootEscrowForReboot()` deletes the users'
  escrow blobs before and after clearing the provider (so a provider that throws leaves nothing
  to restore). It holds a lock that capture's write and the whole arm also take, so an
  operation already running either finishes first and is wiped, or sees the flag and stops;
  preparing, capturing and arming are refused until the reboot. The flag is never reset: if
  the reboot doesn't happen, resume on reboot stays off until the next boot. `RebootBfu` asks
  for the reboot up to three times (`lowLevelReboot` returns only when init didn't reboot
  within 20 s).
- **2026-10-11, owner credential changes.** The reboot credential is deleted when the owner
  removes the screen lock, and when the owner's new primary or second-factor credential is
  equal to it (`DuressPasswordHelper.onLockCredentialChanged`, called from
  `onPostLockCredentialChanged`: ordinary changes `LockSettingsService.java:2232`, reset token
  `:4390`, the automatic second-factor clear `:3702`; unified-profile changes bypass it, which
  doesn't matter for an owner-only credential). An enrolment that overlaps an owner change is
  refused (`owner credential changed, try again`): a change counter, bumped when a change of
  user 0 *starts* (`setLockCredentialInternal`, the token path) and again when it completes,
  is sampled before the owner checks and compared under the lock before the save. A change
  attempt that fails also bumps it; the enrolment is then refused and retried (fails closed). Deleting instead of refusing the change: a refusal would need a check before every
  change path, and an equal credential can't fire anyway. Duress keeps its current behaviour
  (not touched on owner changes). Settings should say when this happened.
- **2026-10-11, a queued reboot is dropped after a successful verification of the same user.**
  The check runs on a background thread after the binder call returns; if any credential of
  that user verifies (either domain, including a Settings confirmation) while the reboot
  attempt waits, the reboot is dropped. Best effort: a verification after the last check, just
  before the reboot call, doesn't stop it. Duress is never dropped. Biometric unlock doesn't go
  through `doVerifyCredential` and can't drop it.
- **2026-10-11, precedence is per attempt.** One worker thread checks attempts in order. A
  reboot attempt queued before a duress attempt reboots before the wipe is checked; the wipe
  is then lost. Accepted: two different alternates typed within a second or two.
- **2026-10-11, unreadable records.** A stored reboot record that can't be parsed disables only
  its own action: the error is caught on the worker thread (only the exception type is logged,
  the record never), enrolment reports `corrupt reboot credential record`, and deleting never
  parses, so it always works. The parser checks every length before allocating, requires the
  exact record size (32-byte hash, 16-byte salt, no handle) and only the scrypt parameters this
  device writes, so a damaged record can't cost more memory or stretching than a valid one. The
  duress record keeps the stock parser, which trusts its lengths.
- **2026-10-10, Q2: fires at every user's prompt**, like duress. A reboot only takes access
  away. (The hook gets the user id since 2026-10-11, used only to drop stale reboots.)
- **2026-10-10, Q5: keeps the normal accounting.** The primary verification has already failed
  and been counted when the alternate is checked; not special-casing it keeps D4. So the
  failure count survives the reboot and repeated use lengthens the lockout; a device-admin
  wipe-after-N policy counts it too. Rate-limited, too-short and repeated guesses return
  early without being counted (`LockSettingsService.java:2822-2828`), but the hook in the
  `finally` (`:2778`) still sees them as not matched: the reboot PIN and duress fire during a
  lockout timeout as well, and a repeated entry fires again.
- **2026-10-10, enrolment (B9):** `setRebootCredential(owner, ownerSecondFactor, credential)`.
  The candidate is compared in memory with the owner credential and, if the owner has one, the
  second-factor PIN, before those are verified (verification zeroizes parceled credentials);
  then against duress with `DuressCredential.verify`. `setDuressCredentials` checks the reverse.
  Errors carry fixed `collision: …` messages. Deleting works without a screen lock, setting
  doesn't. The owner checks go through `doVerifyCredential` like any prompt, so typing the
  duress or reboot credential into them fires it; a wrong owner or second-factor entry counts
  as a failed attempt. The collision check and the write run under one lock, the owner checks
  outside it (they can take the `SyntheticPasswordManager` lock).

- **2026-10-12, hiding switchers by setting, not per surface:** setup sets
  `user_switcher_enabled=0`, which removes the keyguard, quick settings and power-menu
  switchers at once; the switch from the dispatch doesn't check it. Settings hides its Users
  entry in A so A can't turn it back on. Reason: one setting covers every SystemUI surface,
  and per-surface patches can be added where it falls short.
- **2026-10-12, locking B returns to A:** screen off in B switches to user 0, so the lock
  screen is always A's and B stops each time. Reason: with no switcher, B's own lock screen
  would be a dead end for A's holder.
- **2026-10-12, setup UI in Settings:** the setup step is a Settings activity launched by
  SetupWizard2, and the privileged work is one `LockSettingsService` call. Reason: Settings
  is already forked and holds the needed permissions; SetupWizard2 only needs one step.

- **2026-10-12, marker for B:** B is named "Protected", user 0 stays "Owner"; B shows a
  shield in the status bar (switchable in B's Settings) and gets its own red wallpaper, set by
  B's setup on its first run, so its system colors follow. Reason: the preset accent written
  at creation didn't survive B's setup on the Pixel, while a wallpaper drives the colors through
  the normal path; the shield marks B on every screen.
- **2026-10-12, PIN length:** new PINs need 6 digits or more (`MIN_NEW_PIN_SIZE`); the unlock
  path still accepts shorter stored PINs. With a protected space the service refuses short
  PINs from any caller. With auto-confirm on for A, setup asks for B's, the duress and the
  reboot PIN in A's length. Reason: auto-confirm submits at A's length, so a longer PIN
  couldn't be typed. Turning auto-confirm on later with mismatched lengths is not checked yet.
  Superseded by the 2026-10-13 decision below.
- **2026-10-12, owner's PIN in first setup:** Settings keeps a copy of the PIN just set at the
  lock step, in memory, for at most 10 minutes and only before user 0's setup completes; the
  protected space step takes it once instead of asking again. The service still verifies it.
  Reason: asking right after it was entered twice reads as an error, and a service-side check
  of each new PIN against A would cost Weaver reads on A's slot.
- **2026-10-12, duress is optional:** the setup can skip duress, or only its password, in which
  case a random password nobody knows is stored, since duress keeps a PIN and a password as one
  record. Reason: with PINs only, the password is never asked for; a wipe credential should be a
  choice.
- **2026-10-12, no fingerprint for B:** a touch on the lock screen is matched against the
  current user (A) only, and a fingerprint can't unlock a stopped user's storage; B stops on
  every exit. Reason: making it work would need the closed fingerprint HAL to match across
  users and B's key kept while B is closed, which defeats the point of stopping B.
- **2026-10-13, one PIN length:** once a protected space exists, every PIN on the device (A,
  B, A's second factor, duress, reboot) has the length of A's PIN at setup. Setup asks for it
  whether or not auto-confirm is on; the service stores the length (`protected_space_pin_length`
  in `locksettings.db`) and refuses any other in `checkLayoutPinLength`, called for credential
  changes, token resets and alternate enrolment; Settings shows the length on the PIN screens
  (`S/security/LayoutPinLength.java`). The length is stored before B becomes the authority, is
  a reserved key (`DuressPasswordHelper.RESERVED_KEYS`), and setup fails if user 0's credential
  changes while it runs. Spaces set up before this keep only the 6-digit minimum.
  Reason: auto-confirm submits at the stored length, so a PIN of another length can't be
  entered while it's on, and it can be switched on at any time; one rule is simpler to explain
  than one tied to auto-confirm. Side effect: the number of digits typed no longer tells which
  PIN was entered. Cost: changing to a longer PIN means setting the phone up again.
- **2026-10-13, shared PINs are refused only for B (replaces two earlier entries of the same
  day):** A is checked first, so a PIN A shares with B opens A, and an alternate (duress,
  reboot) that A or B shares never runs. With a protected space, B's own PIN changes are
  checked against A's PIN and the alternates (`checkLayoutCollision` in
  `F/services/core/java/com/android/server/locksettings/LockSettingsService.java`); a duress or
  reboot PIN enrolled from B must differ from A's PIN (`checkAlternateAgainstOwner`) and from
  B's own. The check against A's PIN goes through A's rate limiters like a lock-screen attempt;
  while A must wait, the change is refused ("try again later").
  A's own changes are **not** checked. Reason (seen in T8 on 2026101309): a refusal on A's
  change-PIN screen tells whoever holds A's PIN whether a guess is B's PIN or an alternate.
  For the alternates that comparison is local and unlimited, and unlike the lock screen,
  guessing there never risks hitting the duress PIN. B holds all those secrets already, so
  its checks reveal nothing. Cost: if A picks B's PIN, B can't be opened until one of them
  changes; if A picks the duress or reboot PIN, that action stops working. B's owner should
  pick PINs A wouldn't choose.
  Each comparison with A's PIN is a real attempt on A: a non-matching candidate counts one
  failure for A, so about five of B's PIN changes or duress/reboot enrolments without A
  unlocking in between start A's lock-screen delays (1 minute first); A's next unlock resets
  them. A Weaver read that fails outright (not a wrong-key answer) counts as no match, since
  Gatekeeper reports an ordinary mismatch the same way. Both accepted: rare, and only while B
  changes its settings.
- **2026-10-13, B's PIN costs A one attempt per boot:** dispatch tries A first, so the first
  B unlock after a boot (or after A's last unlock) counts one failed attempt for A in Weaver
  and in Android's failed-attempt count; repeats are caught as duplicate wrong guesses before
  the hardware (`F/services/core/java/com/android/server/locksettings/SoftwareRateLimiter.java:250`).
  Accepted: A's next unlock resets both. Only several boots in a row that open B without ever
  opening A would build up to the hardware's delays for A.
- **2026-10-13, auto-confirm stays off by default:** as in stock Android, it's turned on in
  A's Settings → Screen lock; with one PIN length it then submits B's PIN too. B's own setting
  has no effect on the lock screen.
- **2026-10-13, A and B stay PINs:** the 2026-10-11 rule is now enforced. With a protected
  space, a primary credential of user 0 or B that isn't a PIN (no lock, pattern, password) is
  refused for normal changes and token resets (`checkLayoutCredential`), and Settings offers
  only PIN for them (`S/password/ChooseLockGenericController.java`). A cleared second factor is
  still allowed. Reason: B is only reachable from user 0's PIN pad.
- **2026-10-13, no Android private space beside B:** setup sets `no_add_private_profile` on
  both users and refuses to start while user 0 has a private space. Reason: two similar features side by side confuse, and a private space takes
  Weaver slots and a second lock.
- **2026-10-13, calls from B:** setup clears `no_outgoing_calls` for B (Android's default for
  secondary users). SMS stays off: incoming SMS goes to user 0 only.
- **2026-10-13, boot logo:** the boot animation shows "os.ivan.gg" until user 0's first setup
  is done, then the plain AOSP "android" logo; system_server sets
  `persist.bootanim.setup_done` (`bootanim_system_prop`, so only system_server and the
  animation can write it). On husky the animation starts before `/data` is mounted, so it waits
  up to 5 s for `ro.persistent_properties.ready` (one sepolicy line, `system/sepolicy` branch
  `envs-17`). The bootloader's unlocked/custom-key warning before it can't be changed.
  This needs no `bootanimation.zip` on the device: `BootAnimation::android()` only runs
  when `findBootAnimationFile` finds none (`cmds/bootanimation/BootAnimation.cpp:768`). Since
  2026-10-15 our `platform_build` fork keeps GrapheneOS's `bootanimation_zip` out of the
  product (doc 00 decision 2026-10-15). A richer setup animation would be our own zip shown
  only before setup; not planned yet.
- **2026-10-15, stock Android logo after setup, our own shine before:** our builds still had
  GrapheneOS's 2048×605 shine (`android-logo-shine.png`) under the AOSP mask. `envs-17` now
  starts with GrapheneOS's own revert of their logo (`7c9cd735f4`, AOSP mask and 128-pixel
  shine), so after setup the logo is fully stock; on the next release's rebase that commit
  becomes empty and is dropped (if upstream changes those images again, the rebase stops on
  a binary conflict instead). Our 448×605 `setup-logo-mask.png` gets its own
  `setup-logo-shine.png` (2048×605, generated, no upstream artwork), loaded with it in
  `BootAnimation::android()`; with Android's 128-pixel shine most of it stayed dark. The commits
  that edited `android-logo-mask.png` on the way no longer touch it. Reason: no GrapheneOS
  branding (doc 00), and no binary conflict on every rebase.
- **2026-10-13, "Browser" in user 0:** Vanadium's launcher entry
  (`app.vanadium.browser/com.google.android.apps.chrome.Main`) is shown as "Browser" in user 0
  through Android's per-user component label override, applied by system_server at boot
  (`PackageManagerService.overrideSystemComponentLabel`), and its app label is set to the same
  for user 0 where `ApplicationInfo` is built (`PackageInfoUtils.updateApplicationInfo`), so
  Settings → Apps and Recents say "Browser" too. Vanadium's own screens and B keep "Vanadium".
  Reason: the prebuilt defines `<overlayable>` and has obfuscated resource names, so an
  overlay can't rename it.
- **2026-10-13, reboot credential is a PIN with a protected space:** the lock screen is a PIN
  pad, so a reboot password could never be typed there. The service refuses one and Settings
  no longer offers the type.
- **2026-10-15, the reboot PIN costs A and B one attempt:** it is checked last, after A and B
  missed (lock screen order above), so each use counts one failed attempt for both, and after
  the restart the first B unlock counts one more for A. Accepted: same as a wrong guess,
  cleared by each space's next unlock. Seen on the Pixel in T10.
- **2026-10-15, B keeps "Vanadium":** the 2026-10-13 label rule stays; the owner confirmed it
  after T9 W3.
- **2026-10-15, the private space entry is refreshed at setup:** Settings publishes it only at
  boot, so after the protected space was set up it stayed in A's Security & privacy until the
  next boot (T9 F2). Setup now sends Settings a refresh for that one source
  (`LockSettingsService.refreshPrivateSpaceEntry`).

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
  - PIN scrambling (B10) is layout only. `KeyguardPinBasedInputView.setupPinScrambling`
    (`frameworks/base/packages/SystemUI/src/com/android/keyguard/KeyguardPinBasedInputView.java:326-349`)
    shuffles which digit each key shows, so the credential is the same digit string. It has
    separate settings for the primary and second-factor PIN
    (`KeyguardPinBasedInputViewController.java:117-122`). No effect on alternates.
- Q5. Should a matched reversible alternate count toward the failed-attempt counter?
