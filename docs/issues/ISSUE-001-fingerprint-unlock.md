# ISSUE-001 — Fingerprint unlock not working

- Status: **open — root cause identified, fix pending maintainer validation**
- Device: `ruby` (MT6877V), LineageOS 23.2, kernel 6.6.127
- Evidence: `logs/2026-10-04-fp-root/` (root-enabled re-collection)
- Legend: **[V]** verified · **[I]** inferred · **[?]** unknown

## Symptom

No fingerprint enrollment possible ("Add fingerprint" absent in Settings).
`feature:android.hardware.fingerprint` is advertised **[V]**, sensor vendor prop
is `persist.vendor.sys.fp.vendor=goodix` **[V]**, but the HAL interface is never
registered and every bind fails with `Fingerprint HAL not available`.

## Root cause — the `.rc` declares the service but not its HIDL `interface` **[V]**

On-device, with root (`su`, KernelSU, SELinux `Enforcing`) **[V]**:

| # | Fact | Command / evidence |
|---|------|--------------------|
| 1 | Root OK; SELinux **Enforcing** | `su -c "id; getenforce"` → `uid=0 u:r:ksu:s0`, `Enforcing` (`01-root.txt`) |
| 2 | The `.rc` exists and declares the service | `cat /vendor/etc/init/android.hardware.biometrics.fingerprint@2.3-service.xiaomi.rc` → `service vendor.fps_hal ... class late_start`, `user system`, `group system input uhid` (`02-init-rc.txt`) |
| 3 | The binary exists **and the process runs** | `ls -la /vendor/bin/hw/...`; `getprop init.svc.vendor.fps_hal` → `[running]`, pid 1331 (`03-binary-initstate.txt`) |
| 4 | But the interface is **not registered** | `lshal --neat \| grep fingerprint` → empty (`08-lshal-dumpsys-root.txt`) |
| 5 | **The `.rc` has NO `interface` line** (and no `disabled`) | `grep -nE "interface\|disabled\|class"` → only `class late_start` (`06-interface-strings.txt`) |
| 6 | The binary does expose `@2.3::IBiometricsFingerprint` | `strings` → `...fingerprint4V2_322IBiometricsFingerprint17registerAsService...`, `@2.1.so/@2.2.so/@2.3.so` (`06-interface-strings.txt`) |
| 7 | **No `.rc` anywhere declares a fingerprint `interface`** | `grep -rln "biometrics.fingerprint@2" /vendor/etc/init /odm/etc/init /system/etc/init` → only the same `.rc` (`07b-rc-interface-grep.txt`) |
| 8 | init cannot resolve the lazy start | `W libc: Unable to set property "ctl.interface_start" to "...fingerprint@2.1::IBiometricsFingerprint/default": PROP_ERROR_HANDLE_CONTROL_MESSAGE (0x20)` (`05b-logcat.txt`) |

### Causal chain **[V]**

1. `vendor.fps_hal` starts (`init.svc.vendor.fps_hal: running`) but its `.rc`
   does not associate the HIDL interface. **[V]**
2. `hwservicemanager` looks up
   `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default`
   → not registered. **[V]**
3. It tries to start it as a **lazy HAL**; init fails with
   `ctl.interface_start ... PROP_ERROR_HANDLE_CONTROL_MESSAGE (0x20)` because
   **no service declares that interface** in any `.rc`. **[V]**
4. → `Fingerprint HAL not available` / `HIDL daemon is null` → no enrollment. **[V]**

### Official source

AOSP — *HIDL for HALs*: a service is associated with its HIDL interface via the
`interface <fqname>@<ver>::<Iface>` line in its init `.rc`; that declaration is
what init uses to resolve an `interface_start` request from
`hwservicemanager`. <https://source.android.com/docs/core/architecture/hidl/>

## Retracted hypothesis (was wrong — kept for the record)

❌ **"A `@2.3` service cannot serve a `@2.1` client."** **False.** HIDL
interfaces inherit across minor versions — `@2.3` extends `@2.2` extends `@2.1`
— so an `@2.3` implementation **does** satisfy an `@2.1` lookup. Source: AOSP,
*Interface inheritance*:
<https://source.android.com/docs/core/architecture/hidl/interfaces>. The
version-mismatch theory is **discarded**.

Also corrected: the earlier `dumpsys` runs were **unprivileged**, so their errors
were suppressed and an empty output did **not** prove the HAL was absent. The
root-enabled re-collection above supersedes them.

## Proposed fix (pending maintainer validation) **[I]**

Add the missing `interface` declaration to the service's init `.rc`:

```
service vendor.fps_hal /vendor/bin/hw/android.hardware.biometrics.fingerprint@2.3-service.xiaomi
    class late_start
    user system
    group system input uhid
    interface android.hardware.biometrics.fingerprint@2.3::IBiometricsFingerprint default
```

Also confirm the VINTF `manifest.xml` / `compatibility_matrix` list the same
interface. The exact `interface` FQN must match what the vendor blob registers.

**Open for the maintainer (Aeron):** validate the exact `interface` line/FQN
against a working device of the same family — the reporter does not have a
reference device. This is the one check (step 9) deliberately left to the
maintainer.

### Alternative if HIDL registration is intended to be handled differently

If the vendor tree expects the HIDL→AIDL migration ("Move to Xiaomi fingerprint
AIDL" commit exists in `ruby-devs` device tree; LineageOS `hardware/xiaomi` ships
`aidl/fingerprint/`), the `interface`/AIDL `init` binding for that path should be
used instead. Maintainer decides the direction.

## Verification after fix

- `getprop init.svc.vendor.fps_hal` stays `running`
- `lshal --neat | grep -i fingerprint` shows the interface
- logcat loses `Fingerprint HAL not available` / `HIDL daemon is null`
- `dumpsys fingerprint` reports a sensor with enrollment capacity
- Settings shows "Add fingerprint"

## Evidence files

`logs/2026-10-04-fp-root/`: `01-root.txt`, `02-init-rc.txt`,
`03-binary-initstate.txt`, `04-process.txt`, `05-logs-daemon.txt`,
`05b-logcat.txt`, `06-interface-strings.txt`, `07-avc.txt`,
`07b-rc-interface-grep.txt`, `08-lshal-dumpsys-root.txt`.
