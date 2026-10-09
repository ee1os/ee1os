# 07 — Roadmap and backlog

What gets built, in which order, and why. *How* it is built and tested — dev environment,
test levels, per-stage gates — is in `08-development-and-testing.md`.

## Status

| Stage | What | Status |
|---|---|---|
| 0 | Groundwork: docs, source, dev environment | docs + backlog done; build container works (`lunch` OK); first build pending |
| 1 | Baseline experiments on the unmodified emulator | script ready (`tests/stage1.sh`), waiting for first build |
| 2 | `REBOOT_BFU` alternate credential | design ready (doc 04) |
| 3 | Environment B via the lockscreen user switcher | likely no patch; confirm in Stage 1 |
| 4 | Automatic PIN dispatch | design notes only |
| 5 | B before A after boot | depends on Stage 1 item 3 |
| 6 | Real device | not started |

All work stays in the fork for now (decision 2026-10-09, see *Fork and upstream*).

## Stages

### Stage 0 — groundwork

- [x] Sparse checkouts + sync script (`scripts/sync-src.sh`)
- [x] Duress walkthrough (doc 03), dispatch design (doc 04), boot/update constraints (doc 06)
- [x] Full GrapheneOS 17 tree on n5 (2026-10-06; 1057 projects as of 2026-10-08).
      `frameworks/base` = `84183aff` = fork `envs-17`
- [x] All `file:line` references re-checked against the full tree (2026-10-08). Every project SHA
      equals the doc-01 table; four references corrected
- [x] Upstream issue #8505 confirmed; maintainer positions collected (doc 04)
- [x] Backlog B2–B8 (below)
- [x] Build container (`workspace/build-env/`): image built, `lunch` works inside (2026-10-09)
- [ ] First emulator build of unmodified 17, emulator boots, `adb` from m3max
- [ ] Baseline test run on the unmodified build (doc 08, T1 + T2), results recorded
- [ ] Check whether the emulator exposes a Weaver HAL (`adb shell service list | grep -i weaver`)

### Stage 1 — baseline experiments, no code

Unmodified GrapheneOS emulator build, scripted over `adb` (`tests/stage1.sh`). Each item
answers an open question; results go to `tests/results/`.

1. Owner PIN + one secondary user with its own PIN (`cmd lock_settings set-pin`, `pm create-user`).
2. Eviction: after `am switch-user 0`, is user N still unlocked (`am get-started-user-state N`)?
   After `am stop-user -w N`? With `no_run_in_background` set on N? Code reading predicts:
   - plain switch → N keeps running, unlocked (stop-on-switch defaults off,
     `UserController.java:581-591`);
   - with `no_run_in_background` → N stopped, CE key evicted asynchronously
     (`:1702-1713` → `LockSettingsService.java:4015-4026` → vold), so poll rather than check once.
3. Boot order: `settings put global allow_user_switching_when_system_user_locked 1`, reboot,
   switch to N before the owner unlocks (`UserManagerService.java:3362-3367`). Record what breaks.
4. Duress works on the emulator via `set-duress-credentials` (`LockSettingsShellCommand.java:417`).
   Destroys the emulator's data; run last, restart with `EMU_ARGS=-wipe-data`.
5. Lockout schedule with repeated wrong PINs (`SoftwareRateLimiter.java:107-129`): 5 failures →
   1 min, 10 → 4 h, 13 → 4 days, per the table.

### Stage 2 — `REBOOT_BFU` alternate credential

Deliverable: commits on `envs-17` in both forks, exported to `patches/02-reboot-bfu/`, plus
test results. Design: doc 04.

- 2a. system_server: action chosen per entry instead of hard-coded in `DuressPasswordHelper`;
  storage v1 with an action byte and v0 upgrade; `RebootBfuAction`; enrolment collision
  checks that never go through `checkCredential` (doc 04, *Settings flow* item 5);
  `cmd lock_settings set-reboot-credential` for scripted enrolment.
- 2b. Settings screen as drafted in doc 04 → *Settings flow*.
- 2c. Unit tests (duress helper wired for real instead of mocked), host test `RebootBfuTest`
  modelled on `DuressPasswordTest`, manual matrix (doc 08).

### Stage 3 — environment B via the existing lockscreen user switcher

No new verifier. B is a secondary user; the user id is chosen on the lockscreen before any
credential is checked, so there is no cross-user throttling and no duress race.

