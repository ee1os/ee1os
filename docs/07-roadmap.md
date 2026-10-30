# 07 — Roadmap and backlog

What gets built, in which order, and why. *How* it is built and tested — dev environment,
test levels, per-stage gates — is in `08-development-and-testing.md`.

## Status

| Stage | What | Status |
|---|---|---|
| 0 | Groundwork: docs, source, dev environment | done except adb from m3max; baseline in `tests/results/2026-10-10-stage0-T1-T2.md` |
| 1 | Baseline experiments on the unmodified emulator | done 2026-10-10 (`tests/results/2026-10-10-stage1-T3.md`); keyguard entry left for T4 |
| 2 | `REBOOT_BFU` alternate credential | 2a implemented and tested on the emulator after three reviews (`stage2.sh` PASS, escrow SKIP; T1 819/0 incl. 22 new tests; `tests/results/2026-10-11-stage2-T3.md`); 2b screens built, `stage2b.sh` PASS (`2026-10-11-stage2b-T3.md`); open: owner decision on storage (doc 00), keyguard entry and screen states (T4), armed escrow and Weaver (Stage 6) |
| 3 | Environment B via the lockscreen user switcher | eviction confirmed; 3c fixed, rerun with assertions PASS (`tests/results/2026-10-11-stage3-T3.md`); next 3b wording, End session check |
| 4 | Automatic PIN dispatch | built as the A/B/duress layout (doc 04): one pad checks A, then B; emulator 2026-10-12 (`tests/results/2026-10-12-layout-T3.md`) |
| 5 | B before A after boot | backup crash fixed; storage service started by the first unlocked user: B unlocks first with working shared storage and MediaStore, owner stays locked (`tests/results/2026-10-11-stage5-T3.md`); in/out still open |
| 6 | Real device | Pixel 8 Pro on our userdebug build, test keys, bootloader unlocked; Weaver measured; layout passed twice (`2026-10-12-layout-T5.md`, `-T6.md`); release signing not started |

All work stays in the fork for now (decision 2026-10-09, see *Fork and upstream*).

**Next, in order (2026-10-12, after the second phone run).**

