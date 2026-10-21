# init SIGABRT at boot: what could be read on the phone (2026102109, boot at 16:27:00 IST)

- Crash line: `16:27:02.957 pid 956 tid 956 (init) Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE)`, then `crash_dump helper failed to exec, or was killed`.
- Same second: `auditd: avc: denied { ptrace } for comm="crash_dump64" scontext=u:r:crash_dump:s0 tcontext=u:r:init:s0`. So the dead process was in the **init domain** (a forked init child, not yet exec'd into a service binary), and crash_dump is not allowed to ptrace init. That is why the dump fails.
- Timing: ~6.4 s into userspace (`boot_progress_preload_start: 6429` logged 3 ms earlier), while init starts class main / late_start.
- pid neighbours still alive: 947 `shared_modem_platform`, 951 `modem_ml_svc_sit`, then gap 952–999 (exited one-shots and 956), then 1007 `drmserver`.
- Could not name the service:
  - `adb logcat -b kernel` (logd's kmsg copy) has no `init:` lines at all; the engineer's grep matched nothing.
  - `dmesg` → `klogctl: Permission denied` for shell on the user build.
  - `ro.boottime.*` are not readable by shell (`getprop` lists none), so there are no start times to match.
  - init's own `Service '…' (pid 956) …` line only goes to kmsg.
- One-shot services in `stopped` state that start around then (class main/late_start/core): `usbd`, `init-radio-sh`, `misctrl`, `hal_wlcservice` (class `charger hal`, oneshot), plus the `disabled` one-shots `modem_logging_*`, `block_queue_depth`, `edgetpu_vendor_service`, `mmd_setup`, `vendor_uwb_init`, `casefolding_remover`. An `exec` from an `on` trigger would also fit and doesn't appear in `init.svc.*`.
- Stock comparison: the same two lines are reported on stock GrapheneOS (Pixel Fold 10, Android 16, Dec 2025 / Jan 2026 builds): https://discuss.grapheneos.org/d/30723 and https://discuss.grapheneos.org/d/30209. Not husky, but the same pattern on upstream. Today it was also on 2026101516 and 2026101520 here.
- To name the service, we need kmsg: a userdebug build, a bugreport (`adb bugreport` includes `dmesg` collected by dumpstate), or pstore after the next boot. `adb bugreport` is the cheapest next step on this phone.

## Named after a fresh boot (17:09 IST, bugreport dmesg)

Crash this boot: pid 965 at 17:09:39.220. Kernel log:

```
[6.771755][T1]   init: ... started service 'exec 12 (/vendor/bin/gpuflag)' has pid 965
[6.772230][T965] init: cannot setexeccon('u:r:gpuflag:s0') for exec 12 (/vendor/bin/gpuflag): Invalid argument
[6.865346][T1]   init: Service 'exec 12 (/vendor/bin/gpuflag)' (pid 965) received SIGABRT oneshot service took 0.095000 seconds in background
```

- `/vendor/etc/init/gpuflag.rc`: `on boot` → `exec_background u:r:gpuflag:s0 -- /vendor/bin/gpuflag`.
- The loaded policy has no `gpuflag` type: 0 matches in `vendor_sepolicy.cil`, `plat_sepolicy.cil`, `odm_sepolicy.cil`. So `setexeccon` returns EINVAL, and init's forked child aborts before exec.
- Origin: `vendor/google_devices/husky/proprietary/vendor/etc/init/gpuflag.rc` and the `gpuflag` binary/aconfig lib come from the stock vendor image extracted for husky (`husky.mk` lines 373, 1243, 3285). The same files exist for stallion. No `gpuflag` policy anywhere in `device/` or `vendor/google_devices`. Nothing in os-ivan-gg touches these files or the sepolicy.
- Conclusion: an upstream GrapheneOS packaging gap (the stock blob and its rc are shipped without the stock `gpuflag` SELinux domain), not ours. Effect: `gpuflag` never runs on any boot. Stock GrapheneOS husky should show the same line; not checked on a stock flash (no flashing on this phone). Fix options: drop `gpuflag.rc` from the vendor copy list, or add a `gpuflag` domain to the vendor sepolicy. Open: fix in the fork or leave it (nothing goes upstream).
