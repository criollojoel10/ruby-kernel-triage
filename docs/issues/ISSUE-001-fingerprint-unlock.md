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

## Root cause — a HIDL VERSION MISMATCH (confirmed)

**Confirmed [V]:** the device tree `device.mk` (branch `lineage-23.2`) installs
an **`@2.3`** service:

```
141: # Fingerprint
143:     android.hardware.biometrics.fingerprint@2.3-service.xiaomi
168:     init.fingerprint.rc
```

But the framework requests **`@2.1`**:

```
android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default
```

A `@2.3` service does **not** satisfy a `@2.1` client lookup (the FQN differs),
so `hwservicemanager`/init never resolve it → `Fingerprint HAL not available` →
`HIDL daemon is null` → no enrollment in Settings. **[V + I, high confidence]**

Additional facts **[V]**:
- The device tree has a commit **"Move to Xiaomi fingerprint AIDL"** and
  LineageOS `hardware/xiaomi` **already ships the AIDL implementation**
  (`aidl/fingerprint/android.hardware.biometrics.fingerprint-service.xiaomi.*`),
  but that migration is **not on the branch the device runs**.
- `fp-vendor.txt` shows the Goodix `.so` files but **no** `@2.1` service binary.

## Fix proposal

**Recommended (A):** apply the "Move to Xiaomi fingerprint AIDL" migration on the
`lineage-23.2` branch — it aligns with Android 16's AIDL-first biometric stack
using the AIDL code already present in LineageOS `hardware/xiaomi`. **[V]**

**Alternatives:**
- (B) Make the tree serve `@2.1` (patch `manifest.xml` + `init.fingerprint.rc`).
  Quick, but fights the platform direction.
- (C) Add the AIDL `fingerprint-service.xiaomi` + its `init` rc + VINTF xml by
  hand (same result as A).

**Steps:**
1. Diff the "Move to Xiaomi fingerprint AIDL" commit fully (it may touch
   `device.mk`, VINTF and init, not just `device.mk`).
2. Apply on `lineage-23.2`, rebuild.
3. Cross-check against a device whose Goodix sensor works on Android 16 AIDL.

See `docs/08-services-audit.md` §1 for the full analysis.

## How other devices solved it

- Many MTK devices with Goodix sensors on Android 13+ needed the fingerprint
  HAL converted from HIDL to AIDL, or the vendor HIDL service declared in
  `vendor/etc/init/`. See `docs/references.md` for concrete examples to audit.

## Verification plan

- After a fix: `dumpsys fingerprint` should show a registered sensor.
- `logcat` should lose `Fingerprint HAL not available`.
- Settings should show "Add fingerprint".
- Kernel side already works, so no driver change is expected.
