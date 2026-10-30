<!-- Landing page draft for ee1os (ee·1·os: two environments, one OS). -->

# ee1os

**Your PIN decides what opens.**

ee1os is a privacy and security focused Android OS based on GrapheneOS. One lock screen, several
PINs, each with its own outcome: your everyday phone, a protected space with its own keys, an
instant lockdown, or a wipe.

Alpha · based on GrapheneOS 17 · [Install](#install) · [Release notes](#releases)

---

## One PIN pad, several outcomes

The lock screen looks and works like any other. What happens next depends on the PIN you type.

| You type | The phone |
|---|---|
| Everyday PIN | opens your everyday profile |
| Protected space PIN | opens the protected space |
| Reboot PIN | restarts at once; every encryption key leaves memory |
| Duress PIN | wipes the device |
| Anything else | says "wrong PIN" |

No extra buttons, no special gestures: the same pad, the same animation, the same flow.

## Protected space

A second environment on the same phone, with its own apps, its own data and its own encryption
keys.

- **Opened from the normal lock screen** with its own PIN.
- **Separate keys.** The protected space has its own credential and its own encryption key.
  Unlocking the everyday profile does not unlock it.
- **Locked again when you leave.** Switch back and its keys are removed from memory; its data
  stays encrypted until its PIN is entered again.
- **Straight from boot.** After a restart you can open the protected space without ever unlocking
  the everyday profile.
- **Out of the everyday profile's way.** The everyday profile works as a normal phone and does not
  list the protected space or its settings.

## Security settings the everyday profile can't change

The duress PIN, the reboot PIN and user management live in the protected space. Someone holding
the phone unlocked in the everyday profile cannot see them, change them or turn them off.

## Lock down or wipe, from any PIN prompt

- **Reboot PIN.** Type it at the lock screen or at any app that asks for your PIN, and the phone
  restarts immediately. All encryption keys leave memory and every profile needs its PIN again.
- **Duress PIN** (from GrapheneOS). Type it at any PIN prompt and the device wipes itself.

## Also in ee1os

- **Guided setup.** Set up the protected space at first boot or later from Settings, step by step.
  Your existing PIN is kept, and duress is optional.
- **Fingerprint for everyday use.** Fingerprint unlock opens the everyday profile; the protected
  space always asks for its PIN.
- **Signed updates over the air.** Updates come from ee1os, signed with our own keys, and
  install in the background on the inactive slot. The bootloader stays locked and verified boot
  stays on.

---

## Everything else from GrapheneOS

ee1os keeps the whole of GrapheneOS and follows its releases. Highlights:

| | |
|---|---|
| **Sandboxed Google Play** | optional; runs as a regular app with no special access |
| **Network and Sensors permissions** | turn off network or sensor access per app |
| **Storage and Contact Scopes** | give an app only the files or contacts you choose |
| **Hardened memory** | hardened allocator and hardware memory tagging against exploits |
| **Auto-reboot** | returns the phone to its fully encrypted state after a set time locked |
| **USB-C port control** | no new USB data connections while the phone is locked |
| **PIN scrambling and two-factor unlock** | shuffled PIN pad; fingerprint plus PIN |
| **Vanadium** | hardened Chromium-based browser and WebView |
| **Wi-Fi and Bluetooth** | turn off automatically when unused; MAC randomization per connection |
| **Verified boot and attestation** | locked bootloader, own signing key, Auditor app |

Full list: [grapheneos.org/features](https://grapheneos.org/features).

---

## Install

**Supported:** Pixel 8 Pro. More Pixels follow.

1. Enable OEM unlocking in the stock OS (Settings → System → Developer options).
2. Open the [web installer](https://ee1os.com/install) in Chrome or Edge on a computer and connect
   the phone.
3. Unlock the bootloader, flash ee1os, and lock the bootloader again. The installer does each step
   and sets our verified boot key.
4. On first boot, set your everyday PIN and, if you want it, the protected space.

Prefer the command line? [Download the factory image](https://ee1os.com/releases) and run
`flash-all.sh`.

Verified boot key fingerprint: `TBD`

## Releases

Each release is built on a GrapheneOS release and lists which one.

- **Alpha 1** — first public build. Based on GrapheneOS `TBD`. [Notes](https://ee1os.com/releases/alpha-1)

Updates arrive through the built-in Updater; no reinstall needed.

---

## Source

- Organization: [github.com/ee1os](https://github.com/ee1os); docs and patches in
  [ee1os/ee1os](https://github.com/ee1os/ee1os), code on the `envs-17`
  branch of each fork
- Patches against GrapheneOS, per feature: [patches/](https://github.com/ee1os/ee1os/tree/main/patches)

ee1os is a personal research and test project, provided as is with no warranty or liability:
see the [terms](terms.md). It is an independent fork, not affiliated with or endorsed by the GrapheneOS project.
Please don't ask GrapheneOS for support with ee1os. GrapheneOS is a trademark of the GrapheneOS
Foundation.

Contact: TBD
