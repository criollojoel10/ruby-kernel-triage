# 08 — Services & HAL audit

- Date: 2026-10-04
- Device: `ruby` (MT6877V), LineageOS 23.2, kernel 6.6.127
- Evidence: `logs/2026-10-04-services/` (`svc-init.txt` 263 entries, `lshal.txt`
  79 HALs), `logs/2026-10-04/` (logcat/dmesg/props)
- Legend: **[V]** verified · **[I]** inferred · **[?]** unknown

## TL;DR

1. **Fingerprint: root cause corrected.** The device tree **declares and installs
   a HIDL `@2.3` service**
   (`android.hardware.biometrics.fingerprint@2.3-service.xiaomi` in `device.mk`
   line 143), but the framework requests **`@2.1`**. **Version mismatch** → the
   service is never found. See §1. This supersedes the "service entirely
   missing" wording in ISSUE-001/`docs/05`.
2. **Services are basically healthy.** 94 running, 38 stopped — the stopped ones
   are normal one-shots (apexd, bootanim, `boringssl_self_test*`, etc.).
3. **HAL availability is HIDL-only** in `lshal` output: **AIDL HALs are
   invisible** to that dump, so "missing" entries must be read with care. **[V]**
4. **`vendor.mediatek.hardware.mtkpower@1.2` is declared in the VINTF manifest
   but does NOT register** (only 1.0/1.1 do). Performance/power-impacting
   inconsistency. See §3.

## 1. Fingerprint — corrected root cause **[V]**

`device.mk` (branch `lineage-23.2`):

```
141: # Fingerprint
143:     android.hardware.biometrics.fingerprint@2.3-service.xiaomi
168:     init.fingerprint.rc \
250: .../android.hardware.fingerprint.xml  (feature declared)
```

- The tree **ships a HIDL `@2.3`** fingerprint service and an
  `init.fingerprint.rc`. **[V]**
- The running system requests
  `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default`
  (180× in dmesg). **[V]**
- **A `@2.3` service does not satisfy a `@2.1` client** (`@2.3` is not
  interface-compatible with the `@2.1` `IBiometricsFingerprint` FQN the
  biometric service looks up). → `Fingerprint HAL not available`. **[I, high
  confidence]**
- There is a commit **"Move to Xiaomi fingerprint AIDL"** in the device tree,
  and LineageOS `hardware/xiaomi` **already has the AIDL implementation**
  (`aidl/fingerprint/`, `android.hardware.biometrics.fingerprint-service.xiaomi.rc/.xml`).
  But that migration is **not on the `lineage-23.2` branch the device runs**. **[V]**

### Fix options

| Option | Action | Notes |
|--------|--------|-------|
| **A (recommended)** | Apply the "Move to Xiaomi fingerprint AIDL" commit on `lineage-23.2` | Aligns with Android 16 AIDL-first; uses existing LineageOS code |
| B | Patch `manifest.xml`/`init.fingerprint.rc` to serve `@2.1` (or make the client accept `@2.3`) | Quick hack; fights the platform direction |
| C | Add the AIDL `fingerprint-service.xiaomi` + its `init` rc + VINTF xml | Same as A, done by hand |

**Verify after fix:** `dumpsys fingerprint` shows a sensor; logcat loses
`HIDL daemon is null`; Settings shows "Add fingerprint".

## 2. Service states **[V]**

- **94 running / 38 stopped** (`init.svc.*`).
- Stopped = normal one-shots: `apexd`, `apexd-bootstrap`, `bootanim`,
  `boringssl_self_test*`, `derive_classpath`, `idmap2d`, `odsign`,
  `system_aconfigd_*`, `usbd`, `thermal_manager` (started on demand), etc.
- **`conninfra_loader` and `ccci3_mdinit` stopped** — these are MTK connectivity/
  modem loader one-shots; expected stopped after they run. No symptom observed
  (calls not yet tested). **[I]**

## 3. `mtkpower@1.2` declared but absent **[V]**

`configs/vintf/manifest.xml` declares:

```
vendor.mediatek.hardware.mtkpower  @1.2::IMtkPerf/default, @1.2::IMtkPower/default
```

But at runtime only **1.0 / 1.1** register; **1.2 does not** (lshal shows
`N` = not available). The MTK power/perf HAL is what applies **power hints /
DVFS boosts**, so a missing version can affect **performance and battery**. **[I]**

**Fix:** either the vendor blob supporting 1.2 must be shipped, or the manifest
must be corrected to declare the versions actually implemented (1.1).

## 4. HALs present (selected) **[V]**

- **GNSS**: `android.hardware.gnss@1.0/1.1/2.0/2.1` registered; `agpsd` and
  `vendor.gnss-default` running → GNSS stack OK (slow fix is an AGPS/SUPL issue,
  see `docs/07`).
- **Camera**: `android.frameworks.cameraservice.service@2.0/2.1/2.2`,
  `camerahalserver` (pid 1252), `cameraserver` (1212) running.
- **Audio**: `audioserver` (1041) running; MTK audio (`mt6877-afe-pcm`) present
  in dmesg.
- **Radio**: `android.hardware.radio` declared; `ccci_mdinit` (1051) running.
- **Keymaster/Gatekeeper**: present (`keymaster_attestation-1-1`, `gatekeeperd`).
- **NFC**: `st21nfc` present (see `docs/07` peripherals).

## 5. Errors / denials / crashes in the collected window **[V]**

- **No `avc: denied` (SELinux) surfaced** in the window. **[V]**
- **No `ANR in ...`** surfaced. **[V]**
- Only app-level crash: `com.intsig.camscanner:engine` (SIGSEGV in
  `libmagicenhancer.so`) — **third-party app bug**, not the ROM. **[V]**
- `am_kill: binder space running out while frozen` — memory pressure, tracked in
  ISSUE-002. **[V]**

## 6. Improvement proposals

| # | Improvement | Basis | Priority | Risk |
|---|-------------|-------|----------|------|
| S1 | **Fingerprint HIDL→AIDL** | `device.mk` @2.3 vs client @2.1; LineageOS AIDL code exists | **High** | Low |
| S2 | **Fix/correct `mtkpower@1.2` VINTF** | manifest vs runtime mismatch | Med | Low |
| S3 | **Disable unused/debug services** | AOSP/LineageOS defaults | Low | Low |
| S4 | **Verify radio/telephony with a call test** | not yet tested | Med | Low |
| S5 | **Trim vendor debug services** (e.g. `dmesgd` off) | log hygiene (docs/04) | Low | Low |

## 7. References (official / peers)

- Android **AIDL for HALs**: https://source.android.com/docs/core/architecture/aidl
- LineageOS `hardware/xiaomi` AIDL fingerprint: `aidl/fingerprint/` (branch `lineage-23.2`).
- Device tree: `rubyx-devs/device_xiaomi_rubyx` (`device.mk`, `configs/vintf/manifest.xml`,
  `rootdir/etc/init.fingerprint.rc`).
- Peer MTK: `xiaomi-mt6893-dev/kernel_xiaomi_mt6893`, `vitoramaral10/pmos-xiaomi-thunder`.

## 8. Open questions **[?]**

- Does the "Move to Xiaomi fingerprint AIDL" commit also touch VINTF/init, or
  only `device.mk`? Needs a full diff before applying.
- Which vendor blob implements `mtkpower@1.2` — is it shipped but not declared,
  or declared but absent?
