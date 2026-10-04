# 07 — Charging (slow) and GPS (slow fix)

- Date: 2026-10-04
- Device: `ruby` (MT6877V), LineageOS 23.2, kernel 6.6.127
- Evidence: `logs/2026-10-04-charging/charging-timeline.txt` (from
  `dumpsys batterystats --history`), `logs/2026-10-04-services/` (power/GNSS),
  `logs/2026-10-04/dmesg.txt`
- Legend: **[V]** verified · **[I]** inferred · **[?]** unknown

> **Note on method:** the device was **not plugged in** at capture time
> (`usb online=0`, `ac online=0`, `Not charging`), so this analysis is based on
> the **historical** `batterystats` records, as requested.

## Part A — Charging is extremely slow

### A.1 Historical charge rates **[V]**

Computed from `batterystats` charge counters (uAh):

| Episode | Window | Duration | Change | Effective rate |
|---------|--------|---------:|-------:|---------------:|
| EP1 ac | 10-02 09:09→11:38 | 149 min | 399 → 3251 | **≈ 1148 mAh/h** |
| EP3 ac | 10-02 20:43→23:14 | 151 min | 805 → 3206 | **≈ 954 mAh/h** |
| EP4 ac | 10-03 10:41→11:10 | 29 min | 13 → 285 | **≈ 563 mAh/h** |
| EP7 ac | 10-03 15:39→15:46 | 7 min | 0 → 113 | **≈ 969 mAh/h** |
| EP5 **usb** | 10-03 11:46→12:18 | 32 min | 629 → **574** | **NEGATIVE** (discharged while plugged) |

**Interpretation [V]:**
- Even on **AC**, the best observed rate is **~1150 mAh/h**. For a 5000 mAh
  battery that is **>4 h for a full charge** — far below the device's rated
  fast-charge (33 W ≈ 5000+ mAh/h equivalent). This matches the user report:
  "extremely slow".
- **EP5 is the smoking gun:** plugged into **USB**, the pack went **629 → 574**
  over 32 min — net **discharge while on a charger**. The charger is not
  supplying enough current to cover system load.

### A.2 What the power supply reports **[V]**

At capture (`battery/uevent`):

```
POWER_SUPPLY_CONSTANT_CHARGE_CURRENT=12400000   # 12.4 A configured
POWER_SUPPLY_CURRENT_NOW=631000 … 944000        # 0.63-0.94 A actual (discharging)
POWER_SUPPLY_CHARGE_FULL=4066000                # 4066 mAh
POWER_SUPPLY_CHARGE_FULL_DESIGN=5000000         # 5000 mAh design
POWER_SUPPLY_CYCLE_COUNT=1182
POWER_SUPPLY_CHARGE_CONTROL_LIMIT=0
POWER_SUPPLY_CHARGE_CONTROL_LIMIT_MAX=16
POWER_SUPPLY_THERMAL_LIMIT_FCC=0
POWER_SUPPLY_NIGHT_CHARGING=0
POWER_SUPPLY_INPUT_SUSPEND=0
```

And from `dumpsys battery` / `dmesg`:

```
Max charging current: 0
Charging policy: 0
charger_manager_get_sic_current sic_current=12400
TCPC-TCPC:bat_update_work_func Battery Discharging
```

- **`Max charging current: 0`** while plugged (history) — the framework sees
  **no negotiated current**.
- **`CHARGE_CONTROL_LIMIT=0`** with `MAX=16` — the **SIC (step-charging) limit is
  pinned at step 0**, i.e. the *lowest* current step. This is a prime suspect:
  the device may be charging at the minimum step instead of scaling up. **[I]**
- `sic_current=12400` (mA) appears in dmesg — so "SIC" is active and reports
  12.4 A available, but the applied limit is step 0. **[V]**

### A.3 Battery health — a second, independent factor **[V]**

