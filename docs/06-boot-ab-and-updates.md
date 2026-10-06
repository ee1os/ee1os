# 06 — Boot slots, updates, verified boot

Why "slot A = one OS, slot B = another OS" is not a usable dual-boot on a Pixel, and what
that leaves. Revisions: hardware_interfaces `10f50d7`, update_engine `79f478a`.

## The slot API

`src/hardware_interfaces/boot/aidl/android/hardware/boot/IBootControl.aidl`:

| Method | Line | Meaning |
|---|---|---|
| `getCurrentSlot()` | 47 | slot the running system booted from |
| `getActiveBootSlot()` | 34 | slot the bootloader will try next |
| `setActiveBootSlot(slot)` | 117 | select slot for next boot; resets its retry state |
| `markBootSuccessful()` | 108 | confirm the current slot booted fine |
| `isSlotBootable` / `isSlotMarkedSuccessful` | 91 / 101 | slot health flags |
| `setSlotAsUnbootable(slot)` | 126 | mark slot broken |
| `get/setSnapshotMergeStatus` | 71 / 157 | Virtual A/B merge state (`MergeStatus.aidl`: NONE, UNKNOWN, SNAPSHOTTED, MERGING, CANCELLED) |

So a privileged system component *can* say "boot the other slot next time". That is the
whole of the mechanism the idea sketch wanted to reuse.

## Who else calls it

update_engine owns the slots:

- After applying an OTA it switches to the target slot:
  `src/system_update_engine/payload_consumer/postinstall_runner_action.cc:469`.
- It can switch back to the current slot when an update is cancelled:
  `src/system_update_engine/aosp/update_attempter_android.cc:1552`.
- Wrapper: `src/system_update_engine/aosp/boot_control_android.cc:120` (`SetActiveBootSlot`),
  `:134` (`MarkBootSuccessfulAsync`).

## Why two OSes in two slots breaks

1. **The inactive slot is the update staging area.** Every OTA writes the new system into the
   slot that is not running. Two OSes sharing A/B means each one's update overwrites the other.
   Avoiding that requires disabling seamless updates or redesigning update_engine — both are
   far outside an upstreamable change.
2. **Virtual A/B.** Current Pixels don't have two full copies of the dynamic partitions; the
   inactive slot's `system`/`vendor`/`product` exist as copy-on-write snapshots during an
   update and are merged afterwards (the `MergeStatus` state machine). There is no persistent
   "second system image" to boot into between updates.
3. **Retry / rollback logic.** The bootloader counts boot attempts per slot and falls back when
   a slot isn't marked successful. Bouncing between slots on purpose fights that logic.
4. **One `userdata`.** Slots duplicate boot/system/vendor partitions only. `/data` and
   `metadata` are single partitions, and their format is tied to the OS version that last
   wrote them. Two OS builds at different patch levels sharing one `/data` is unsupported;
   downgrades of `/data` are not handled.
5. **Rollback protection.** AVB rollback indexes are stored per key/location in tamper-evident
   storage and only move forward. Two images signed by the same key must stay at compatible
   rollback indexes, so they have to be built and updated in lockstep anyway.
6. **Firmware is shared.** Bootloader, radio and secure-element firmware exist once (or A/B
   for update purposes) and are matched to one OS release.

## Verified boot with a custom key

- Pixels accept a user-set AVB root (`avb_custom_key`) and will boot an OS signed with it
  while the bootloader is **locked**; the boot screen shows a yellow notice with the key
  fingerprint. This is how GrapheneOS itself boots.
- Consequence for this project: any PoC must be a complete, self-signed GrapheneOS build
  flashed with our own key. Hard requirement from doc 00: no design may depend on leaving the
  bootloader unlocked.
- Not in the sparse checkout: `external/avb`, device trees, the bootloader interface docs.
  Add them before doing work in this area.

## Conclusion

- **Decision 2026-10-06:** no multi-OS / multi-slot design. One OS image, one update channel.
  Anything "second environment"-shaped has to live inside that one OS.
- `setActiveBootSlot` has no role in the `REBOOT_BFU` PoC (doc 04): `REBOOT_BFU` is a plain reboot of the
  same slot.

## Open items

- Confirm the Virtual A/B details against the device tree of the actual target Pixel
  (which partitions are true A/B, which are dynamic/snapshotted).
- `system_core/fs_mgr` is no longer at that path on the `17` branch (sparse pattern matches
  nothing); locate where fstab / first-stage mount handling lives now and fix
  `scripts/sync-src.sh`.
