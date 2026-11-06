
## Removable volume across user switches — 2026-11-06T18:05:39+00:00
build: Android/sdk_phone64_x86_64/emu64x:17/CP2A.260605.016/2026110506:userdebug/test-keys
    protected space is user 10
### inserted in A
    PASS: A sees it
### A to B and back with the stick left in
    PASS: it moves to B
    PASS: A no longer lists it
    PASS: it moves back to A
### inserted in B, back to A with the stick left in (B stops)
    PASS: B sees it
    PASS: A sees it
### unmount and mount in B keep it with B
    PASS: it moves to B
    PASS: B still sees it
### reboot with the stick in, B first while A stays locked
    FAIL: B sees it (belongs to , )
### then back to A, still before A's first unlock
    PASS: A sees it after its first unlock

usb-volume: 1 FAILED
