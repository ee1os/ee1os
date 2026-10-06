# 02 — Credentials and storage encryption: pointers

This file is deliberately a reading list, not a walkthrough. The upstream material is
authoritative and better maintained than a local paraphrase would be.

## Read upstream

- AOSP, file-based encryption: <https://source.android.com/docs/security/features/encryption/file-based>
- AOSP, Gatekeeper: <https://source.android.com/docs/security/features/authentication/gatekeeper>
- AOSP, Weaver HAL: `src/hardware_interfaces/weaver/`
- GrapheneOS FAQ, encryption: <https://grapheneos.org/faq#encryption>
- GrapheneOS features, duress PIN/password: <https://grapheneos.org/features#duress>

## Read in the tree

- The class-level comment of `SyntheticPasswordManager.java` (roughly lines 100–160 at
  frameworks_base `84183aff`) describes the protector files and what each one holds.
- `LockSettingsService.java:3600` (`onCredentialVerifiedInternal`) shows the order of
  operations after a successful verification.
- `system_vold/FsCrypt.cpp` — the `fscrypt_*` entry points listed in `01-source-layout.md`.

## What the other docs rely on

Only these facts, each of which is cited where it is used:

1. Each Android user has its own credential-protected storage key.
2. Verification of the primary credential is rate-limited by hardware, not by the OS (doc 04).
3. The duress check is separate from primary-credential verification (doc 03).
