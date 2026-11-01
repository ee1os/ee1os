# Patches

`approved.txt` is the list of fork commits that may be built and signed: one line per commit,
`<repo> <patch-id> <short-sha> <group> <subject>`, checked by `scripts/verify-tree.sh` and
extended with `scripts/approve.sh -g <group>` (doc 08, *Tree check*). `<group>` names a section of
`changes.toml`, which says in plain words what the group's commits change and why; each stable
release's changes page (`scripts/fork_report.py`) is built from the two files. It covers all six forks (`platform_build`,
`platform_frameworks_base`, `platform_packages_apps_Settings`,
`platform_packages_apps_SetupWizard2`, `platform_packages_apps_Updater`,
`platform_system_sepolicy`), branch `envs-17` over the GrapheneOS release tag in
`state/upstream-tag` (`2026102100` on 2026-10-30).

The directories are `git format-patch` exports of the early stage commits, kept as a record.
They were made on the old base, `frameworks/base` `84183aff` and `packages/apps/Settings`
`e5c0d9dd` (branch `17`), and don't apply to the current forks; the forks themselves are the
source.

| Dir | Commit | What |
|---|---|---|
| `03-environment-b/` | `ce54caed` | AccountsDb: close the CE database on close() (3c) |
| `05-boot-order/` | `d34c6e71` | Backup: open user preferences without the CE check of user 0 |
| | `066afecc` | Storage: start the storage service on the first unlocked user |
| | `b7598b08` | Storage: resolve the storage service outside the session lock |
| `02-reboot-bfu/` | `3de3688f` | Add reboot credential (2a) |
| | `7187029c` | Reboot credential: harden storage, lifecycle and dispatch |
| | `f554fde6` | Add alternate credential tests |
| | `5d3b7f9b` | Reboot credential: escrow, record and enrolment fixes |
| | `2d11384e` | Add reboot escrow and alternate credential tests |
| `02-reboot-bfu/settings/` | Settings `a64a0967` | Add reboot PIN screens (2b); applies to `packages/apps/Settings` |

Results: `tests/results/`.
