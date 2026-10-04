# Handoff to maintainer (Aeron) — fingerprint HAL

Context: root-enabled inspection of the running device (see
`../logs/2026-10-04-fp-root/`). Summary of what was found and what is left for
the maintainer.

## What the root logs show (facts)

1. The Goodix/FPC **vendor blobs are present** and the **kernel drivers are
   active** — `[goodixFP] gf_irq ... gf_netlink_send` lines stream in `dmesg`
   (`../logs/2026-10-04-fp-root/05-logs-daemon.txt`). So this is **not** a
   missing variant/driver problem.
2. The HIDL service **process runs**: `init.svc.vendor.fps_hal = [running]`
   (pid 1331), binary present at
   `/vendor/bin/hw/android.hardware.biometrics.fingerprint@2.3-service.xiaomi`.
3. **But the interface is never registered**: `lshal --neat | grep fingerprint`
   is empty; `dumpsys fingerprint` (with root) shows
   `FingerprintProvider/defaultHIDL` alive but with no sensor.
4. The service `.rc`
   (`/vendor/etc/init/android.hardware.biometrics.fingerprint@2.3-service.xiaomi.rc`)
   declares `service vendor.fps_hal ... class late_start` **without an
   `interface` line**.
5. `hwservicemanager` repeatedly tries to start
   `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default`
   as a lazy HAL; init rejects it:
   `ctl.interface_start ... PROP_ERROR_HANDLE_CONTROL_MESSAGE (0x20)`.
6. **No `.rc`** in `/vendor /odm /system` declares a fingerprint `interface`.

## Hypothesis

The missing `interface <fqname>@<ver>::<Iface>` line in the service `.rc` is why
init cannot resolve the lazy `interface_start`, so the HAL never registers.

## What the maintainer should validate (reporter has no reference device)

- The correct `interface` FQN for this vendor blob, against a working device of
  the same family.
- Whether the intended path is HIDL (`interface` line) or the AIDL migration
  ("Move to Xiaomi fingerprint AIDL", LineageOS `hardware/xiaomi/aidl/fingerprint/`).
- The VINTF `manifest.xml` / `compatibility_matrix` entries.

## Not conclusive by itself

The `@2.3` vs `@2.1` idea is **discarded** (HIDL inheritance:
<https://source.android.com/docs/core/architecture/hidl/interfaces>). The
mechanism proposed above fits all 8 facts, but the exact `interface` line needs
a reference device to confirm.