1. Layout gaps (built 2026-10-13, doc 04 decisions): one PIN length, A and B stay PINs, no
   Private space, calls from B, boot logo after setup, "Browser" in user 0. Still open: show
   where duress is managed (B's Settings).
2. Release basics (*Release and distribution* R1–R2): the update app points at our server,
   one script builds and signs a release. Needs the owner's keys for real signing. Hosting
   (2026-10-13): GitHub organization `os-ivan-gg`, public; updates from one rolling
   "updates" release in a releases repo, factory images in numbered releases; R2 only if
   files outgrow GitHub's 2 GB per file.
3. Upstream tracking (R5) and the update compatibility test (R6) before any tester gets a
   build.
4. ~~Weaver-backed alternates~~ shelved, doc 00 decision 2026-10-13.
5. Remaining phone checks: reboot PIN, auto-confirm with the layout, duress wipe last.
6. Rename to ee1os (R8, doc 00 decision 2026-10-30).

The earlier list (2026-10-11) is done or folded in above: Stage 3 wording and Stage 5
coverage stay open in their sections.

## Release and distribution (planned 2026-10-12)

Not started; done when the layout is stable enough for outside testers. Nothing is published
before the owner says so.

| # | Task | Notes |
|---|---|---|
| R1 | Our own update server | Done 2026-10-13: `packages/apps/Updater/res/values/config.xml:3` (fork branch `envs-17`) points at `https://github.com/ee1os/releases/releases/download/updates/` (`os-ivan-gg` until 2026-10-30) (rolling "updates" release; the GrapheneOS-only TLS pin set doesn't apply to it). To check on the first release: update_engine streams the payload from that URL and has to follow GitHub's redirect to its download host |
| R2 | Release script on n5 | first version 2026-10-13: `scripts/release.sh [user\|userdebug]` builds target files, signs (`script/generate-release.sh`, passphrase prompt), uploads the update zip and channel metadata to the rolling "updates" release and the install zip to a release of its own, notifies klava hq. Untested until the keys exist; old update zips aren't pruned yet |
| R3 | Tester install | install zip plus a short script, later an adapted web installer page: unlock, flash, set `avb_custom_key`, lock |
| R4 | ee1os.com page (was os.ivan.gg) | what it is, install steps, release notes; static hosting with the images; drafted here, published by the owner |
| R5 | Tracking GrapheneOS releases | first version 2026-10-13: `scripts/track-upstream.sh`, nightly. Detects a new husky stable tag, syncs, rebases each fork's `envs-17` (stops and notifies on a conflict), builds, runs `tests/gate.sh` if present, then force-pushes the branches with a `<tag>.os` tag, rebuilds the manifest on the tag and packs the flash archive. 2026-10-15: the manifest step rebased only its last commit, which a release tag's pinned `default.xml` doesn't take anyway; it now starts from the tag, copies our `envs.xml` and adds one include. Releases only, never upstream branch `17` (doc 00 decision 2026-10-15). 2026-10-15: `scripts/upstream-watch.py` previews branch `17` nightly and flags strategic changes; a release with flags is built but held until `APPROVE=<tag>` (doc 08). Phone check and release stay manual. Owner decision: GrapheneOS stable releases sync automatically. Open: `tests/gate.sh` (unit tests + emulator scenarios), scheduled 2026-10-15 as TrueNAS cron jobs 25 (`upstream-watch.py preview`, 00:30) and 26 (`track-upstream.sh`, 01:00), user faeton, n5 time |
| R6 | Update compatibility test | install release N, set up the layout, update to N+1, check users, PINs, duress and reboot records still work |
| R7 | Naming | "a fork of GrapheneOS" as description only; no GrapheneOS name, logo or boot animation as branding. 2026-10-15: GrapheneOS's new boot animation is kept out by the `platform_build` fork (doc 00 decision). 2026-10-30: the name is ee1os, "two environments, one OS" (doc 00 decision) |
| R8 | Rename to ee1os | In progress 2026-10-30. Done: repo renamed `ee1os`; site renamed and moved to Worker `ee1os` in the "ID AKM" Cloudflare account (ee1os.com, www); scripts, local manifest and docs point at `github.com/ee1os`; forks on `envs-17`: setup logo mask, notification label, duress text, setup screens, Updater URL (await approval and the next release). Keys: rotated to `CN=ee1os` by the owner (doc 08 *Key rotation*; the test phone is erased and reinstalled; the old keys are archived, never deleted). Kept: local paths (`~/work/os-ivan-gg`, `/src/os-ivan-gg`, `/mnt/tank/scripts/os-ivan-gg`). Plan was: register/point ee1os.com (owner); rename the GitHub organization `os-ivan-gg` and this repo, then the Updater URL (R1), `scripts/envs-local-manifest.xml`, the release and tracking scripts, the boot logo and on-device strings that say os.ivan.gg (doc 04, boot logo), `site/` drafts (`NAME`), key CN in `scripts/generate-keys.sh` before the release keys exist. Installed test builds update from the old URL, so the old release location keeps redirecting or serving until every tester is on a build with the new one. fri4.com stays owned |

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
- [x] First emulator build of unmodified 17 (2026-10-10, super partition raised to 3584 MiB),
  emulator boots in about 25 s, `adb` works on n5
- [ ] `adb` from m3max over the ssh tunnel (doc 08)
- [x] Baseline test run on the unmodified build (doc 08, T1 + T2), results recorded: T1 797
  passed, one stock test class doesn't load; T2 needs Weaver, moves to T5
- [x] Weaver HAL on the emulator: none. Lockout there is the software limiter only

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

**Results 2026-10-10** (`tests/results/2026-10-10-stage1-T3.md`):

- Item 2 as read: a plain switch leaves N `RUNNING_UNLOCKED`; `am stop-user -w` returns before
  the key is removed (CE names encrypted after 4–5 s); `no_run_in_background` stops N on switch
  away and locks it at once. But see 3c: one CE database stays open.
- Item 3: owner stays `RUNNING_LOCKED`; unlocking N first crashes system_server in the backup
  service (`UserBackupManagerService.java:622` → `ContextImpl.java:686-701`, checks user 0's
  unlock state for a system-context file). Stock code, reachable only through
  `allow_user_switching_when_system_user_locked`.
- Item 5: 4 mismatches, then `Request throttled`; right PIN accepted after 65 s. Goldfish has no
  Weaver, so this is the software limiter only.
- Item 4: duress fires from the shell verify (same `checkCredential` entry as the bouncer); the
  next boot stops at `init_user0_failed`. `input text` doesn't reach the keyguard bouncer, so
  keyguard entry is checked by hand (T4).

### Stage 2 — `REBOOT_BFU` alternate credential

Deliverable: commits on `envs-17` in both forks, exported to `patches/02-reboot-bfu/`, plus
test results. Design: doc 04.

- 2a. system_server, first version 2026-10-10 (fork `envs-17`): one reboot credential in its own storage
  slot instead of a table (doc 04 *Decisions*), checked after duress in
  `DuressPasswordHelper`; `RebootBfu` (`lowLevelReboot`); collision checks in memory against
  the owner credential, the second-factor PIN and duress, both directions;
  `ILockSettings.setRebootCredential` / `hasRebootCredential`;
  `cmd lock_settings set-reboot-credential` for scripted enrolment. Tests: `tests/stage2.sh`.
  **Results 2026-10-10:** every collision refused in both directions; reboot PIN at the
  owner's and at envB's prompt → down within 2 s, back in BFU after ~25 s, owner PIN unlocks with
  data intact, boot reason a plain `reboot,` (since changed, below); wrong/right PINs never
  reboot; wrong-PIN response time unchanged with 0, 1 or 2 alternates (D4; shell + adb
  latency, so it rules out a large difference, not a small one). Not covered then: the
  second-factor collision and password enrolment (password is now in `stage2.sh`, the second
  factor in the unit tests only). Patch: `patches/02-reboot-bfu/`.
- **Review fixes, 2026-10-11** (fork `7187029c`, tests `f554fde6`), from a code review of 2a:
  - a stored record that can't be parsed disabled nothing before and crashed system_server on
    any wrong entry (the worker thread let the exception out); now it disables only its own
    action, logs a fixed message, and deleting never parses;
  - an armed reboot escrow would have unlocked the users again after the reboot: cleared first;
  - a reboot queued behind the real credential of the same user is dropped;
  - owner removes the lock, or picks a primary / second-factor credential equal to the reboot
    credential → reboot credential deleted (all change paths pass `onPostLockCredentialChanged`);
  - boot reason `userrequested`, the power menu's, instead of none;
  - credential arguments zeroized on every path (binder methods incl. the inherited duress
    ones, shell command early returns);
  - collision check + write under one lock;
  - the wipe / reboot actions sit behind `DuressPasswordHelper.Actions`, so tests use the real
    helper: `AlternateCredentialsTests`, 15 tests.
  Decisions and accepted limits (precedence per attempt, accounting, lockout) in doc 04
  *Decisions*. Results: `tests/results/2026-10-11-stage2-T3.md`.
- 2b. Settings screen as drafted in doc 04 → *Settings flow*.
- 2c. Host test `RebootBfuTest` modelled on `DuressPasswordTest` (needs Weaver, so T5), manual
  matrix (doc 08). Keyguard entry of the reboot PIN is a T4 check, as for duress. The unit
  tests with the real helper are done (above); `LockSettingsServiceTestable` still returns a
  mock, so the stock tests don't exercise the hook.

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
- 3c. **Found 2026-10-10, patched in the fork.** After N stops, system_server kept
  `/data/system_ce/N/accounts_ce.db` (+ `-wal`, `-shm`) open, so vold removed the key with busy
  files and that database stayed readable. `purgeUserData` calls `AccountsDb.close()`
  (`AccountManagerService.java:1581-1596`), which closed only the DE helper
  (`AccountsDb.java:1456-1458` at `84183aff`). Since AOSP e866ee92 / 083147324f7b ("Remove detach_de_ce
  flag") the CE database is a separate `CeDatabaseHelper` (`:181`, `:1362-1365`) that nothing
  closed. `lsof` after a stop (`probe` with Settings, Dialer, Camera, Sync opened in N): 89 CE
  files open while N runs, only these three after the stop. Fix: close `mCeDatabase` too
  (fork `ce54caed`, `patches/03-environment-b/`). Retest on the fixed build: 93 CE files open
  while N runs, none after the stop, no vold warning. Stage 3 depends on this patch.

**Isolation evaluation, first version (2026-10-11; doc 00 goal 3).** What the emulator runs
show, with the fork's 3c patch:

| Property | Status | Evidence |
|---|---|---|
| B has its own credential, synthetic password and CE key | by construction | secondary user, doc 02 (not separately tested) |
| B's CE storage locked after *Run in background* off + switch away | shown | Stage 1 item 2: CE names encrypted at once |
| … after `am stop-user` | shown | CE names encrypted after 4–5 s; 3c: no CE file left open (`2026-10-11-stage3-T3.md`) |
| … after power-menu End session | read, not run | `UC:1182-1230`; T4 |
| Plain switch without the restriction | **not isolated**: B stays unlocked | Stage 1 item 2 (checked to 30 s) |
| A's CE key while B is in use | stays in memory until reboot | `UC:1323-1324`; accepted (doc 00 *Decisions*); `REBOOT_BFU` covers it |
| After a reboot, nothing is unlocked until a credential is entered | shown | Stage 2 `reboot` / `reboot-b`: owner `RUNNING_LOCKED`, sentinel unreadable |
| B usable before A after boot | experiment, works on the emulator | Stage 5 (backup fix + storage patch) |
| Duress still wipes everything from any prompt | shown for the shell prompt | Stage 1 item 4, 2026-10-11 regression; keyguard entry is T4 |
| Throttling of B's PIN | software limiter only on the emulator | Stage 1 item 5; Weaver is Stage 6 |

Not evaluated yet (no claim either way): what A and B share at device level (radios and
their configuration, public volumes, device identifiers, the user list itself; existence of B
is visible by design, doc 00 *Non-goals*); whether apps or services of A keep anything of B
in memory after B stops beyond the 3c case; behaviour on hardware.

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

Stage 1 item 3 (2026-10-10): unlocking N while the owner is locked crashes system_server in
`BackupManagerService` (Stage 1 results). Cause, read 2026-10-10:

- `UserBackupPreferences` opens `/data/system_ce/N/backup/backup_preferences` (N's CE, unlocked)
  with `getSharedPreferences(File)` on the system context (`UserBackupPreferences.java:37-41`).
- The system context is flagged credential-protected because its `LoadedApk` has no data dirs
  (`ContextImpl.java:3947-3952`), and `credentialProtectedStorageCheck` throws unless
  `myUserId()`, always 0 in system_server, is unlocked (`:687-701`). It is a throw, uncaught on
  the backup thread.
- Fix: `createDeviceProtectedStorageContext().getSharedPreferences(file, …)`: same file, no
  check. The same idiom is used in `services/usb/java/com/android/server/usb/UsbDeviceManager.java:1132-1136`.
- Sweep of every `getSharedPreferences` in `services/` and `core/java/com/android/server`: no
  other call on the raw system context runs for N after boot. `AuthenticationStatsPersister`
  (`biometrics/AuthenticationStatsPersister.java:69`) uses it but only receives user 0's
  unlock; `RecoverySystemService` (`:229-233`) runs before `setSystemProcess`, when the check is
  off.

**Experiment 2026-10-10 with the fix** (fork `d34c6e71`, `patches/05-boot-order/`): N unlocks
first, owner stays `RUNNING_LOCKED`, no crash. Next blocker: N's shared storage stays
`unmountable` ("Reporting emulated;10 unmounted due to system locked", "Not ready to bind to the
ExternalStorageService for user 10").

**Cause, corrected 2026-10-11.** The first reading ("user 0's MediaProvider serves every user")
was wrong. Each user binds its own ExternalStorageService: the connection is per volume user
(`storage/StorageSessionController.java:83-93`), the bind is `bindServiceAsUser(…,
UserHandle.of(mUserId))` (`storage/StorageUserConnection.java:546-550`), and the service isn't
`singleUser` (`packages/providers/MediaProvider/AndroidManifest.xml:220`). Two owner-first
gates instead:

- the service component was looked up only in user 0's unlock (`onUnlockUser`,
  `StorageSessionController.java:273-282`, resolved as `USER_SYSTEM`, `:379`); until then the
  component is null and every connection fails with "Not ready to bind"
  (`StorageUserConnection.java:488-490`);
- `getVolumeList` reports every volume unmounted to callers other than MediaStore until user 0
  has unlocked (`StorageManagerService.java:3931-3935`, `:4003`).

**Patch 2026-10-11** (fork `066afecc`): the first user to unlock looks the component up, as
itself; user 0 still does it again when it unlocks. `getVolumeList` also reports volumes to a
user that has unlocked on its own. Result: `tests/stage5.sh storage` PASS: N's `emulated;10`
mounts, files can be written and read, MediaStore of N answers, the owner stays locked
throughout; after the owner unlocks, both users' storage works
(`tests/results/2026-10-11-stage5-T3.md`). Before in/out: next-list item 2.

### Stage 6 — real device

Dedicated test Pixel, own signing keys, never a daily device. Purpose: Weaver/secure-element
throttling, eSIM wipe and the real boot chain, none of which the emulator has. Manual steps
in doc 08.

## Fork and upstream

- **Decision 2026-10-09:** everything stays in the forks (branch `envs-17`). Nothing is
  proposed upstream for now.
- **Decision 2026-10-13:** the project moves to the GitHub organization `os-ivan-gg`, all
  public: the forks (frameworks/base, Settings, SetupWizard2, sepolicy, Updater), this repo
  (renamed from `grapheneos-envs`), `manifest`, `releases`, `site`. Reason: several repos that
  belong together, clean URLs for releases, room for testers. The site goes live only on the
  owner's go.
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
| B9 | Where can enrolment probe a candidate against the owner's Secondary PIN without the duress hook and without counting a failure? | nowhere: every path hits the rate limiter and Weaver; ask for the second-factor PIN at enrolment instead (doc 04 *Settings flow* 5) |
| B10 | PIN scrambling vs alternates (doc 04 Q4) | layout only, credential unchanged, no effect |
| B11 | Release provenance: `publish-release.sh` names the checkout's current SHAs, not what the signed build was made from | open (2026-10-15): record the manifest, fork SHAs and upstream tag next to the artifacts at build time and publish that record |
| B12 | `state/base` and `upstream-watch` reports are on `flash/scratch` (not backed up) | open: losing `state/base` stops `track-upstream.sh` safely; reseed from the fork tags `<tag>.os` |

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

## Review log

Outside reviews, advisory only, no file writes.

| Date | Reviewer | Subject | Outcome |
|---|---|---|---|
| 2026-10-30 | Grok, Codex, agy | Project domain fri4.com | Best reading `4` = `a`, *fría*, "cold" → BFU; also Scandinavian *fri*, "free"; `3744` on a phone keypad. Risks: Frida, FRIA (EU AI Act), cold-boot attacks, spoken ambiguity |
| 2026-10-30 | Grok, Codex (agy: quota) | Project domain ee1os.com | Both rank "two environments, one OS" first; Codex adds "encrypted environments". Risks: Eelo (old /e/OS name), `1`/`l`/`I`, EE carrier, "-os" reads as a fork (accurate for us). Codex: "ee1os has the cleverer explanation; fri4 has the cleaner brand." Owner chose ee1os (doc 00 decision 2026-10-30) |
