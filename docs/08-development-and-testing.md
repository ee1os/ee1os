# 08 — Development environment, testing, phases

How the work in `07-roadmap.md` is built and tested. The stage *content* lives there; this
doc is the procedure.

## Machines

GrapheneOS builds only on x86_64 Linux (<https://grapheneos.org/build>).

| Machine | Role |
|---|---|
| `n5` | Build host and emulator host. TrueNAS SCALE, so nothing is installed on the host: the build runs in a Docker container. 24 threads, 91 GB RAM shared with Immich, ollama etc. → `-j8`, 28 GB container cap, one highmem job. |
| m3max | Editor (remote over SSH), `adb`, `scrcpy` for the emulator screen. |
| test Pixel | Stage 6 only. Dedicated device, own signing keys, never a daily phone. |
| `de1` | Fallback build host (8 threads, 62 GB RAM, Debian 13 → same container). |

## Layout on n5

```
/mnt/flash/scratch/grapheneos/          (= ~/work/grapheneos; not snapshotted, not backed up)
  grapheneos-17/                        repo tree, branch 17 + local manifest
    .repo/local_manifests/envs.xml  ->  grapheneos-envs/scripts/envs-local-manifest.xml
    out/                                build output (~100 GiB)
  grapheneos-envs/                  ->  ~/work/grapheneos-envs  (this repo; backed up)
  bin/repo                              repo launcher
  build.log, sync.log
```

Nothing that can't be rebuilt lives under `flash/scratch`. Commits go to the forks on GitHub
and to this repo.

## Source control

- Forked repos, all on branch `envs-17` (created from GrapheneOS `17`):
  `faeton/platform_frameworks_base`, `faeton/platform_packages_apps_Settings`. Add
  `platform_system_vold` only if a stage needs it. The local manifest points those projects at
  the forks; everything else syncs from GrapheneOS.
- Work in the tree: `repo start dev frameworks/base packages/apps/Settings`, commit there,
  push with `git push fork HEAD:envs-17`. n5 has no GitHub SSH key; push over HTTPS
  (`gh auth setup-git` once, then
  `git push https://github.com/faeton/platform_frameworks_base HEAD:envs-17`).
- One commit series per stage. When a stage is done, tag it in each fork (`stage2`) and export
  it here: `git format-patch fork/17..HEAD -o <this repo>/patches/02-reboot-bfu/`.
- Commit style: short subject in the imperative, upstream style, no noise.
- **Rebase routine** when GrapheneOS moves `17` (new monthly release):
  1. `repo sync -j8` (in tmux, log to `sync.log`);
  2. in each fork project: `git fetch fork && git rebase fork/17` (or the new upstream ref),
     then `git push -f fork HEAD:envs-17`;
  3. rebuild, rerun the regression gate (below), update pinned SHAs in doc 01, re-verify
     line references (backlog B1).

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
- The analysis reruns only when `Android.bp`/`.mk` files change. Java edits go straight to
  compiling, which is where `JOBS`/`HIGHMEM` matter.
- A guard runs next to every long build: `/mnt/flash/scratch/grapheneos/guard.sh` in the build's
  tmux session. It kills the container below 4 GB available and logs to `mem.log`. The container uses host networking, so adb and the emulator ports are on
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
| T3 | Scripted scenarios over adb (`tests/*.sh`) | emulator | `run.sh exec /src/grapheneos-envs/tests/stage1.sh <item>` |
| T4 | Manual matrix at the real keyguard and in Settings | emulator via `scrcpy` | checklist below |
| T5 | Hardware behaviour | test Pixel | Stage 6 checklist |

Results: one file per run in `tests/results/` (`YYYY-MM-DD-<stage>-<level>.md`, build
fingerprint first line: `adb shell getprop ro.build.fingerprint`).

The emulator shares one adb server with every `run.sh exec` container (host network), so no
`adb connect` is needed. atest keeps its logs in the container's `/tmp`, which is gone after the
run; copy them out when a run needs a closer look:
`run.sh exec 'atest … > /src/t1.log 2>&1; cp -rL /tmp/atest_result_faeton/CURRENT /src/t1-logs'`.
The first atest run builds TradeFed, so don't pass `-it` to it.

**Regression gate** (every change, every rebase): T0, T1, and duress on the emulator
(`tests/stage1.sh duress --yes-wipe`, then `EMU_ARGS=-wipe-data run.sh emulator`). Duress must
still fire from every prompt it fires from today (doc 00 hard requirement). The script enters the
duress PIN through `cmd lock_settings verify`; `adb shell input text` doesn't reach the keyguard
bouncer on this build, so the keyguard itself is a T4 check.
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

## Phases

Each stage from the roadmap runs through the same steps: read → build → test → record. The
gate says when a stage is done.

| Stage | Dev work | Tests | Gate |
|---|---|---|---|
| 0 | container, first build, emulator up | T0; T1 + T2 on unmodified build as **baseline** | baseline recorded in `tests/results/`, failures there are known and listed |
| 1 | none (unmodified build) | T3 `tests/stage1.sh` items 1–5, T4 for keyguard steps | every item has an observed result; doc 07 Stage 1/3/5 updated with it |
| 2a | `frameworks/base`: action table, storage v1, `RebootBfuAction`, shell command, collision checks | T0, T1 with new unit tests (helper not mocked), regression gate | unit tests green, duress unchanged |
| 2b | `packages/apps/Settings`: Reboot PIN screens | T0, T4 Settings checklist | enrol / update / delete / collision errors work |
| 2c | `RebootBfuTest` host test | T2, T4 matrix | matrix fully green, wrong-PIN timing unchanged (D4) |
| 3 | probably none; maybe wording in Settings | T3 eviction scenarios, T4 End session | eviction confirmed for restriction and End session |
| 4 | keyguard dispatch (fork-only) | T1, T3 crossing script, T4 | design notes 1–7 in doc 07 each covered by a test |
| 5 | experiment | T3 boot-order script | in/out decision recorded in doc 00 |
| 6 | flash test Pixel (manual) | T5 | hardware throttling and wipe observed |

### T4 checklist for `REBOOT_BFU` (Stage 2)

1. Owner PIN unlocks normally; nothing else happens.
2. Reboot PIN at the keyguard → device reboots; after boot it asks for the PIN (BFU).
3. Reboot PIN at an in-app credential confirmation (Settings → re-enter PIN) → reboots.
4. Reboot PIN at the fingerprint second-factor prompt → reboots (doc 04 Q4).
5. Duress PIN still wipes from the keyguard (destructive, last).
6. Enrolment rejects: reboot PIN = owner PIN, = duress PIN, = second-factor PIN; the owner's
   failed-attempt counter is unchanged afterwards.
7. A wrong PIN looks the same (message and timing) with 0, 1 and 2 alternates enrolled.
8. Storage upgrade: duress enrolled on an unmodified build, then the patched build boots and
   duress still wipes.

### Stage 6 (manual, human-run)

Build for the device target with release signing (GrapheneOS build guide, *Generating
release signing keys*), flash with the bootloader unlocked, set our AVB key, lock the
bootloader again. Then repeat the T4 checklist and observe Weaver throttling with repeated
wrong PINs. Never automated from this repo.
