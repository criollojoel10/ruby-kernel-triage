# ISSUE-002 — General UI/system lag

- **Severity:** Medium
- **Status:** Investigating — multiple contributing factors identified
- **Collected:** 2026-10-04, `logs/2026-10-04/`
- **Related files:** `loadavg.txt`, `cpufreq.txt`, `meminfo.txt`,
  `dmesg.txt`, `logcat-events.txt`, `thermal.txt`

## Symptom

The system feels laggy: stutters in the UI, slow app switching, occasional
jank. Not constant, but frequent enough to notice.

## Evidence

### 1. Memory pressure is high

`meminfo.txt`:

```
MemTotal:        7591944 kB
MemFree:          308984 kB
MemAvailable:    2482736 kB
SwapTotal:       4548132 kB
SwapFree:        1286792 kB
```

- Only **~300 MB free** of 7.5 GiB.
- **Swap is ~72% used** (3.26 GiB swapped out of 4.55 GiB). An Android device
  that is swapping this hard will stutter whenever it touches cold pages.

### 2. CPU is pinned at the minimum frequency

`cpufreq.txt` shows every core at its **lowest** OPP, with no governor listed:

```
--- /sys/devices/system/cpu/cpu0/cpufreq/      900000
--- /sys/devices/system/cpu/cpu7/cpufreq/      910000
```

All cores report ~900 MHz. Two readings are possible and must be disambiguated
(see below): either the sampler caught an idle moment, or **the cpufreq
governor is not scaling** and the device is stuck slow.

### 3. The kernel log is flooded

`dmesg.txt` (2.1 MB in a single boot) is dominated by two noisy sources:

| Count | Message |
|-------|---------|
| ~thousands | `Cache flush buffer fail, iova = ...` (GPU/IOMMU) |
| 51+ | `[CONN_BUS_C]ahb_apb_timeout:[...]` (connectivity bus) |
| 39 | `[wlan] qmHandleRxPackets:(RX WARN) ... non-interesting type` |
| 30 | `[wlan] mtk_cfg80211_get_station:(REQ WARN) last Rx link speed` |

A `dmesg` this noisy on the serial console / log path is itself a source of
latency (logging on the critical path) and hides real errors.

### 4. Framework is killing processes

`logcat-events.txt`:

```
I am_kill : [0,19634,com.google.android.gms.learning,935,
             Async binder space running out while frozen,134448]
```

Apps are being killed with **"binder space running out while frozen"** — a sign
the cached/frozen process set is too large and binder buffers are exhausted.

### 5. Thermal state is normal

`thermal.txt`: AP ~41 °C, CPU ~50 °C, PA ~52 °C. **Not thermal throttling.**

## Analysis

This is **not one bug** — it is at least three stacked effects:

1. **RAM starvation / swap thrash.** With ~300 MB free and heavy zram/swap use,
   any foreground work competes with page reclaim.
2. **CPU frequency suspicion.** If all cores are genuinely stuck at 900 MHz, the
   device is running at ~35% of its max clock and will feel sluggish everywhere.
   This must be confirmed with a load test while sampling `scaling_cur_freq`.
3. **Log flooding on the kernel path.** The `Cache flush buffer fail` and
   `ahb_apb_timeout` storms add overhead and obscure real faults.

The `Cache flush buffer fail, iova = ...` messages are the most suspicious:
they point at the **GPU/IOMMU (Mali-G68)** cache-coherency path and appear
thousands of times. If the GPU driver is mis-flushing caches, rendering jank
follows.

## Root cause / hypothesis

- **H1 (memory):** too many cached/frozen apps for 7.5 GiB → swap thrash and
  `binder space running out` kills. *Fix direction:* tune LMKD/frozen-process
  limits, reduce `MAX_CACHED_PROCESSES`, or check for a memory leak in a vendor
  daemon.
- **H2 (cpufreq):** the governor may be missing/misconfigured. *Confirm with a
  load test* (`scaling_governor`, `scaling_cur_freq` under load).
- **H3 (GPU cache):** `Cache flush buffer fail` indicates a Mali/IOMMU
  coherency bug in the 6.6 kernel GPU driver. *Fix direction:* audit the
  Mali kbase (`kbase_mmu` / cache maintenance) against a known-good tree.
- **H4 (logging):** rate-limit or silence the noisy `wlan`/`CONN_BUS` messages.

## Fix proposal (ordered)

1. **Measure, don't guess:** capture `scaling_cur_freq` and `scaling_governor`
   for all cores *while a heavy task runs*, plus `psi` pressure. Confirm H2.
2. **Quantify GPU noise:** count `Cache flush buffer fail` per minute; correlate
   with `dumpsys gfxinfo` jank frames.
3. **Memory:** record per-process RSS (`dumpsys meminfo`) to find the hog.
4. Only then choose fixes; do not tune blindly.

## How other devices solved it

See `docs/references.md`. In particular, comparable MTK trees with a Mali
patchset backport and their LMKD tuning are the closest references.

## Verification plan

- Lag reproduced under a repeatable scenario (cold app switch, scroll).
- `scaling_cur_freq` rises under load (H2 disproved/fixed).
- `Cache flush buffer fail` count → 0 after the GPU fix.
- `dumpsys gfxinfo <app>` janky-frame % drops.