**Code reading 2026-10-08: probably no framework patch needed.** Paths relative to
`frameworks/base/`; `UC` = `services/core/java/com/android/server/am/UserController.java`.

- **Eviction exists today without a device owner.**
  - `DISALLOW_RUN_IN_BACKGROUND` on N makes every switch away from N call
    `stopUsersLU(N, allowDelayedLocking=false)` (`UC:2736-2747`). The owner sets it in
    Settings → Users → N → *Run in background*
    (`packages/apps/Settings/src/com/android/settings/users/UserDetailsSettings.java:242-243`) or with
    `pm set-user-restriction --user N no_run_in_background 1`. Setting it while N is in the
    background stops N at once (`UserRestrictionsUtils.java:735-742`).
  - Power-menu **End session** (`GlobalActionsDialogLite.java:1281-1305`) falls back to
    `ActivityManager.logoutUser` when there is no device-owner logout
    (`UserLogoutInteractor.kt:59-67`). That switches to user 0, then
    `stopUser(N, allowDelayedLocking=false)` (`UC:1182-1230`). It only requires N to be a
    non-system user allowed to switch (`UserManagerService.java:3396-3411`). The device-owner
    gate (`DevicePolicyManagerService.java:12652-12656`, `:19467-19472`) applies to the DPM
    path only.
- **Any stop of a full secondary user evicts its key.** `config_multiuserDelayUserDataLocking`
  is false (`core/res/res/values/config.xml:3307`), and only Private space allows delayed
  locking (`UserTypeFactory.java:345`), so `canDelayDataLockingForUser` is false
  (`UC:1785-1794`). Chain: `finishUserStopped` → `dispatchUserLocking` →
  `LockSettingsInternal.lockUser` → `StorageManager.lockCeStorage` + keystore lock
  (`UC:1660-1713`). Skipped if N is restarted before the FgThread task runs (`UC:1709-1711`).
- **Without the restriction** a plain switch leaves N running and unlocked until an LRU stop
  past the running-user limit (`max(RAM_GB-2, 3)`, `ActivityManagerService.java:9733-9736`),
  26 h in the background (`config_backgroundUserConsideredDispensableTimeSecs`), or an
  explicit stop.
- `UserControllerHelper` (GrapheneOS) only adds the per-user
  `disallow_delayed_locking_on_user_stop` setting (`UserControllerHelper.java:14-24`, read at
  `UC:1786`); it matters for Private space only.
- User 0 can never be stopped (`UC:1323-1324`), so A's key stays in memory until reboot
  (accepted, doc 00 *Decisions*).
- 3a. Confirm on the emulator (Stage 1 item 2) that the restriction and End session behave as
  read. Patch only if Stage 3 must not depend on a setting; the minimal patch is in
  `stopUserOnSwitchIfEnforced` (`UC:2741-2747`).
- 3b. The toggle exists (*Run in background* off). Remaining work is wording: say that it
  evicts the user's keys on every switch.

### Stage 4 — automatic PIN dispatch

