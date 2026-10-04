# 05 — ROM / HAL audit (non-kernel)

- Date: 2026-10-04
- Device: `ruby` (MT6877V), LineageOS 23.2 `23.2-20261002-UNOFFICIAL-rubyx`, Android 16
- Evidence: `logs/2026-10-04/` — `props-all.txt`, `logcat-*`, `fp-*`, `dmesg.txt`
- Legend: **[V]** verified in source/log · **[I]** inferred · **[?]** unknown

## TL;DR

1. **Fingerprint root cause nailed.** `dmesg` shows init failing **180×** in 91 s:
   `Could not find 'android.hardware.biometrics.fingerprint@2.1::
   IBiometricsFingerprint/default'`. The HIDL service is **not declared/installed
   at all**. This is definitive (supersedes the "hypothesis" wording in
   ISSUE-001). Fix = add the HIDL fingerprint service (or an AIDL one) to the
   device tree. **[V]**
2. The **build fingerprint is Android 14** (`:14/UP1A...`) while the system is
   **Android 16** — expected for bring-up, but it means several HALs are
   mismatched generations. **[V]**
3. **`lmkd` is running** but memory pressure is high (see ISSUE-002); LRU/cached
   tuning is the leverage. **[V]**
4. Dalvik/heap props are **default LineageOS** — no device-specific tuning is
   present (an optimization opportunity, not a bug). **[V]**

## 1. Fingerprint HAL — definitive root cause

`dmesg.txt` (repeated 180 times, exactly):

```
init: Control message: Could not find
'android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default'
for ctl.interface_start from pid: 536 (/system/system_ext/bin/hwservicemanager)
```

What this means, step by step:

1. `hwservicemanager` asks init to start the interface
   `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default`.
2. init looks for a service that declares that interface in `vendor/etc/init/*.rc`
   → **none exists**.
3. So the interface is never registered → `HidlToAidlSensorAdapter: Fingerprint
   HAL not available` → `HIDL daemon is null` → `dumpsys fingerprint` empty →
   Settings shows no enrollment. **[V]**

**Supporting facts [V]:**
- `feature:android.hardware.fingerprint` is advertised (framework expects it).
- Sensor vendor is **Goodix** (`persist.vendor.sys.fp.vendor=goodix`).
- `/vendor/lib64/hw/fingerprint.goodix.so` **exists**, but there is **no**
  `android.hardware.biometrics.fingerprint@2.1-service*` binary next to it.

### Fix

In the device tree (`rubyx-devs/device_xiaomi_rubyx`):

1. Build & install a fingerprint HAL service that provides
   `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint`.
   - Either the vendor HIDL implementation, or
   - an **AIDL** implementation if the vendor blob only supports AIDL.
2. Declare it in the vendor init `.rc` (class `hal`, `interface hal`).
3. Add it to `manifest.xml` / `compatibility_matrix`.
4. Verify: `dumpsys fingerprint` shows a sensor; logcat loses `HIDL daemon is
   null`; Settings shows "Add fingerprint".

> Compare against a working Goodix MTK device on Android 13+ to copy the exact
> HAL declaration (see `docs/references.md`).

## 2. Build / HAL generation mismatch **[V]**

```
ro.build.fingerprint = Redmi/ruby_global/ruby:14/UP1A.230620.001/
                       OS2.0.11.0.UMOMIXM:user/release-keys
```

- Vendor blobs come from **Android 14 / HyperOS 2**, system is **Android 16**.
- Practical impact: some HALs are legacy (HIDL) where Android 16 is AIDL-first.
  This is *the* mechanism behind ISSUE-001, and likely behind other HAL quirks.
- Not a bug per se, but each legacy HAL needs a bridge or a conversion.

## 3. Memory / LMKD **[V]**

```
[init.svc.lmkd]: running
[persist.sys.lmk.reportkills]: true
[ro.lmk.swap_compression_ratio]: 2
```

- lmkd is active, but `logcat` shows `am_kill ... binder space running out while
  frozen` → the frozen/cached working set exceeds what binder/LMK budget allows.
- Leverage: tune `ro.lmk.*` thresholds, cap cached apps, and size zram. This is
  the ROM-side half of ISSUE-002.

## 4. Dalvik / runtime props **[V]**

```
dalvik.vm.heapsize           512m
dalvik.vm.heapgrowthlimit    256m
dalvik.vm.systemservercompilerfilter  speed-profile
dalvik.vm.usap_pool_enabled  false
dalvik.vm.isa.arm64.variant  cortex-a76
dalvik.vm.isa.arm.variant    cortex-a55
```

- These are the **defaults** for this device class; the CPU variants
  (`cortex-a76` / `cortex-a55`) are correct for MT6877. **[V]**
- No device-specific tuning is applied — an opportunity for small, safe wins
  (e.g. `dalvik.vm.usap_pool_enabled`, heap growth) but low priority vs. the
  fingerprint and memory issues. **[I]**

## 5. Other observed errors

- App crash `com.intsig.camscanner:engine` (SIGSEGV in `libmagicenhancer.so`) —
  **third-party app bug**, not the ROM. Documented for completeness only. **[V]**
- `E AppOps: Cannot noteOperation` (×2) — benign. **[V]**
- No AVC denials (`avc: denied`) surfaced in the collected window. **[V]**

## 6. Improvement proposals

| # | Improvement | Detail | Priority | Risk |
|---|-------------|--------|----------|------|
| R1 | **Fingerprint HAL** | Declare/install the HIDL (or AIDL) fingerprint service | **High** | Low |
| R2 | **LMKD / frozen-app tuning** | Tune `ro.lmk.*`, cap cached apps | High | Med |
| R3 | **zram sizing** | Match zram to 7.5 GiB device, enable better compressor | High | Med |
| R4 | **Dalvik tuning** | Small heap/USAP tweaks | Low | Low |
| R5 | **HAL generation audit** | Review every legacy HIDL that Android 16 is bridging | Med | Med |
| R6 | **Radio/RIL check** | Not audited yet (needs call test) | — | — |

## 7. How comparable devices solve it

- **`rubyx-devs/device_xiaomi_rubyx`** — the actual device tree; where R1/R2 go.
- **`vitoramaral10/pmos-xiaomi-thunder`** (MT6833) — documents bring-up and
  connectivity; Goodix/Novatek style peripherals.
- Other Goodix MTK ROMs on Android 13+ — copy the HAL declaration verbatim.

## 8. Open questions **[?]**

- Which HAL exactly does the vendor blob implement (HIDL 2.1 vs AIDL)? Needs
  inspection of the `goodix` blob's exported interface.
- Are there other `Could not find ...` HAL failures hidden by log noise?
