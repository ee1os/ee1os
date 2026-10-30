# 08 — Development environment, testing, phases

How the work in `07-roadmap.md` is built and tested. The stage *content* lives there; this
doc is the procedure.

## Machines

GrapheneOS builds only on x86_64 Linux (<https://grapheneos.org/build>).

| Machine | Role |
|---|---|
| `n5` | Build host and emulator host. TrueNAS SCALE, so nothing is installed on the host: the build runs in a Docker container. 24 threads, 91 GB RAM shared with Immich, ollama etc. → `-j8`, 28 GB container cap, one highmem job. |
| m3max | Editor (remote over SSH), `adb`, `scrcpy` for the emulator screen. |
| test Pixel | Pixel 8 Pro (husky, Titan M2), set aside for this project; stock Android 16 as of 2026-10-11. Stage 6 only. Own signing keys, never a daily phone. |
| `de1` | Fallback build host (8 threads, 62 GB RAM, Debian 13 → same container). |

## Layout on n5

```
/mnt/flash/scratch/grapheneos/          (= ~/work/grapheneos; not snapshotted, not backed up)
  grapheneos-17/                        repo tree, branch 17 + local manifest
    .repo/local_manifests/envs.xml  ->  os-ivan-gg/scripts/envs-local-manifest.xml
    out/                                build output (~100 GiB)
  os-ivan-gg/                       ->  ~/work/os-ivan-gg  (this repo; backed up)
  bin/repo                              repo launcher
  build.log, sync.log
```

Nothing that can't be rebuilt lives under `flash/scratch`. Commits go to the forks on GitHub
and to this repo.

## Source control

- Everything is in the GitHub organization [os-ivan-gg](https://github.com/os-ivan-gg) (since
  2026-10-13; the forks were moved from `faeton/`, whose URLs redirect). Forked repos, all on
  branch `envs-17` (created from GrapheneOS `17`): `platform_frameworks_base`,
  `platform_packages_apps_Settings`, `platform_packages_apps_SetupWizard2`,
  `platform_system_sepolicy`, `platform_packages_apps_Updater` (update URL), and
  `platform_build` (since 2026-10-15, created from tag `2026100600`; keeps GrapheneOS's boot
  animation out, doc 00). Add
  `platform_system_vold` only if a stage needs it. The local manifest
  (`scripts/envs-local-manifest.xml`) points those projects at the forks; everything else syncs
  from GrapheneOS. Other repos: `os-ivan-gg` (this one), `manifest`, `releases`, `site`, and
  `.github` (the organization's front page).
- Work in the tree: `repo start dev frameworks/base packages/apps/Settings`, commit there,
  push with `git push fork HEAD:envs-17`. n5 has no GitHub SSH key; push over HTTPS
  (`gh auth setup-git` once, then
  `git push https://github.com/os-ivan-gg/platform_frameworks_base HEAD:envs-17`).
- One commit series per stage. When a stage is done, tag it in each fork (`stage2`) and export
  it here: `git format-patch fork/17..HEAD -o <this repo>/patches/02-reboot-bfu/`.
- Commit style: short subject in the imperative, upstream style, no noise.
- **Rebase routine** when GrapheneOS publishes a release (about weekly; tags like
  `2026100600` in every repo): `scripts/track-upstream.sh` does it nightly (doc 07 R5). Only
  release tags: never merge or rebase onto upstream branch `17` between releases, it is their
  development line and a merge breaks the next rebase (doc 00 decision 2026-10-15). By hand:
  1. `repo init -b refs/tags/<tag> && repo sync -j8` (in tmux, log to `sync.log`);
  2. in each fork project: `git rebase --onto refs/tags/<tag> <old base> envs-17`, then
     `git push -f fork envs-17`; the script keeps the old base per repo in `state/base/`;
  3. rebuild, rerun the regression gate (below), update pinned SHAs in doc 01, re-verify
     line references (backlog B1).
- **Watching upstream between releases:** `scripts/upstream-watch.py preview` (nightly) compares
  our release tag (or the release held for approval, which `envs-17` already carries) with
  upstream branch `17` and flags what needs a decision before the next
  release: projects added or removed, a new AOSP base, commits touching files our forks
  change, and commits in the areas we depend on (credentials, duress, keyguard, boot animation
  and branding, product packages, Updater, setup, users, storage, private space). Routine
  changes are listed, not flagged. Reports go to `upstream-watch/` next to the tree; new
  flags go to klava hq (OS topic) once. If `state/review-hook` is an executable, it gets each flagged
  report and its impact review is saved as `<report>-review.md`. The message leads with the
  review's verdict (decision needed / test first / nothing to do) and its to-do lines, and
  reminds about a held release with the `APPROVE=`/`SKIP=` commands (the hook is local to n5, not part of this repo; the report is untrusted upstream text, so
  the hook may only read files). Projects whose history went backwards or that are past
  GitHub's compare limits (250 commits, 300 files) are flagged as well.
- **Strategic releases wait for the owner:** `track-upstream.sh` runs `upstream-watch.py check
  <tag>` first. If it flags anything, the release is synced, rebased, built and gated as usual
  but not pushed; the message links the report. `APPROVE=<tag> scripts/track-upstream.sh`
  pushes it (refused if a fork's `envs-17` moved since the build or `out/` holds another
  build); `SKIP=<tag>` drops it and puts the forks back. While one is held, a newer release is
  announced once and waits. Routine releases go through on their own.
- **Safety rules of `track-upstream.sh`:** it starts only when every fork's local `envs-17`
  equals the fork on GitHub, rebases from `state/base/<repo>` (the upstream commit under
  `envs-17`, seeded 2026-10-15 with the `2026100600` commits), puts the branches back on any
  failure before the push, and pushes with `--force-with-lease` against what it rebased
  from. Vendor modules (`vendor/google_devices/<model>`) are generated by adevtool, not synced,
  and refuse to build once a sync moves `vendor/adevtool` past the commit they were made with
  (`adevtool-version-check.mk`). After the rebase the script regenerates each outdated module
  (husky first, then every other model in the tree) with `scripts/vendor-module.sh <model>` in
  the build container, ollama paused; the stock factory image is downloaded into
  `vendor/adevtool/dl/` when the release needs a new one. A failure stops the run like a failed
  build. Decided 2026-10-19: release 2026101600 moved adevtool and its first build failed at
  product config. After the sync it also stops if any project has files missing from its
  checkout: `repo sync` reported success for 2026101600 while `external/talkback` lacked its
  prebuilt APK (objects never fetched); deleting that project and syncing it again fixed it.
  A build that ships any `bootanimation*.zip` is refused (no GrapheneOS boot animation,
  doc 00). A release counts as done (`state/upstream-tag`) only when the forks and the manifest
  are pushed. The manifest's `envs-17` follows the fork branches; its `<tag>.os` tag sits on
  a commit that pins the forks to their `<tag>.os` tags, so a release can be synced again
  exactly.
- **Tree check before anything runs or is signed** (decided 2026-10-30): `scripts/verify-tree.sh`
  fails, with every reason, unless the tree is exactly what was reviewed. Fork commits over the
  upstream tag (`HEAD`, not the fork on GitHub) must match `patches/approved.txt` as committed
  in this repo's `HEAD`, by patch-id: no extra, none missing, no merge or empty commits. Each
  fork must sit on the tag's commit, the tag signed by GrapheneOS
  (`scripts/grapheneos-allowed-signers`, from grapheneos.org/allowed_signers) and pinned by the
  tag's signed `default.xml`. Every other project must be at that manifest's revision, with no
  project it doesn't list; `.repo/local_manifests` holds only `envs.xml`. No project may have
  uncommitted, untracked (in the forks also ignored) files, assume-unchanged or skip-worktree
  entries, replace refs or grafts. The tree root holds only project dirs, linkfile/copyfile
  targets matching their sources, `out*/`, `keys/` and `releases/`. Each generated vendor
  module matches `state/vendor/<model>` (adevtool commit, factory image with its SHA-256, a hash
  over paths, modes, link targets and contents), written by `vendor-module.sh`; husky and
  stallion were recorded from their existing modules on 2026-10-30 (adevtool `78aac18c`,
  images `cp3a.261005.005`, SHA-256 equal to Google's in the file names). About 7 s on n5.
  - `scripts/approve.sh <repo> <commit>...` adds lines (`<repo> <patch-id> <short-sha>
    <subject>`, only the first two are checked); `--draft` lists every commit over the tag. It
    doesn't commit: the owner reviews and commits `approved.txt` from m3max. The first list
    (63 commits on `2026102100`) became the reference with the owner's OK.
  - Patch-id: `git show --binary --full-index --no-renames`, no user config, then `git patch-id
    --verbatim` (whitespace counts; it can't be combined with `--stable`, and file order is
    fixed by git anyway). A clean rebase keeps it: all 62 commits kept their ids from
    `2026101600` to `2026102100`. A rebase that changes a commit (conflict, changed context)
    gives a new id, and that commit is approved again. Reason: patch-ids survive the nightly
    rebase where commit SHAs don't; what upstream changes around our patches is
    `upstream-watch.py`'s job.
  - `release.sh` checks before the build (an unreviewed `build/make` runs at `lunch`), builds in
    an emptied `out_release/` (its old outputs and otatools would be signed or run otherwise),
    checks again, then signs. No way around the check. The signing keys and the passphrase
    are in the container only for the signing step: `run.sh` covers `keys/` and `.secrets/`
    with an empty root-only tmpfs unless `KEYS=1`; the build doesn't read them.
  - `track-upstream.sh` checks after the rebase and before the build. If the only failures are
    commits to approve, it builds and holds the release like a strategic one (approve, commit
    `approved.txt`, then `APPROVE=<tag>`); any other failure stops it and puts the forks back.
    Its push (`publish()`, also for `APPROVE=`) checks again.
  - Not covered: root or the owner's shell on n5 (it can change the check itself); moving
    signing off n5 is a separate task. Approvals are checked against SSH signatures once
    `/mnt/tank/scripts/os-ivan-gg/allowed_signers` (root's, outside the repo) exists; until
    then anyone who can commit to this repo's `HEAD` on n5 can approve.
- **Schedule** (TrueNAS cron, `sudo midclt call cronjob.query`): job 25 runs the preview at
  00:30, job 26 `track-upstream.sh` at 01:00 (n5 time, Europe/Lisbon). Logs:
  `upstream-watch.log` and `track-upstream.log` next to the tree.
- **Scripts:** `scripts/track-upstream.sh` (follow GrapheneOS, `DRY_RUN=1` to only detect and
  list the vendor modules it would regenerate), `scripts/vendor-module.sh` (adevtool, in the container), `tests/gate.sh` (atest and
  `tests/keyguard.sh` on the emulator),
  `scripts/release.sh` (sign and publish, run by the owner), `scripts/pack-flash.sh` (images
  for `fastboot flashall`). All report to klava hq, topic "OS" (890), through `/mnt/tank/scripts/notify-telegram.sh`.

## Build container

`workspace/build-env/` — `Dockerfile` (Ubuntu 24.04, AOSP build deps, uid 3000 so files stay
owned by `faeton`) and `run.sh`:

| Command | Does |
|---|---|
| `run.sh image` | build the image `grapheneos-build:24.04` (done 2026-10-09, 757 MB) |
| `run.sh shell` | interactive shell, `lunch` done |
| `run.sh build [targets]` | `m -j12 [targets]`, appends to `build.log` |
| `run.sh emulator` / `emulator-stop` | headless emulator in the background, adb on n5's `127.0.0.1:5555` |
| `run.sh exec '<cmd>'` | one command with `lunch` done, e.g. `adb`, `atest`, `tests/*.sh` |

Defaults: `LUNCH=sdk_phone64_x86_64-cur-userdebug`, `JOBS=8`, `MEM=28g`, `HIGHMEM=1`; all
overridable by environment.

Phone builds also set `BUILD_NUMBER` and `BUILD_DATETIME`: `build/envsetup.sh` otherwise keeps
the number from `out/soong/build_number.txt`, so a new image would show the old one. `OUT_DIR`
gives a target its own output tree (e.g. `OUT_DIR=out_husky`): switching one tree between the
emulator and the phone redoes Soong's analysis and recompiles for the other architecture.
`run.sh build` logs `m`'s own exit code as `M_EXIT=` in `build.log`.

Memory: Soong sizes its highmem pool (metalava, R8, …) from the host's RAM via `sysinfo`
(`build/soong/ui/build/config_linux.go:19-27`, `config.go:1588-1616`). Inside the container
it sees all 91 GB and ignores the cap, so `run.sh` passes `NINJA_HIGHMEM_NUM_JOBS`. n5 has
no swap: exceeding the cap kills the build, not other services. The largest single process is
Soong's analysis of the whole tree. **Measured 2026-10-10:** `run.sh build nothing` with a
28 GB cap. `soong_build` was OOM-killed inside the container at 29 GB RSS, about 2 minutes
in; other services were unaffected. The analysis can't be made smaller from outside:
`soong_build` runs under `env -i` (no `GOMEMLIMIT`/`GOGC`) and with `GOMAXPROCS` = all CPUs
(`build/blueprint/bootstrap/command.go:71`). So a build host needs more than 28 GB for the
container.

What worked on n5 (2026-10-10):
- 24 GB zram swap, zstd, in RAM only; gone on reboot. Never swap on ZFS.
  `sudo modprobe zram && echo zstd | sudo tee /sys/block/zram0/comp_algorithm && echo 24G | sudo tee /sys/block/zram0/disksize && sudo mkswap /dev/zram0 && sudo swapon -p 100 /dev/zram0`
- The ollama model unloaded for the analysis (`ollama stop <model>`; the service keeps running).
- `MEM=44g MEMSWAP=68g run.sh build nothing`: analysis done in 2:20, peak **36 GB**, n5 never
  below 24 GB available.
- The analysis reruns when `Android.bp`/`.mk` files change **or a source file is added or
  removed** under a glob ("Globs changed, rerunning soong"). Edits to existing files go straight
  to compiling, which is where `JOBS`/`HIGHMEM` matter.
- A guard runs next to every long build: `/mnt/flash/scratch/grapheneos/guard.sh` in the build's
  tmux session. It kills the container below 4 GB available and logs to `mem.log`. On
  2026-10-10 it killed a re-analysis with the emulator (5.5 GB) and an ollama model loaded;
  stop the emulator (`run.sh emulator-stop`) before a build that adds files.

Incremental build times on n5 (2026-10-10, `JOBS=12 HIGHMEM=2 MEM=44g`):

| Change | Steps | Time | Peak container RAM |
|---|---|---|---|
| new files in `services/core` + an `ILockSettings.aidl` method (framework.jar changes, everything above it recompiles) | ~4500 | 46:46 | 43.7 GB (into swap), during the SystemUI compile |
| edits to existing `services/` files only | small | 2:48 | — |
| `services/` edits + a new test file in `servicestests` (analysis rerun, no framework.jar change), `droid FrameworksServicesTests`, 2026-10-11 | ~520 after analysis | 6:15 | 31.5 GB during analysis; n5 down to 9 GB available with the emulator stopped |
| test module only, existing files edited | small | <1 min | — |

So keep framework (`core/`) API changes rare and batch them.

The container uses host networking, so adb and the emulator ports are on
n5's loopback. From m3max: `ssh -L 5555:127.0.0.1:5555 n5`, `adb connect 127.0.0.1:5555`,
`scrcpy`.

Known: Soong prints "Build sandboxing disabled due to nsjail error" inside Docker. Builds
still work; the sandbox only guards against undeclared inputs.

## Edit–build–test loop

- First build: `run.sh build` (hours; watch `build.log`). Then `run.sh emulator`.
- Framework change (`frameworks/base/services`): `run.sh build services`, then
  `adb root && adb remount && adb sync && adb shell stop && adb shell start`.
  Needs the emulator started with `-writable-system` (default in `run.sh`).
- Settings change: `run.sh build Settings`, then the same `adb sync` + restart.
- Anything touching resources shared with SystemUI or the boot image: full `run.sh build` and
  restart the emulator.
- After a test that wipes (duress): `run.sh emulator-stop`, then
  `EMU_ARGS=-wipe-data run.sh emulator`.

## Test levels

| Level | What | Where | Command |
|---|---|---|---|
| T0 | It builds, no new warnings in touched files | container | `run.sh build` |
| T1 | Unit tests, locksettings | emulator (instrumentation) | `run.sh exec 'atest FrameworksServicesTests:com.android.server.locksettings'` |
| T2 | Host tests: GrapheneOS `DuressPasswordTest`, later `RebootBfuTest` | a target with a Weaver HAL (test Pixel; goldfish has none) | `run.sh exec 'atest DuressPasswordTest'` |
| T3 | Scripted scenarios over adb (`tests/*.sh`) | emulator | `run.sh exec /src/os-ivan-gg/tests/stage1.sh <item>` |
| T4 | Manual matrix at the real keyguard and in Settings | emulator via `scrcpy` | checklist below |
| T5 | Hardware behaviour | test Pixel | Stage 6 checklist |

Results: one file per run in `tests/results/` (`YYYY-MM-DD-<stage>-<level>.md`, build
fingerprint first line: `adb shell getprop ro.build.fingerprint`).

The emulator shares one adb server with every `run.sh exec` container (host network), so no
`adb connect` is needed. atest keeps its logs in the container's `/tmp`, which is gone after the
run; copy them out when a run needs a closer look:
`run.sh exec 'atest … > /src/t1.log 2>&1; cp -rL /tmp/atest_result_faeton/CURRENT /src/t1-logs'`.
The first atest run builds TradeFed, so don't pass `-it` to it. Instrumentation needs user 0 in
front and unlocked: after a reboot test, run `cmd lock_settings verify --old <owner PIN>` first.
Otherwise TradeFed reports the device unresponsive and reboots it (`sys.boot.reason` =
`reboot,shell`).

**Regression gate** (every change, every rebase): T0, T1, and duress on the emulator
(`tests/stage1.sh duress --yes-wipe`, then `EMU_ARGS=-wipe-data run.sh emulator`). Duress must
still fire from every prompt it fires from today (doc 00 hard requirement). The script enters the
duress PIN through `cmd lock_settings verify`; `adb shell input text` doesn't reach the keyguard
bouncer on this build. Taps on the pad keys and single key events do: `tests/keyguard.sh`
types A's and B's PINs at the real bouncer both ways, locks B with an app open and checks that
A's lock screen comes back with nothing of B on top, and that the pad still sends every entry
during a lockout. Screenshots of the bouncer come out black (secure window), so it reads the
screen with uiautomator. `tests/gate.sh` runs it on a second wiped emulator after the atest
runs. Decided 2026-10-21: release 2026101600 changed the PIN pad's focus and the keyguard's
occlusion right next to our dispatch, and no automatic check typed at the lock screen.
Duress at the bouncer stays a T4/T5 check (it wipes).
`DuressPasswordTest` can't run on goldfish: it asserts Weaver reads after every verify
(`DuressPasswordTest.java:59`), so it runs at T5 on the test Pixel.

Known baseline failures (stock GrapheneOS 17, `tests/results/2026-10-10-stage0-T1-T2.md`):

- T1: `WeaverHidlBasedSyntheticPasswordTests` doesn't load. Its parent switched to
  `JUnitParamsRunner` in `18b79a00` but the HIDL subclass still uses `AndroidJUnit4`
  (`WeaverHidlBasedSyntheticPasswordTests.java:28`), so atest reports "Completed With ERRORS".
  Everything else passes.
- T2: fails at `:59` on goldfish (no Weaver). The second test then fails at `:52` because the
  first left a password set.

What the emulator can't show: secure-element / Weaver throttling (goldfish has no Weaver HAL,
so lockout is the software limiter, doc 03), eSIM wipe, verified boot with our own key, A/B
slots (goldfish is not A/B, doc 06).

**The test Pixel** (Pixel 8 Pro `3A101FDJG000C4`) holds real data in B since 2026-10-30: updates
by OTA, tests over adb only. No wipe, `-w` flash or duress PIN on it without the owner's OK for
that run; duress-wipe tests run on another device. Its USB-C port is set to "Charging-only when
locked, except before first unlock" (T12). Leaving B with the power button switches to A's
locked lock screen and adb disappears (from the Mac's USB list too) until A is unlocked: the new
USB session after the switch counts as locked. Locking inside A, and locking B after a
reboot-PIN boot (A still before first unlock), keep adb (T13). Drivers stop at that step and
wait for the owner to unlock A; don't count the steps run meanwhile as results. Not yet
confirmed against the setting itself (shell can't read `persist.security.usb_mode`).

## Phases

Each stage from the roadmap runs through the same steps: read → build → test → record. The
gate says when a stage is done.

| Stage | Dev work | Tests | Gate |
|---|---|---|---|
| 0 | container, first build, emulator up | T0; T1 + T2 on unmodified build as **baseline** | baseline recorded in `tests/results/`, failures there are known and listed |
| 1 | none (unmodified build) | T3 `tests/stage1.sh` items 1–5, T4 for keyguard steps | every item has an observed result; doc 07 Stage 1/3/5 updated with it |
| 2a | `frameworks/base`: reboot credential slot, `RebootBfu`, shell command, collision checks, lifecycle | T0, T3 `tests/stage2.sh` (every item), T1 incl. `AlternateCredentialsTests` (real helper, counting actions), regression gate | every check prints PASS; stock T1 unchanged; duress unchanged |
| 2b | `packages/apps/Settings`: Reboot PIN screens | T0, T3 `tests/stage2b.sh screens` (uiautomator), T4 Settings checklist | enrol / update / delete / collision errors work; no-lock, corrupt-record and second-factor states checked in T4 |
| 2c | `RebootBfuTest` host test | T2, T4 matrix | matrix fully green, wrong-PIN timing unchanged (D4) |
| 3 | `AccountsDb` close fix (3c); maybe wording in Settings | T3 eviction scenarios, `tests/stage3.sh openfiles`, T4 End session | eviction confirmed for restriction and End session; no CE file open after a stop |
| 4 | keyguard dispatch (fork-only) | T1, T3 crossing script, T4 | design notes 1–7 in doc 07 each covered by a test |
| 5 | experiment; backup fix; storage service on the first unlocked user | T3 `tests/stage5.sh storage` | every check PASS, then in/out decision recorded in doc 00 |
| 6 | flash test Pixel (manual) | T5 | hardware throttling and wipe observed |

### T4 checklist for `REBOOT_BFU` (Stage 2)

1. Owner PIN unlocks normally; nothing else happens.
2. Reboot PIN at the keyguard → device reboots; after boot it asks for the PIN (BFU).
3. Reboot PIN at an in-app credential confirmation (Settings → re-enter PIN) → reboots.
4. Reboot PIN at the fingerprint second-factor prompt → reboots (doc 04 Q4).
5. Duress PIN still wipes from the keyguard (destructive, last).
6. Enrolment rejects: reboot PIN = owner PIN, = duress PIN, = second-factor PIN. The
   collision checks add no failed attempt (the owner check itself may reset earlier ones).
7. A wrong PIN looks the same (message and timing) with 0, 1 and 2 alternates enrolled.
8. Storage upgrade: duress enrolled on an unmodified build, then the patched build boots and
   duress still wipes.
9. With PIN auto-confirm on, a reboot PIN of another length than the owner PIN: note when it
   can be submitted (the OK button is hidden until it is, `KeyguardPinViewController.java:113-121`).
10. Lockout countdown: the service fires the reboot PIN even then (doc 04 *Decisions*, Q5),
    but the keyguard blocks input during the countdown. Note which prompts still accept it.
11. Boot reason after the reboot PIN equals the one after a power-menu restart.

### Stage 6 (manual, human-run)

First pass (decided 2026-10-11, owner): a `husky-cur-userdebug` build with test keys, flashed
with the bootloader left unlocked (`verifiedbootstate` = `orange`), so root and `adb` are
available for the Weaver measurements (doc 04, *Weaver-backed alternates*); nothing from
official GrapheneOS goes on the device first. The vendor module comes from adevtool
(`vendor/adevtool/bin/run generate-all -d husky`), with its helper tools from the main `out/`:
`run.sh exec scripts/vendor-module.sh husky`, which the tracker also runs after a sync that
moves adevtool.
Second pass: build for the device target with release signing (GrapheneOS build guide, *Generating
release signing keys*), flash with the bootloader unlocked, set our AVB key, lock the
bootloader again. In the tree: `script/generate-keys husky` (keys under `keys/husky/`, AVB key
`avb.pem`, public part `avb_pkmd.bin`; owner-run, backed up offline), then `m
target-files-package otatools-package` and `script/finalize.sh`, then
`script/generate-release.sh husky <BUILD_NUMBER>` for the signed factory image and update
package under `releases/`. On the phone (owner-run): `fastboot erase avb_custom_key`,
`fastboot flash avb_custom_key avb_pkmd.bin`, flash the signed images, `fastboot flashing
lock` (wipes). A userdebug build signed with the same keys keeps root for tests; once locked,
every image must carry these keys. Then repeat the T4 checklist and observe Weaver throttling with repeated
wrong PINs. Never automated from this repo.

One key set for all models (decided 2026-10-14, owner): the keys made for husky also sign
every other model, so there is one passphrase, one backup and one verified boot fingerprint
(`65894abf…f161`) on the site. GrapheneOS uses a set per model, which limits a leak to one
model; with one holder and one build machine that buys little here. A new model gets
`keys/<codename>` as a copy of `keys/husky`, its vendor files from adevtool
(`generate-all -d <codename>`), then `DEVICE=<codename> scripts/release.sh`. Each model
still needs its own build: the images carry that model's kernel, drivers and firmware.
Moving a model to its own keys later means a wipe and reinstall on its phones.

No security preview releases (decided 2026-10-15, T9 U2): GrapheneOS's preview builds carry
embargoed patches we don't get, so there is nothing to publish on those channels. The Updater
fork ignores and hides the opt-in and no longer offers its screen, which makes setup skip that
step (`UpdaterSecurityPreviewActivity`, SetupWizard2). Each release publishes every channel
file the Updater can ask for (stable, beta and alpha for a user build, all the same build) and
a `-security-preview` copy of each for phones that opted in on 2026101406, the only build that
offered it. Reason: a phone asking for a missing channel file never updates, silently.

Checklist for the first session, shell first so the hour goes to what only hardware shows
(userdebug-style `adb` access is assumed for the shell steps; on a user build use the
screens). Record each result in `tests/results/` like the emulator runs.

1. Baseline: owner PIN, envB with its own PIN (`stage1.sh setup`). `getprop
   ro.boot.verifiedbootstate` = `yellow` (own AVB key, locked).
2. Weaver: wrong owner PINs one at a time, note each response and timeout
   (`cmd lock_settings verify --old 0000`), stop before a long lockout. Compare with the
   emulator (software limiter only, Stage 1 item 5).
3. Reboot PIN at the owner's and envB's prompt (`stage2.sh reboot`, `reboot-b`): BFU after
   boot, owner data intact, boot reason equal to a power-menu restart.
4. Armed escrow: `cmd recovery request-lskf com.android.shell`, unlock, `cmd recovery
   is-lskf-captured com.android.shell` = true, then the reboot PIN. After boot the owner
   must be `RUNNING_LOCKED`. Then once with a real resume-on-reboot update, to see that the
   normal path still works when the reboot PIN isn't used.
5. Duress, last: duress PIN at the keyguard; device off, next boot can't decrypt, eSIM gone.
   Reflash afterwards.
6. Stage 5 on hardware, if still in: `stage5.sh storage`.

