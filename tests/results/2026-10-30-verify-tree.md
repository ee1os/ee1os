# Tree check (`scripts/verify-tree.sh`) on n5, 2026-10-30

Tree `grapheneos-17` on GrapheneOS `2026102100`, 1056 projects; forks on `envs-17` equal to
GitHub (`build/make` `0bbc26e4`, `frameworks/base` `55883064`, Settings `12051b4f`,
SetupWizard2 `4cfb073c`, Updater `0ec3356b`, sepolicy `9507623e`). `patches/approved.txt`:
63 commits, approved by the owner. os-ivan-gg at `fbb1dfb`. No `allowed_signers` yet, so
approvals were not signature-checked. Every case was rolled back right after its run
(script in the session's scratch dir, not kept).

| # | Case | Exit | Reason printed |
|---|---|---|---|
| 1 | clean tree, approved list | 0 | `tree OK` |
| 2 | `git commit --allow-empty -m test` in `frameworks/base` | 1 | `frameworks/base: empty commit 76e24ca3c88f test` |
| 2b | unapproved non-empty commit (a line added to `frameworks/base/Android.bp`) | 1 | `frameworks/base: commit not approved: 59a1dbc67496 test: unapproved change` |
| 3 | `echo >> frameworks/base/README.md` (that file isn't tracked: it becomes a new one) | 1 | `frameworks/base: uncommitted, untracked or ignored: ?? README.md` |
| 3b | tracked `frameworks/base/Android.bp` changed, not committed | 1 | `frameworks/base: uncommitted, untracked or ignored: M Android.bp` |
| 4 | `git -C external/zlib checkout HEAD~1` | 1 | `external/zlib: at 959608634d6d, 2026102100 pins 8731e6760935` |
| 5 | line of `558830646454` removed from `approved.txt` and committed | 1 | `frameworks/base: commit not approved: 558830646454 Show the lockout countdown on user 0's pad for either user` |
| 5b | the same line removed in the working copy only | 1 | `os-ivan-gg has uncommitted changes in scripts/, patches/ or workspace/build-env/` (the committed list is the one used) |
| 7 | `device/rogue/vendorsetup.sh` (outside every project; `envsetup` would source it) | 1 | `outside every project: device/rogue` |
| 8 | `frameworks/base` detached from `envs-17` | 1 | `frameworks/base: HEAD isn't the envs-17 branch` |
| 1 | clean again after the rollbacks | 0 | `tree OK` |

Time on n5 (case 6): 10.7–11.3 s wall per run (about 11 s by the script's own count), with
the vendor module hashes (1.9 GB) included. Target was under a minute.

Before the fix in `fbb1dfb`, case 3 printed `rs README.md` for `?? README.md` (the shell
expanded `??`); fixed in the next commit. Patch-id stability: all 62 commits that existed on
`2026101600.os` kept their patch-id through the rebase onto `2026102100`.
