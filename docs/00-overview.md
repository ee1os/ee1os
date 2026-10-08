# 00 — Overview, scope, threat model

## Origin

Started 2026-10-06 from an idea sketch: one Pixel on GrapheneOS where different lockscreen
credentials lead to different outcomes —

| Credential | Outcome |
|---|---|
| PIN A | unlock the primary environment |
| PIN B | enter a second, separately-keyed environment |
| PIN C | duress → irreversible wipe (already exists in GrapheneOS) |
| anything else | ordinary "wrong PIN" |

The sketch's own conclusion holds after reading the code: the credential hook is ~10% of the
work; storage keys, OTA/update, verified boot and session lifecycle are the other ~90%.

## Goals

1. Document precisely how GrapheneOS 17 turns a typed credential into unlocked keys and
   where the duress check sits (docs 02, 03).
2. Design a general, reviewable **credential → action dispatch** mechanism that generalises
   duress (docs 04). First concrete action: *reboot to BFU* (Before First Unlock), aligned
   with an existing upstream discussion.
3. Evaluate **separate, cryptographically isolated environments** using what Android already
   supports (secondary users with their own synthetic password + CE key, session termination
   that evicts keys). Not written up here — there is no doc 05.
4. Map the boot/update machinery (A/B slots, update_engine, AVB with `avb_custom_key`) and
   record why "slot A = OS 1, slot B = OS 2" is not a viable dual-boot (doc 06).
5. Ship staged PoCs as patches against a pinned GrapheneOS revision (doc 07).

## Hard requirements

- **Bootloader stays locked**, verified boot intact (custom AVB key is fine). A design that needs
  an unlocked bootloader is rejected.
- **No regression of the existing duress feature** — it must still fire from every credential
  prompt it fires from today.
- **No weaker credential storage.** Any new credential must be protected at least as well as the
  primary one (Weaver/secure-element throttling), not just an offline-checkable hash.
- Upstream-shaped: small, auditable diffs in the GrapheneOS style; no global behaviour change
  for users who don't opt in.

## Non-goals

- **Hiding the existence of an environment / forensic deniability.** Out of scope.
  Rationale: (a) GrapheneOS developers have consistently argued that this cannot be delivered
  honestly on Android ([#5247](https://github.com/GrapheneOS/os-issue-tracker/issues/5247): "It's
  not possible to make hidden profiles with plausible deniability";
  [#2175](https://github.com/GrapheneOS/os-issue-tracker/issues/2175),
  [#8409](https://github.com/GrapheneOS/os-issue-tracker/issues/8409)) — on-disk metadata, storage accounting and usage patterns reveal it — and
  that a false promise of deniability endangers users more than it helps; (b) a design review on 2026-10-06
  (see *Design notes* in `07-roadmap.md`) independently found the same
  for a secondary-user design. A proposal claiming this would not be accepted upstream.
- **Forensic extraction tooling**, in either direction: no analysis of extraction tools, no
  new mechanisms aimed at resisting them, no claims about what they can or cannot recover.
  The project relies on whatever GrapheneOS already provides there and adds nothing.
- Running a non-GrapheneOS OS (e.g. Google stock) side-by-side.
- Anything requiring changes to Pixel bootloader / TF-A / secure-element firmware.

## Threat model (working draft)

Adversary can: obtain the device; compel the owner to enter *a* credential; operate the unlocked
UI; attempt brute force via the normal UI (rate-limited by Weaver/Gatekeeper).

Not modelled: an adversary using forensic extraction tools (see *Non-goals*).

What the design aims to provide:

| Property | Mechanism | Status |
|---|---|---|
| Secondary environment's data stays encrypted while it's not in use | per-user CE key evicted on session end | exists in Android/GrapheneOS |
| Compromise of one environment's credential doesn't reveal the other's keys | separate synthetic passwords, Weaver slots | exists |
| Owner can return device to BFU quickly | reboot / proposed BFU credential | existing + proposed |
| Owner can destroy all keys | duress credential | exists |
| Existence of second environment is hidden | — | **non-goal** |

## Decisions

- 2026-10-06 — Both environments are GrapheneOS (one source tree, one signing root), not
  GrapheneOS + stock. Reason: one firmware baseline, one update channel, one rollback index.
- 2026-10-06 — Deniability declared a non-goal (see above).
- 2026-10-06 — Environment A is the owner profile (user 0) and its CE key may stay in memory
  until reboot; only environment B (a secondary user) has to be evictable. Reason (owner
  decision): A is the regular primary profile, and user 0 cannot be stopped
  (`UserController.java:1323-1324`), so making A evictable would need a three-credential layout
  with an empty owner. Rejected as not worth it; `REBOOT_BFU` covers A.
- 2026-10-06 — Forensic extraction dropped from the threat model and declared a non-goal
  (owner decision). Reason: none of the planned PoCs address it, and keeping it in the threat
  model invited work the project does not intend to do.