"The PIN decides": a credential typed at the keyguard is tried against the other environment
when it does not match the selected user. PIN-only, owner already unlocked since boot.
Upstream has rejected switch-to-user PINs (#8675, #8409), so this is fork-only by nature.

- 4a. Keyguard-only verify flag; second verification through user N's normal protector;
  duress check completed before the second verification; result names the target user;
  switch + dismiss for that user. In-app confirmation prompts never carry the flag.
- 4b. Accounting: a successful dispatch must not be reported as an owner failure
  (`KeyguardSecurityContainerController.java:1300`); remove the matched credential from the
  other user's wrong-guess cache (`SoftwareRateLimiter.java:400`); a throttled user blocks
  fallthrough.
- 4c. Try the last-used user first (stored user id, not credential-derived); measure counters
  over a scripted week of crossings.
- 4d. PIN A typed while B is foreground: switch to user 0, then stop N as in Stage 3.
- 4e. Enrolment-time collision check of PIN B against duress / alternates / PIN A.

### Stage 5 — B before A after boot (experiment, may be dropped)

Only if Stage 1 item 3 looked workable. Decide in/out and record it in doc 00.

### Stage 6 — real device

Dedicated test Pixel, own signing keys, never a daily device. Purpose: Weaver/secure-element
throttling, eSIM wipe and the real boot chain, none of which the emulator has. Manual steps
in doc 08.

## Fork and upstream

- **Decision 2026-10-09:** everything stays in the forks (`faeton/platform_frameworks_base`,
  `faeton/platform_packages_apps_Settings`, branch `envs-17`). Nothing is proposed upstream
  for now.
- If that changes: GrapheneOS takes code as GitHub PRs on the per-component repos and feature
  requests on `os-issue-tracker`; discussion belongs in their chat rooms or forum, not the
  tracker ([#29](https://github.com/GrapheneOS/os-issue-tracker/issues/29)). Style is upstream
  style, 4-space indent, braces always, 100 columns (<https://grapheneos.org/build>). Expect
  maintainers to split, reword and reorder commits. #8505 is the place for a `REBOOT_BFU`
  proposal; Stages 4–5 would stay in the fork regardless.

## Not planned

- Multi-OS / multi-slot boot (doc 06).
- Environment concealment / deniability (doc 00, non-goals).
- There is no doc 05.

## Backlog

| # | Task | Result |
|---|---|---|
| B1 | Re-verify line references after each tree update | recurring; last done 2026-10-08 |
| B2 | Callers of `doVerifyCredential`, UI surfaces | 7 call sites, doc 03 *Who reaches the hook* |
| B3 | Duress code, branch `16` vs `17` | doc 03 *Changes since 16* |
| B4 | Stretch cost per failed attempt with N alternates | ~1.4 ms per scrypt on n5, one per same-type alternate, off the response path; doc 04 D6 |
| B5 | `Secondary` lock domain and the hook | duress fires there too; doc 04 Q4 |
| B6 | Existing locksettings tests | no duress unit test; `DuressPasswordTest` host test is the template; doc 04 *Test plan* |
| B7 | fstab / first-stage mount on `17` | `system/fs/fs_mgr`; emulator is not A/B; doc 06 |
| B8 | Settings screen flow | duress enrolment has no collision check; doc 04 *Settings flow* |
| B9 | Where can enrolment probe a candidate against the owner's Secondary PIN without the duress hook and without counting a failure? | open, needed for Stage 2a |
| B10 | PIN scrambling vs alternates (doc 04 Q4) | open |

## Design notes

Findings from design reviews of the secondary-user approach, kept because later stages rely
on them. Line numbers re-checked 2026-10-08.

- **Concealment is not achievable** with a secondary user: its existence is visible in system
  metadata (doc 00 non-goals).
- **Never let a software-comparable value select anything that grants access** (→ D2 in doc 04);
  alternates need collision rules (→ D1, D3).
- **Entering user N from the owner's keyguard** is feasible with N's normal hardware-backed
  verification and no new credential blob, but:
  1. hook a keyguard-only coordinator, not `doVerifyCredential` (`LockSettingsService.java:2689`,
     `:2709` would drag in every confirmation prompt);
  2. the duress check is asynchronous (`DuressPasswordHelper.java:50`), so a fallback to N must
     wait for it, or N can unlock before a colliding wipe;
  3. a throttled user 0 must block fallthrough, or primary precedence breaks;
  4. keyguard failed-attempt accounting would count every PIN B as an owner failure
     (`KeyguardSecurityContainerController.java:1300`);
  5. the software rate limiter keeps copies of wrong guesses (`SoftwareRateLimiter.java:400`),
     so a valid PIN B sits in memory as an owner wrong guess — doc 03 P5 is too absolute;
  6. the limiter is steep (5 failures → 1 min, 10 → 4 h, 13 → 4 days,
     `SoftwareRateLimiter.java:107-129`), and Weaver persists a failure before comparing
     (`IWeaver.aidl:83-98`), so try-0-then-N locks the owner out quickly;
  7. collisions can't be checked offline; enrolment has to submit the candidate once to the
     other user's verifier (→ D3).
- The explicit user picker avoids all of the above, which is why Stage 3 comes before Stage 4.
- Switching to N before the owner unlocks is blocked by UI policy only
  (`UserManagerService.java:3362-3367`); no cryptographic owner-first dependency found. Before
  owner unlock `getVolumeList` reports every volume unmounted, except to MediaStore
  (`StorageManagerService.java:3931-3934`, `:3995-4001`). Stage 1 item 3 tests what else breaks.
