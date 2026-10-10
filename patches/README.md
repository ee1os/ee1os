# Patches

`git format-patch` exports of the fork commits, one directory per roadmap stage. Base:
`frameworks/base` `84183aff` (branch `17`); the fork branch is `envs-17`.

| Dir | Commit | What |
|---|---|---|
| `03-environment-b/` | `ce54caed` | AccountsDb: close the CE database on close() (3c) |
| `05-boot-order/` | `d34c6e71` | Backup: open user preferences without the CE check of user 0 |
| `02-reboot-bfu/` | `3de3688f` | Add reboot credential (2a) |

They touch different files and apply in any order (`git am`). Results: `tests/results/`.
