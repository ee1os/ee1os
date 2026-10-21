# 2026-10-21 — lock screen countdown fix, regression gate (emulator)

frameworks/base `envs-17` 58e76ac0981a. Fix for T11 7.2 and 8.1 (doc 04 decision 2026-10-21).

```
gate: gate-keyguard.log result: PASS (exit 0)
gate: gate-auth.log Passed: 47, Failed: 0, Ignored: 0, Assumption Failed: 0  
gate: gate-lss.log Passed: 845, Failed: 0, Ignored: 17, Assumption Failed: 8 
```

## Lock screen dispatch — 2026-10-21T12:23:40+00:00
build: Android/sdk_phone64_x86_64/emu64x:17/CP2A.260605.016/2026101902:userdebug/test-keys
    protected space is user 10
### A's PIN, tapped and as key events
    PASS: A opens (taps)
    PASS: A opens (key events)
### B's PIN at A's lock screen: B opens without asking again
    PASS: B opens
### screen off in B with an app open: back on A's lock screen, nothing of B on top
    PASS: user 0 after screen off
    PASS: lock screen showing
    PASS: nothing of B on top, focus on A's lock screen
    PASS: A opens (key events) right after B
### during a lockout the pad still sends every entry
    PASS: all 7 entries reached the service
    PASS: pad still up
    PASS: countdown shown
### only B in lockout: B's PIN shows B's countdown, and opens B once it ends
    PASS: A opens after the lockout
    PASS: B's PIN during B's lockout: countdown, still user 0
    PASS: B opens once its lockout ended
results: /src/gate-keyguard.log
result: PASS
