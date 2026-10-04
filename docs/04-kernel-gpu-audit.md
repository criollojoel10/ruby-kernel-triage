# 04 — Kernel / GPU performance audit

- Date: 2026-10-04
- Device: `ruby` (MT6877V), LineageOS 23.2, kernel `6.6.127-4k-ged71a8f07b9c-dirty`
- Evidence: `logs/2026-10-04/dmesg.txt` (one 91 s window, 29 971 lines)
- Legend: **[V]** verified in source/log/API · **[I]** inferred · **[?]** unknown

## TL;DR

1. **The `Cache flush buffer fail` storm is NOT the GPU.** The exact string comes
   from MediaTek's **video codec** driver, `drivers/media/platform/mtk-vcu/
   mtk_vcodec_mem.c` (formerly `mtk-vcodec`), on the `dma_buf` cache-flush path.
   **[V]** — see §2. Do **not** patch Mali for this.
2. The kernel log is **dominated by noise**, not by faults: `goodixFP` (18 483
   lines), touch `FTS_TS` (3 510), `wlan` (1 836), `CONN_BUS` (1 020),
   `haptic_hv` (1 366). Printing interrupts on the hot path is itself a latency
   and power cost. **[V]**
3. CPU frequency scaling **works** (governors `schedutil/performance/conservative/
   powersave` present; cores observed at 1.26 / 1.54 GHz and up to 2.0 GHz). The
   earlier "pinned at 900 MHz" reading was an **idle sample**, not a bug. **[V]**
4. Actionable items are mostly **tuning + log hygiene**, plus one codec fix.

## 1. Noise budget (one 91 s dmesg window) **[V]**

| Source | Lines | Note |
|--------|------:|------|
| `goodixFP` | 18 483 | fingerprint IRQ + netlink, fires per touch |
| `FTS_TS` | 3 510 | touchscreen report |
| `wlan` | 1 836 | TX/RX INFO logs |
| `haptic_hv` | 1 366 | vibrator |
| `Cache flush buffer fail` | 1 219 | **codec** (see §2) |
| `CONN_BUS_C` | 1 020 | connectivity bus debug |
| `update cpufreq limit` | 432 | cpufreq transitions |
| `Thermal` | 263 | thermal zones |
| `init:` | 180 | fingerprint HAL not found (ISSUE-001) |
| **total** | **29 971** | in 91 s → ~330 lines/s |

A driver that logs per interrupt is a real cost: console/serial writes take
locks and wake the writer. Most of these are `pr_info`/`pr_debug` that a
production kernel should not print by default.

## 2. The `Cache flush buffer fail` storm — root cause **[V]**

Exact source string, confirmed by reading the vendor tree
`xiaomi-mediatek-devs/android_kernel_xiaomi_mt6877`
(branch `experimental/mali/lineage-20`) and mirrored in
`OnePlusOSS/android_kernel_oneplus_mt6877`:

```
drivers/media/platform/mtk-vcu/mtk_vcodec_mem.c
    → dma_buf cache maintenance path
    → pr_err("Cache flush buffer fail, iova = %llx, size = %d")
```

Evidence in our log:

```
Cache flush buffer fail, iova = 1fc000000, size = 56448
Cache flush buffer fail, iova = 1f8800000, size = 8384
```

- 1 219 occurrences in 91 s (~13/s), sizes 1 064–56 448 bytes, iovas in
  `0x1e7800000 … 0x1fc000000` (the MTK reserved/CMA range used by the codec).
- The codec is **not in use** during idle, yet the flush keeps failing → a
  cache-maintenance call is returning failure on buffers that are **not mapped /
  already unmapped**, which is the classic "flush on a stale dma-buf attachment"
  pattern.

> **Correction to earlier triage:** ISSUE-002 initially attributed this to the
> Mali-G68 GPU/IOMMU. That was wrong. The string is the **video codec**. This
> document supersedes that attribution.

## 3. What is healthy **[V]**

- **cpufreq**: `scaling_available_governors = conservative powersave performance
  schedutil`; `scaling_available_frequencies` = 500 MHz … 2.0 GHz. Cores scale.
- **Thermals** (from `thermal.txt`): AP ~41 °C, CPU ~50 °C, PA ~52 °C — **no
  throttling** observed.
- **PMIC**: MT6359P present; MT6360 (chg/led/tcpc) present.

## 4. Improvement proposals

| # | Improvement | Detail | Applies to ruby | Risk | How to verify |
|---|-------------|--------|-----------------|------|---------------|
| K1 | **Fix / silence the codec flush** | Guard the `dma_buf` cache flush in `mtk_vcodec_mem.c` against unmapped attachments, or demote the `pr_err` to `pr_debug_ratelimited` | High | Low | `dmesg | grep -c 'Cache flush buffer fail'` → 0 |
| K2 | **Rate-limit per-IRQ logging** | Demote `goodixFP`, `FTS_TS`, `haptic_hv`, `wlan` INFO logs to `*_ratelimited`/debug | High | Low | dmesg line rate drops ≫10× |
| K3 | **zram / swap tuning** | Current swap ~72% used, `MemFree` ~300 MB (see ISSUE-002). Tune `vm.swappiness`, `zram` size, `lz4`/`zstd` | High | Med | PSI memory pressure, app-switch latency |
| K4 | **LMKD / cached-process tuning** | `am_kill: binder space running out while frozen` → tune `ro.lmk.*` / reduce cached apps | High | Med | No binder-space kills |
| K5 | **schedutil tuning** | EAS/PELT params, `rate_limit_us`, uclamp | Med | Med | jank %, freq residency |
| K6 | **I/O scheduler** | Check UFS scheduler (`mq-deadline`/`kyber`) + `read_ahead_kb` | Med | Low | `fio`, app launch |
| K7 | **CONN_BUS / wlan debug off** | The `[CONN_BUS_C]debug_ctrl_setting` and wlan INFO logs are debug-only | High | Low | noise budget |

## 5. What comparable MediaTek trees do

- **`MT6878-mainline/linux`** (MT6878, same block): mainline bring-up; the
  display/IOMMU/codec work there is the reference for cleaning up the vendor
  codec path. **[V]** https://github.com/MT6878-mainline/linux
- **`mt6785-mainline/linux`** (GitLab PMOS): shows how MTK drivers are
  re-implemented cleanly (clk/pinctrl/dts, cpuidle). **[V]**
- **`vitoramaral10/pmos-xiaomi-thunder`** (MT6833): GPU backport and connectivity
  bring-up on a vendor kernel — closest "downstream + improvements" model. **[V]**
- **`OnePlusOSS/android_kernel_oneplus_mt6877`**: same MT6877 vendor codec
  source; useful to diff the `mtk_vcodec_mem.c` fix. **[V]**

## 6. Open questions **[?]**

- Does the codec flush failure cause visible artifacts, or is it benign noise
  with a real cost only in log volume? Needs a decode workload test.
- Real cause of the memory pressure: leak vs. too many cached apps? Needs
  per-process RSS sampling.
