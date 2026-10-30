# ee1os

A phone OS for your personal security. [ee1os.com](https://ee1os.com)

Built on [GrapheneOS](https://grapheneos.org) for Pixel phones. Sensitive accounts, wallets and
contacts live in a protected space with its own keys, opened from the normal lock screen by its
own PIN. Other PINs open the everyday profile, reboot at once to the fully locked state, or
wipe the phone.

> Personal research and test project, alpha quality. Provided as is, with no warranty and no
> liability of any kind. Not affiliated with or endorsed by the GrapheneOS project.

This repo holds the design docs, test scripts, build tooling and per-feature patches. The code
itself is on the `envs-17` branch of the forks in [ee1os](https://github.com/ee1os).

## Docs

| Doc | What |
|---|---|
| [00 Overview](docs/00-overview.md) | goals, scope, non-goals, threat model, decisions |
| [01 Source layout](docs/01-source-layout.md) | checkouts, pinned revisions, where to look |
| [02 Credentials and encryption](docs/02-credentials-and-encryption.md) | reading list |
| [03 Duress](docs/03-duress-implementation.md) | GrapheneOS's duress feature, callers, changes since 16 |
| [04 Alternate credentials](docs/04-alternate-credential-actions.md) | credential → action design, the A/B/duress layout, decisions |
| [06 Boot, A/B and updates](docs/06-boot-ab-and-updates.md) | A/B slots, update_engine, verified boot; why no dual boot |
| [07 Roadmap](docs/07-roadmap.md) | status, stages, next steps, release plan |
| [08 Development and testing](docs/08-development-and-testing.md) | build container, emulator, phone tests |

## Layout

```
docs/                 design and procedure docs
scripts/              local manifest (forks), source sync
workspace/build-env/  build container (Dockerfile, run.sh)
tests/                stage test scripts; results/ holds run records
patches/              format-patch export per stage
```

## Building

Sync GrapheneOS 17 with `repo`, add `scripts/envs-local-manifest.xml` as
`.repo/local_manifests/envs.xml` so the forked projects come from this organization, then build
in the container: see [doc 08](docs/08-development-and-testing.md).
