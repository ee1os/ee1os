# 07 — Roadmap and backlog

## Stages

### Stage 0 — groundwork (in progress)

- [x] Sparse checkouts + sync script (`scripts/sync-src.sh`)
- [x] Duress implementation walkthrough (doc 03)
- [x] Dispatch design draft (doc 04)
- [x] Boot/update constraints (doc 06)
- [x] Verify every `file:line` reference in docs 03, 04, 06 against the pinned SHAs (2026-10-08, full tree;
      all project SHAs equal the doc-01 table; 4 refs corrected: `UserController:1323-1324`,
      `UserManagerService:3362-3367`, `DevicePolicyManagerService:12652-12656`, SP-manager comment 88–160)
- [x] Confirm the upstream issue number (2026-10-08): #8505 "Feature: BFU PIN" is real and open,
      with no team reply yet. Maintainer positions from related issues are in doc 04 → *Maintainer positions*
- [x] Read GrapheneOS contribution expectations (2026-10-08) → *Upstream conversation* below
- [x] Add locksettings tests path to the sparse set (2026-10-08, plus `tests/DuressPasswordTest/`)

### Test environment

GrapheneOS builds only on x86_64 Linux (<https://grapheneos.org/build>); the MacBook is arm64,
so it cannot build. Split, as checked 2026-10-06:

| Machine | Role | Facts |
|---|---|---|
| `n5` | **build + emulator host** (chosen 2026-10-06; on the LAN / Thunderbolt) | x86_64 bare metal, Ryzen AI 9 HX PRO 370 (24 threads), 91 GB RAM, 1.6 TB free on the `flash` SSD pool, `/dev/kvm` present. TrueNAS SCALE 25.10.7 appliance: build only inside a container/instance with a `flash` dataset, never on the host. Already busy (load ≈ 12, ~49 GB RAM used besides ZFS cache), so cap the build (`m -j12`, container memory limit). `faeton` currently lacks Docker and KVM access there. |
| `de1` | fallback build host | x86_64 bare metal, 8 threads, 62 GB RAM, 381 GB free, `/dev/kvm` present, Debian 13 (not a supported build OS — use a container) |
| MacBook | editor, `adb`, screen mirror | M3 Max; holds this repo and the sparse `src/` reference |

Source control. GrapheneOS is ~1000 git repos tied together by `platform_manifest`; only the
repos we change are forked, everything else syncs from upstream.

- Forks under `github.com/faeton`: `platform_frameworks_base` (LockSettingsService, users,
  SystemUI keyguard) and `platform_packages_apps_Settings`. Add `platform_system_vold` only if
  a stage needs it. Work branch in each: `envs-17`, created from upstream `17`.
- The build tree uses the upstream manifest plus `.repo/local_manifests/envs.xml`, which
  redirects those projects to the forks.
- The build tree uses `scripts/envs-local-manifest.xml` from this repo, symlinked as that local manifest.
- On `n5` the workspace is `/mnt/flash/scratch/grapheneos/` (`~/work/grapheneos` symlinks to
  it; `flash/scratch` is unsnapshotted and not backed up): `grapheneos-17/` (build tree,
  `repo init -b 17` done 2026-10-06), `bin/repo` (launcher), and `grapheneos-envs` → a symlink to
  this repo at `~/work/grapheneos-envs` on the backed-up `flash/home` (moved 2026-10-06).
- Open on `n5`: its SSH key is not registered with GitHub, so it can fetch the public forks but
  cannot push or pull this private repo yet; no `git-lfs`. Build output (`OUT_DIR`) stays under
  `flash/scratch`, never `flash/home`.

#### n5 workspace phases

Track for getting n5 from "source checked out" to "running Stage 1".

| Phase | Goal | Status |
|---|---|---|
| W0 | Workspace guide, repo on backed-up dataset, full tree synced | Guide + move done 2026-10-06. First sync (tmux `grapheneos`) died around 15:40 with 675/683 projects; missing `cts`, `frameworks/base`, `frameworks/layoutlib`, `hardware/ti/am57x`, `kernel/configs`, `kernel/prebuilts/6.1/{arm64,x86_64}`, `kernel/prebuilts/6.12/arm64`. Re-run 19:29 in tmux `grapheneos-sync` → `sync.log`: all 683 checked out; some fetches hit HTTP 429 from googlesource, but `repo sync -l` then finished cleanly (every project at its manifest revision). `frameworks/base` = `84183aff` (fork `envs-17` = upstream `17`, the SHA the docs cite). **Done 2026-10-06.** Re-sync (manifest now 1057 projects) finished with 3 HTTP-429 fetch failures (`external/{mp4parser,neon_2_sse,newfs_msdos}`); `-j1` retry of those succeeded, every project has `.git`, tmux `grapheneos-sync` removed 2026-10-08. |
| W1 | Build container on n5 with the scratch tree bind-mounted and `/dev/kvm` | **Prepared, not started** (2026-10-08): `workspace/build-env/` (Dockerfile, Ubuntu 24.04, uid 3000; `run.sh image|shell|build|emulator`, 48 GB memory cap, `-j12`, target `sdk_phone64_x86_64-cur-userdebug`). Docker chosen over Incus: TrueNAS Incus has no pool configured (`virt.global.config` `NO_POOL`), while hand-run Docker containers are already the norm on n5. Waiting for owner go-ahead. RAM is the constraint (~19 GB available on 2026-10-08 at 09:00); a ZFS ARC cap is being considered. |
| W2 | First emulator build of unmodified 17, headless, `adb` from m3max | Blocked on W1. Then `run.sh build` (log `build.log`), `run.sh emulator`, `ssh -L 5555:127.0.0.1:5555 n5` + `adb connect` on m3max |
| W3 | Re-verify docs 03/04/06 against the full tree; backlog B2–B8 | **Mostly done 2026-10-08**: refs verified (4 fixed); B2, B5, B6, B7 done; Stage 3 eviction and the `getVolumeList` claim verified; upstream issue and contribution norms checked. Left: B3 (diff 16 vs 17), B4 (stretch cost), B8 (Settings flow). |
| W4+ | Stages 1–6 below | — |

n5 facts as of 2026-10-06 19:30: load ≈ 0.4, ~35 GB RAM available, 645 GB free in `flash/scratch`
(700 GB quota, `.repo` is 41 GB). That quota covers the ~90 GiB source and ~100 GiB of build output.
- `patches/` stays the deliverable: `git format-patch upstream/17..envs-17` per stage.

Setup (human-run):

1. `n5`: container or TrueNAS instance (Debian bookworm or Ubuntu 24.04) with a `flash` dataset
   mounted, `/dev/kvm` passed through, and port 5555 reachable on the host's localhost.
2. In it: `repo init -u https://github.com/GrapheneOS/platform_manifest.git -b 17`, add the local
   manifest, `repo sync -j8`. Budget ~90 GiB (lightweight sync) + ~100 GiB build output. Emulator
   targets need no vendor files, kernel build, Vanadium or adevtool.
3. Lunch `sdk_phone64_x86_64`, `userdebug` variant, then `m -j12`. Start headless:
   `emulator -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect`.
4. Mac: `brew install android-platform-tools scrcpy`; `ssh -L 5555:127.0.0.1:5555 n5`;
   `adb connect 127.0.0.1:5555`; `scrcpy` for the screen (PIN entry at the real keyguard).
5. Edit in the full tree on `n5` (remote editor over SSH), commit on `envs-17`, push to the fork,
   export patches into `patches/NN-name/` here. `src/` on the Mac stays reference-only.
6. Loop: `m` and restart the emulator; for framework-only changes `adb root`, `adb remount`,
   `adb sync`, `adb shell stop && adb shell start` is faster (emulator started with `-writable-system`).

Not testable on the emulator: secure-element / Weaver throttling, eSIM wipe, the real boot chain.
The software rate limiter and all framework logic are. Check at Stage 0 whether the emulator
exposes a Weaver HAL at all (`adb shell service list | grep -i weaver`).

### Stage 1 — baseline experiments, no code

Unmodified GrapheneOS emulator build, scripted over `adb`. Each item answers an open question.

1. Owner PIN + one secondary user with its own PIN (`cmd lock_settings set-pin`, `pm create-user`).
2. Eviction: after `am switch-user 0`, is user N still unlocked (`am get-started-user-state N`)?
   After `am stop-user -f N`? With `no_run_in_background` set on N, a plain switch should stop
   and lock it (`UserController.java:2741-2747`) — if so, Stage 3 needs little or no code.
   *Code reading (2026-10-08) predicts:* plain switch → N keeps running and stays unlocked (stop-on-switch
   defaults off, `UserController.java:581-591`). With `no_run_in_background` → N is stopped and its CE key
   evicted asynchronously on FgThread (`:1702-1713` → `LockSettingsService.java:4015-4026` → vold), so
   poll `isUserUnlocked`/`am get-started-user-state` instead of checking immediately.
3. Boot order: `settings put global allow_user_switching_when_system_user_locked 1`, reboot,
   switch to N before the owner unlocks (`UserManagerService.java:3362-3367`). Record what breaks.
4. Duress works on the emulator via `set-duress-credentials` (`LockSettingsShellCommand.java:417`).
5. Lockout schedule observed with repeated wrong PINs (`SoftwareRateLimiter.java:107-129`).

### Stage 2 — `REBOOT_BFU` alternate credential (upstream-shaped)

Deliverable: `patches/02-reboot-bfu/` against frameworks_base (then Settings) + test log.

- 2a. system_server only: select the action instead of hard-coding it in `DuressPasswordHelper`;
  storage v1 with action byte and v0 upgrade; `RebootBfuAction`; shell command for enrolment.
- 2b. Settings screen modelled on `DuressPasswordSetupActivity`.
- 2c. Unit tests + manual matrix from doc 04.

### Stage 3 — environment B via the existing lockscreen user switcher

No new verifier. B is a secondary user; the user id is chosen on the lockscreen before any
credential is checked, so there is no cross-user throttling and no duress race.

**Code reading 2026-10-08: probably no framework patch needed.** Paths relative to
`frameworks/base/`; `UC` = `services/core/java/com/android/server/am/UserController.java`.

- **Eviction exists today without a device owner.** These two mechanisms are confirmed in the code:
  - Setting `DISALLOW_RUN_IN_BACKGROUND` on N makes every switch away from N call
    `stopUsersLU(N, allowDelayedLocking=false)` (`UC:2736-2747`). The owner can set it in
    Settings → Users → N → *Run in background* (`packages/apps/Settings/.../users/UserDetailsSettings.java:242-243`)
    or with `pm set-user-restriction --user N no_run_in_background 1`. Setting it while N is already in the
    background stops N at once (`UserRestrictionsUtils.java:735-742`).
  - Power-menu **End session** (`GlobalActionsDialogLite.java:1281-1305`) falls back to
    `ActivityManager.logoutUser` when no device-owner logout exists (`UserLogoutInteractor.kt:59-67`).
    That path switches to user 0 and then calls `stopUser(N, allowDelayedLocking=false)` (`UC:1182-1230`).
    It requires only that N is a non-system user allowed to switch (`UserManagerService.java:3396-3411`).
    The *device-owner* gate (`DevicePolicyManagerService.java:12652-12656`, `:19467-19472`) applies
    only to the DPM logout path.
- **Any stop of a full secondary user evicts its key** on GrapheneOS defaults:
  - `config_multiuserDelayUserDataLocking` is false (`core/res/res/values/config.xml:3307`), and
    only the Private-space user type allows delayed locking (`UserTypeFactory.java:345`). So
    `canDelayDataLockingForUser` returns false (`UC:1785-1794`).
  - The eviction chain is `finishUserStopped` → `dispatchUserLocking` → `LockSettingsInternal.lockUser` →
    `StorageManager.lockCeStorage` and keystore lock (`UC:1660-1713`).
  - The eviction is skipped if N is restarted before the FgThread task runs (`UC:1709-1711`).
- **Without the restriction**, a plain switch leaves N running and unlocked until one of these:
  - an LRU stop past the running-user limit (`maxRunningUsers = max(RAM_GB-2, 3)`,
    `ActivityManagerService.java:9733-9736`);
  - 26 h of background (`config_backgroundUserConsideredDispensableTimeSecs`);
  - an explicit stop.
- `UserControllerHelper` (GrapheneOS) only adds the per-user `disallow_delayed_locking_on_user_stop`
  setting (`UserControllerHelper.java:14-24`, read at `UC:1786`). It matters only for Private space.
- 3a. Confirm on the emulator (Stage 1 item 2) that the restriction plus End session behave as
  read. Patch only if Stage 3 must not depend on a setting. The minimal patch would be in
  `stopUserOnSwitchIfEnforced` (`UC:2741-2747`).
- 3b. The per-user toggle already exists: *Run in background*, off. The remaining work is
  UX: say clearly that turning it off evicts the user's keys on every switch.

### Stage 4 — automatic PIN dispatch (fork-only)

"The PIN decides": a credential typed at the keyguard is tried against the other environment
when it does not match the selected user. PIN-only, owner already unlocked since boot.

- 4a. Keyguard-only verify flag; second verification through user N's normal protector;
  duress check completed before the second verification; result names the target user;
  switch + dismiss for that user. In-app confirmation prompts never carry the flag.
- 4b. Accounting: a successful dispatch must not be reported as an owner failure
  (`KeyguardSecurityContainerController.java:1300`); remove the matched credential from the
  other user's wrong-guess cache (`SoftwareRateLimiter.java:400`); a throttled user blocks fallthrough.
- 4c. Try the last-used user first (stored user id, not credential-derived); measure counters
  over a scripted week of crossings.
- 4d. PIN A typed while B is foreground: switch to user 0, then stop N as in Stage 3.
- 4e. Enrolment-time collision check of PIN B against duress / alternates / PIN A.

### Stage 5 — B before A after boot (experiment, may be dropped)

Only if Stage 1 item 3 looked workable. Decide in/out and record it in doc 00.

### Stage 6 — real device (manual)

Dedicated test Pixel, own signing keys, never a daily device. Purpose: hardware throttling
behaviour that the emulator cannot show.

### Upstream conversation

- After Stage 2: short proposal for `REBOOT_BFU` — motivation, diff size, properties preserved
  (P1–P5 in doc 03), rules D1–D6 in doc 04, open questions Q1–Q5.
- After Stage 3: the always-evict session end, if it turned out to need a patch.
- Stages 4–5 stay in the fork unless maintainers ask.
- Post where maintainers ask for it (issue tracker / development chat); expect design changes.

How GrapheneOS takes contributions (checked 2026-10-08):
- Code goes in as GitHub PRs on the per-component repos (e.g. `platform_frameworks_base`), and
  external PRs do get merged.
- Feature requests go to `os-issue-tracker`. Discussion goes to the chat rooms or forum, not the
  tracker ("Please don't use the issue tracker for discussion",
  [#29](https://github.com/GrapheneOS/os-issue-tracker/issues/29)).
- Style is upstream style: 4-space indent, braces always, 100 columns
  (<https://grapheneos.org/build>, *Development guidelines*). Expect maintainers to split,
  reword and reorder commits. Upstream licences stay as they are, and there is no CLA.

### Not planned

- Multi-OS / multi-slot boot (doc 06).
- Environment concealment / deniability (doc 00, non-goals).
- There is no doc 05.

## Backlog

Each item is self-contained; write findings into the named doc, with citations.

| # | Task | Output |
|---|---|---|
| B1 | Re-verify all line references after the next `sync-src.sh` | docs 03/04/06 |
| B2 | ~~Trace every caller of `doVerifyCredential` and list which UI surfaces reach it~~ **done 2026-10-08** (7 sites) | doc 03 |
| B3 | Diff duress code between branches `16` and `17` (did the hook move?) | doc 03 |
| B4 | Measure/estimate stretch cost per failed attempt with N alternates (D6) | doc 04 |
| B5 | ~~Find how the `Secondary` lock domain (fingerprint second factor) interacts with the hook~~ **done 2026-10-08**: duress fires there too | doc 04 Q4 |
| B6 | ~~Find the locksettings unit tests covering duress, list what exists~~ **done 2026-10-08**: none at unit level; host test `DuressPasswordTest` is the template | doc 04 test plan |
| B7 | ~~Locate fstab / first-stage mount sources on branch `17`; fix sparse paths~~ **done 2026-10-08**: `system/fs/fs_mgr`; emulator is not A/B | doc 06, sync script |
| B8 | Draft the Settings screen flow by reading `DuressPassword*Activity` | doc 04 |

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
