# ISSUE-001 — Fingerprint unlock not working

- Status: **open, root cause UNKNOWN**
- Device: `ruby` (MT6877V), LineageOS 23.2, kernel 6.6.127
- Evidence: `logs/2026-10-04/fp-*.txt`, `logs/2026-10-04/dmesg.txt`,
  `logs/2026-10-04/logcat-system.txt`
- Legend: **[V]** verified · **[I]** inferred · **[?]** unknown

## Symptom

No fingerprint enrollment possible ("Add fingerprint" absent in Settings). The
feature is advertised (`feature:android.hardware.fingerprint` **[V]**), the
sensor vendor prop is set (`persist.vendor.sys.fp.vendor=goodix` **[V]**), but
`dumpsys fingerprint` returns **empty** and every HAL bind fails.

## Evidence (what the logs actually show) **[V]**

`logcat-system.txt` — repeated in a tight loop:

```
W HidlToAidlSensorAdapter: NoSuchElementException
W HidlToAidlSensorAdapter: Fingerprint HAL not available
E HidlToAidlSessionAdapter: Unable to set HIDL callback. HIDL daemon is null.
E FingerprintUpdateActiveUserClient: Failed to setActiveGroup: HIDL daemon is null.
```

`dmesg.txt` — repeated 180 times, exactly:

```
init: Control message: Could not find
'android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default'
for ctl.interface_start from pid: 536 (/system/system_ext/bin/hwservicemanager)
```

`fp-vendor.txt` — the vendor blobs are present as **HAL implementation modules**
(`.so`), not as a standalone service binary:

```
/vendor/lib64/hw/fingerprint.goodix.default.so -> fingerprint.goodix.so
/vendor/lib64/hw/fingerprint.fpc.default.so    -> fingerprint.fpc_isee.so
```

## What is established so far

1. **The HAL binder is never registered.** `hwservicemanager` asks init to start
   `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default`
   and init fails to find it. **[V]**
2. **Vendor blobs exist** (`fingerprint.goodix.so`, `fpc` variant) and the device
   tree ships an `@2.3` HIDL service
   (`android.hardware.biometrics.fingerprint@2.3-service.xiaomi` in `device.mk`
   line 143). **[V]**
3. **Both Goodix and FPC drivers are enabled in the kernel**, including in the
   build running here (per maintainer Aerons). So this is **not** a missing
   variant/driver support problem. **[V, external confirmation]**

## Retracted hypothesis (was wrong)

❌ **"A `@2.3` service cannot serve a `@2.1` client."** This was asserted in an
earlier revision of this issue. **It is false.** HIDL interfaces **inherit**
across minor versions — `@2.3` extends `@2.2` extends `@2.1`, so an `@2.3`
implementation **does** satisfy an `@2.1` lookup. Source: AOSP, "Interfaces and
packages", *Interface inheritance*:
<https://source.android.com/docs/core/architecture/hidl/interfaces>

> "An interface can be an extension of a previously-defined interface. … Each
> interface in a package with a non-zero minor version number must extend an
> interface in the previous version of the package."

The version-mismatch theory is therefore **discarded**. The real reason the
service is not found/started is still **unknown** at this layer. **[?]**

## Why the earlier evidence was weaker than claimed

- The `dumpsys` commands were run **without root**, so errors were silently
  suppressed and `dumpsys fingerprint` came back empty for that reason too — not
  necessarily because the HAL is absent. **[I, maintainer note]**
- `dmesg`/`logcat` show the *symptom* (no binder) but **not the reason** the
  service fails to start (no `init` failure line for the specific `.rc`, no
  SELinux denial, no crash of the daemon captured).

## Next steps (what would actually move this)

1. **Re-collect with root** (`adb root` / `su`): `dmesg`, logcat, and `lshal` —
   so suppressed errors surface.
2. **Inspect the vendor init `.rc`** on-device:
   `cat /vendor/etc/init/android.hardware.biometrics.fingerprint*` and
   `ls -laZ /vendor/bin/hw/` — check the service is declared, `class hal`, and
   whether it is **disabled** or **errored at start**.
3. **Check for SELinux denials**: `dmesg | grep -i avc` and
   `logcat | grep -i avc` around boot.
4. **Try starting it manually** and read the exact error:
   `setprop ctl.start android.hardware.biometrics.fingerprint@2.3-service.xiaomi`
   (or `@2.1` equivalent) and capture stderr.
5. Collect `lshal` full output to see whether the interface is listed as
   declared-but-not-registered.
6. Compare against a device where Goodix works on the same MTK + AIDL stack.

## Fix

**Not determined yet.** Do not ship a fix until the start-failure reason is
captured with root. See `docs/08-services-audit.md` §1.
