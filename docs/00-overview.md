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
6. A **three-credential layout set up at install**: A (user 0, the everyday profile), B (a
   secondary user that holds the security settings) and the duress credential. A works as
   plain Android and shows nothing of B or the alternates (doc 04, *A/B/duress layout*).

## Hard requirements

- **Bootloader stays locked**, verified boot intact (custom AVB key is fine). A design that needs
  an unlocked bootloader is rejected.
- **No regression of the existing duress feature** — it must still fire from every credential
  prompt it fires from today.
- **No weaker credential storage.** Any new credential that grants access must be protected at
  least as well as the primary one (Weaver/secure-element throttling), not just an
  offline-checkable hash. Credentials that only wipe or reboot may be stored like upstream's
  duress credentials (decision 2026-10-13).
- Upstream-shaped: small, auditable diffs in the GrapheneOS style; no global behaviour change
  for users who don't opt in.

## Non-goals

- **Deniability.** B is kept out of A's everyday screens (goal 6), and that is all. Nothing
  claims B can't be found: its directories and user record are on disk, storage use, `adb`,
  Weaver counters and usage patterns show it, and anyone who knows this build asks for a
  second PIN. GrapheneOS developers make the same point
  ([#5247](https://github.com/GrapheneOS/os-issue-tracker/issues/5247): "It's
  not possible to make hidden profiles with plausible deniability";
  [#2175](https://github.com/GrapheneOS/os-issue-tracker/issues/2175),
  [#8409](https://github.com/GrapheneOS/os-issue-tracker/issues/8409)), and a false promise of
  deniability endangers users more than it helps; a design review on 2026-10-06 (*Design
  notes* in `07-roadmap.md`) found the same. Screens and docs must not suggest otherwise.
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
- 2026-10-11 — Non-goal reworded (owner decision): B is kept out of A's screens, without any
  claim that it can't be detected. Reason: that was the intent from the start; the old wording
  read as if B would be shown everywhere.
- 2026-10-06 — Environment A is the owner profile (user 0) and its CE key may stay in memory
  until reboot; only environment B (a secondary user) has to be evictable. Reason (owner
  decision): A is the regular primary profile, and user 0 cannot be stopped
  (`UserController.java:1323-1324`), so making A evictable would need a three-credential layout
  with an empty owner. Rejected as not worth it; `REBOOT_BFU` covers A.
- 2026-10-06 — Forensic extraction dropped from the threat model and declared a non-goal
  (owner decision). Reason: none of the planned PoCs address it, and keeping it in the threat
  model invited work the project does not intend to do.
- **2026-10-11: alternates move behind hardware throttling ("No weaker credential storage").**
  The reboot credential is stored like the duress credentials: a salted scrypt value in
  `locksettings.db` (`DuressCredential.java:23-28`), checkable offline, with no Weaver or
  secure-element throttling. That contradicts the hard requirement above as written. The owner
  chose to keep the requirement and to put alternates behind Weaver (one slot per alternate)
  rather than narrow the requirement to credentials that grant access; narrowing stays the
  fallback only if the slot budget or the throttling interaction rules Weaver out. Reason:
  an offline-checkable alternate can be recovered from an extracted `locksettings.db` and then
  avoided. First step is measuring the slot budget on the test device (doc 07). Until then,
  Stage 2 is not claimed to meet this requirement.
- **2026-10-13: the requirement is narrowed to credentials that grant access** (replaces the
  2026-10-11 decision above). The duress and reboot credentials stay salted scrypt values in
  `locksettings.db`, as upstream stores duress. Reason: they open nothing, and recovering them
  needs code execution on the device to read the file; what it buys is guessing A's or B's PIN
  on the device while avoiding the wipe, and that guessing is still throttled by Weaver. The
  Weaver-backed alternates design (doc 04) is shelved, not deleted.
- 2026-10-11 — Three-credential layout set up at install (goal 6, owner decision): A is user 0
  and the everyday profile; B is a secondary user that holds the duress, reboot and user
  settings; the duress credential stays device-wide. A shows none of them. Biometrics belong
  to A only (a fingerprint at the lock screen opens A; B is credential-only). A's CE key may
  stay in memory while B is used, as decided on 2026-10-06; `REBOOT_BFU` covers it. Stages 4
  and 5 become required. Credential lengths: all PINs of 6 digits or more, no length ranges; the
  enrolment check in A's change-PIN screen is accepted, with refusals throttled (doc 04).
- **2026-10-15: no GrapheneOS boot animation or branding, in any form** (owner decision). The
  main OS boots with the stock animated AOSP "android" logo; until the first setup is done it
  shows our own (doc 04, boot logo). GrapheneOS's branch `17` added its own animation
  (`bootanimation_zip` from the new `branding` repo, listed in build/make
  `target/product/base_product.mk`); our `platform_build` fork filters it back out, so it isn't
  installed once a release brings it in. Upstream also lists it in
  `target/product/generic/Android.bp` (`product_image_defaults`), which only GSI images use,
  not husky or the emulator; if we ever build those, drop it there too. Reason: the project is described as a fork of
  GrapheneOS, not branded as it (doc 07 R7).
- **2026-10-15: we follow GrapheneOS stable release tags only, by rebase.** Upstream's branch
  `17` is their development line between releases; it is never merged into `envs-17`, because
  `scripts/track-upstream.sh` rebases each fork from its release-tag base onto the next tag and
  a merge would make it replay upstream commits. Their changes reach us with the next tag.
- **2026-10-30: the project is renamed ee1os, at ee1os.com** (owner decision; replaces the
  working name os.ivan.gg and the `NAME` placeholder in `site/landing.md`). Read "ee-one-os":
  **two environments, one OS**.
  - *ee* is the two environments, A (user 0) and B (secondary user), each with its own
    synthetic password and CE key (goal 3, 6); also **e**ncrypted **e**nvironments, which
    is what makes B worth having. This repo was `grapheneos-envs` for the same reason.
  - *1os* is one OS: one GrapheneOS build, one signing root, one update channel, not a
    dual boot (decision 2026-10-06, doc 06).
  - The "-os" suffix marks a separately maintained distribution. That is accurate here: we
    ship our own builds and updates from the forks (doc 07 *Fork and upstream*, R1–R7).
  - Side readings, never used as claims: *eel* (`1` = `l`), a thing that slips out of a
    grip; and Greek *eleos*, mercy. The eel must not turn into "hidden" or "undetectable"
    wording: deniability is a non-goal (above).
  - Known costs, accepted: `1` reads as `l` or `I` (`eelos`, `eeios`); `eelo` was the 2017
    name of /e/OS; EE is a UK mobile carrier. Mitigation: always write it lowercase as
    `ee1os`, explain it once next to the name ("ee·1·os — two environments, one OS"), keep
    GrapheneOS out of the branding (doc 07 R7).
  - fri4.com (owned) was the other candidate: `4` = `a`, *fría*, "cold" (Spanish), the BFU
    state the reboot PIN returns to, and four PINs (A, B, duress, reboot). Cleaner as a
    brand, but it names one action out of four; ee1os names the whole design. fri4.com
    stays owned, and can point at the reboot-to-BFU page.
  - Reviews: Grok and Codex on both names, agy on fri4 only (quota); doc 07 *Review log*.
  The rename itself is doc 07 R8.