```
CHARGE_FULL = 4066 mAh   vs   DESIGN = 5000 mAh   →  ~81% state of health
CYCLE_COUNT = 1182
```

The battery has **~1182 cycles and ~81% capacity**. An aged battery charges
slower in the CV (constant-voltage) phase because internal resistance rises.
This **amplifies** but does **not** fully explain the AC rate (>4 h), so the
charge-control issue (A.2) is the primary suspect. **[I]**

### A.4 Hypotheses and fix directions

| # | Hypothesis | Confidence | Fix direction |
|---|-----------|-----------|---------------|
| C1 | SIC/charge_control_limit stuck at step 0 → lowest current | High | Inspect/fix the MT6360 charger config in the DTS; check `charger_manager` SIC policy |
| C2 | Charger not negotiating HVDCP/AFC/PD (falls back to 5 V default) | High | Check charger/PD config + the charger IC node properties in DTS |
| C3 | Thermal `thermal_limit_fcc=0` / charger thermal causes throttling | Med | Verify thermal throttling during charge (log thermal zones while charging) |
| C4 | Aged battery (81% SoH) slows CV phase | Med | Not fixable in ROM; explains part of slowness |
| C5 | `input_current_limit` not set / reported as 0 | Med | Set a correct default input current limit |
| C6 | Cable/charger hardware (test with a known 33 W charger) | ? | Hardware A/B test |

**How to confirm when the device can be plugged in [V]:**
1. `cat /sys/class/power_supply/charger/charge_type` (SDP/CDP/DCP/HVDCP).
2. Watch `input_current_limit`, `constant_charge_current`, `current_now` over time.
3. Watch `charge_control_limit` — does it stay 0?
4. `dmesg | grep -i charger` during charge to see the negotiation.

## Part B — GPS takes a long time to fix (but works)

### B.1 What is present and healthy **[V]**

```
init.svc.agpsd = running
init.svc.vendor.gnss-default = running
android.hardware.gnss@1.0/1.1/2.0/2.1 = registered (Y)
vendor.gps.gps.version = 0x6877     (matches MT6877)
vendor.debug.gps.support.l5 = 1     (L5 band enabled)
vendor.gps.clock.type = 21
persist.sys.gps.lpp = 2
```

- **The GNSS stack is fully present and running** — this is not a missing-HAL
  problem (unlike the fingerprint). **[V]**
- L5 support and the MT6877 GPS version are declared. **[V]**

### B.2 Why it may be slow **[I]**

Since the stack is present, a slow TTFF (time-to-first-fix) usually comes from:

1. **No AGPS/SUPL data** — without network-assisted data, the receiver must
   download the full ephemeris/almanac from satellites (cold start = minutes).
2. **SUPL server not configured** in the vendor GPS config.
3. **XTRA/LPP data not refreshing** (`persist.sys.gps.lpp` exists; check if the
   data actually downloads).
4. **Antenna / RF** affecting signal acquisition.

### B.3 Fix directions

| # | Item | Fix |
|---|------|-----|
| G1 | SUPL server config | Verify `supl` host/port in vendor GPS config (MTK: `gnss` config path) |
| G2 | XTRA/LPP data refresh | Ensure the AGPS data downloader runs and refreshes before a fix |
| G3 | `gps.conf` / MTK GPS params | Compare with a working MTK device's GPS config |
| G4 | Cold vs warm start | Measure TTFF cold (worst case) to set expectations |

### B.4 How to measure **[V]**

- Cold TTFF: after a GPS data reset, time to first fix.
- Warm/hot TTFF: normal use.
- Bookmark the comparison against a working MTK device is in `docs/references.md`.

## References / peers

Comparative MTK devices for both issues: `pmos-xiaomi-thunder` (MT6833),
`MT6878-mainline/linux`, `xiaomi-mt6893-dev/kernel_xiaomi_mt6893`,
`rubyx-devs/device_xiaomi_rubyx`. See `docs/references.md`.
