# Patches

`git format-patch` exports of the fork commits, one directory per roadmap stage. Base:
`frameworks/base` `84183aff` and `packages/apps/Settings` `e5c0d9dd` (branch `17`); the fork
branches are `envs-17`.

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

Within a directory the patches apply in number order; the directories touch different files and
apply in any order (`git am`). Results: `tests/results/`.
