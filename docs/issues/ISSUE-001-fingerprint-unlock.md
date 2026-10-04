# ISSUE-001 — No fingerprint unlock option (PIN/pattern only)

- **Severity:** High (security/Ux feature missing)
- **Status:** Investigating — root cause identified from logs, fix not yet applied
- **Collected:** 2026-10-04, `logs/2026-10-04/`
- **Related files:** `fp-services.txt`, `fp-list.txt`, `fp-hal.txt`,
  `fp-vendor.txt`, `logcat-system.txt`, `dmesg.txt`

## Symptom

The device has no way to enroll a fingerprint. Settings shows only PIN,
pattern and password options; there is no "Add fingerprint" entry, so
fingerprint unlock cannot be configured at all.

## Evidence

### 1. The feature is advertised

`fp-list.txt`:

```
feature:android.hardware.fingerprint
```

So the platform believes the hardware feature exists.

### 2. The vendor HAL binaries exist

`fp-vendor.txt`:

```
fingerprint.fpc.default.so   -> /vendor/lib64/hw/fingerprint.fpc_isee.so
fingerprint.fpc_isee.so      (?)
fingerprint.goodix.default.so -> /vendor/lib64/hw/fingerprint.goodix.so
fingerprint.goodix.so        (?)
```

The device's real sensor is Goodix (`persist.vendor.sys.fp.vendor=goodix`),
and `fingerprint.goodix.so` is present.

### 3. The kernel driver works and is actively talking

`dmesg.txt` shows the Goodix kernel driver firing constantly:

```
[51152.742368] [goodixFP] [gf_netlink_send] : enter, send command 1
[51152.743315] [goodixFP] [gf_netlink_send] : send done, data length is 32
[51152.744250] [goodixFP] gf_irq, 883, exit
[51152.761391] [goodixFP] gf_irq, 866, enter
```

So the sensor, IRQ line and netlink channel to userspace are **alive**. This is
not a hardware problem.

### 4. But the framework cannot reach the HAL

`logcat-system.txt`:

```
W HidlToAidlSensorAdapter: Fingerprint HAL not available
E FingerprintUpdateActiveUserClient: Failed to setActiveGroup: HIDL daemon is null.
```

And `dumpsys fingerprint` returns **empty** (`fp-services.txt`), meaning the
biometric service has no registered sensor.

## Analysis

Two independent things are true at once:

- **Kernel/driver layer:** healthy. Goodix driver probes, receives IRQs, and
  exchanges netlink messages.
- **Framework layer:** broken. The biometrics system service tries to bind the
  **HIDL** `android.hardware.biometrics.fingerprint@2.1` interface, gets
  nothing, and reports `HIDL daemon is null`. The sensor is never registered,
  so Settings never offers enrollment.

The log tag `HidlToAidlSensorAdapter` is the smoking gun: LineageOS 23.2
(Android 16) ships a **biometric AIDL** stack, and the legacy **HIDL** HAL for
this device is not being bridged. The `HidlToAidlSensorAdapter` is supposed to
wrap the old HIDL HAL into the new AIDL service — it fails because the HIDL
daemon is not running / not declared.

## Root cause / hypothesis

**Hypothesis (high confidence):** the vendor fingerprint HAL is a **HIDL 2.1**
daemon, but it is either:

1. **not being started** by `init` (missing/incorrect entry in the vendor
   `init.rc` or a `.rc` not copied for this ROM), or
2. **declared only for the wrong interface** — the device tree ships
   `android.hardware.biometrics.fingerprint@2.1-service` but the framework now
   binds via AIDL `android.hardware.biometrics.fingerprint.IFingerprint`, or
3. the **Goodix userspace daemon** (`vendor.goodix` fingerprint service) is
   missing from `/vendor/bin/hw/` (only the `.so` is there).

Note: `fp-vendor.txt` lists the `.so` files but **no** `android.hardware.
biometrics.fingerprint@2.1-service*` binary. That is the prime suspect.

## Fix proposal

1. **Confirm which HAL the ROM ships.** On device:
   `ls -la /vendor/bin/hw/ | grep -i fingerprint` and
   `getprop | grep -iE 'fingerprint|biometric'`.
2. If the device tree declares a **HIDL** HAL, check the vendor `.rc` /
   `manifest.xml` (in the device tree at `rubyx-devs/device_xiaomi_rubyx`):
   - Ensure `android.hardware.biometrics.fingerprint@2.1-service` is built and
     installed to `/vendor/bin/hw/`.
   - Ensure its `init` service is `class hal` and `user system`.
3. If the ROM is expected to use an **AIDL** HAL, add the AIDL fingerprint
   service or ensure `HidlToAidlSensorAdapter` can bind the HIDL daemon.
4. Cross-check against a device whose Goodix sensor works on the same stack
   (see `docs/references.md`).

## How other devices solved it

- Many MTK devices with Goodix sensors on Android 13+ needed the fingerprint
  HAL converted from HIDL to AIDL, or the vendor HIDL service declared in
  `vendor/etc/init/`. See `docs/references.md` for concrete examples to audit.

## Verification plan

- After a fix: `dumpsys fingerprint` should show a registered sensor.
- `logcat` should lose `Fingerprint HAL not available`.
- Settings should show "Add fingerprint".
- Kernel side already works, so no driver change is expected.
