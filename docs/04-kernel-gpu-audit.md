# 04 — Kernel / GPU performance audit

- Date: 2026-10-04 · **revised 2026-10-06** (§2 rewritten: rate and root-cause
  claims corrected — see the two correction notes in §2)
- Device: `ruby` (MT6877V), LineageOS 23.2, kernel `6.6.127-4k-ged71a8f07b9c-dirty`
- Evidence: `logs/2026-10-04/dmesg.txt` (one 91 s window, 29 971 lines)
- Legend: **[V]** verified in source/log/API · **[I]** inferred · **[?]** unknown

## TL;DR

1. **The `Cache flush buffer fail` storm is NOT the GPU.** The exact string comes
   from MediaTek's **video codec** driver, `drivers/media/platform/mtk-vcu/
   mtk_vcodec_mem.c` (formerly `mtk-vcodec`), on the `dma_buf` cache-flush path.
   **[V]** — see §2. Do **not** patch Mali for this.
1b. **It is a real driver bug, not background noise.** All 1 219 failures happen
   in a 37 s burst at **33/s**, bounded to the millisecond by one active **VP9**
   decode session, against **10 fixed VCU addresses that no buffer registered in
   the `vdec` queue covers** — none of them the picture buffer. Read at source
   level on 2026-10-06: `vcu_buffer_cache_sync()` skips the cache maintenance and
   `mtk_vcu_ioctl()` hands **`-EINVAL`** back to userspace. **[V]** — see §2.
2. The kernel log is **dominated by noise**, not by faults: `goodixFP` (18 483
   lines), touch `FTS_TS` (3 510), `wlan` (1 836), `CONN_BUS` (1 020),
   `haptic_hv` (1 366). Printing interrupts on the hot path is itself a latency
   and power cost. **[V]**
3. CPU frequency scaling **works** (governors `schedutil/performance/conservative/
   powersave` present; cores observed at 1.26 / 1.54 GHz and up to 2.0 GHz). The
   earlier "pinned at 900 MHz" reading was an **idle sample**, not a bug. **[V]**
4. Actionable items are mostly **tuning + log hygiene**, plus one codec fix (the
   VP9 cache flush — worth more than its 1 219 log lines, since a failing flush
   on every frame is a real per-frame cost during video playback).

## 1. Noise budget (one 91 s dmesg window) **[V]**

| Source | Lines | Note |
|--------|------:|------|
| `goodixFP` | 18 483 | fingerprint IRQ + netlink, fires per touch |
| `FTS_TS` | 3 510 | touchscreen report |
| `wlan` | 1 836 | TX/RX INFO logs |
| `haptic_hv` | 1 366 | vibrator |
| `Cache flush buffer fail` | 1 219 | **codec**, all inside 37 s of VP9 decode (§2) |
| `CONN_BUS_C` | 1 020 | connectivity bus debug |
| `update cpufreq limit` | 432 | cpufreq transitions |
| `Thermal` | 263 | thermal zones |
| `init:` | 180 | fingerprint HAL not found (ISSUE-001) |
| **total** | **29 971** | in 91 s → ~330 lines/s |

A driver that logs per interrupt is a real cost: console/serial writes take
locks and wake the writer. Most of these are `pr_info`/`pr_debug` that a
production kernel should not print by default.

## 2. The `Cache flush buffer fail` storm **[V]**

The trigger is **measured** (below): one VP9 decode session, 33/s, bounded to the
millisecond. The mechanism is now **read from the source** (below): the requested
range matches no buffer registered in the queue, so the flush is skipped and the
ioctl fails.

Exact source string, confirmed 2026-10-06 by reading
`MiCode/Xiaomi_Kernel_OpenSource` branch `ruby-s-oss` at
`drivers/media/platform/mtk-vcu/mtk_vcodec_mem.c:431` (and mirrored in
`xiaomi-mediatek-devs/android_kernel_xiaomi_mt6877`, branch
`experimental/mali/lineage-20`, and `OnePlusOSS/android_kernel_oneplus_mt6877`):

```
drivers/media/platform/mtk-vcu/mtk_vcodec_mem.c
    → vcu_buffer_cache_sync()   (containment test, :405)
    → pr_info("Cache flush buffer fail, iova = %lx, size = %d", ...)   (:431)
drivers/media/platform/mtk-vcu/mtk_vcu.c
    → mtk_vcu_ioctl(), case VCU_CACHE_FLUSH_BUFF   → returns -EINVAL (:1887)
```

Evidence in our log:

```
Cache flush buffer fail, iova = 1fc000000, size = 56448
Cache flush buffer fail, iova = 1f8800000, size = 8384
```

The string is **vendor-only**: `grep -rn 'flush buffer fail'` over an extracted
mainline `linux-6.6.127` (`~/.cache/ruby-kernel-6.6.127/full/linux-6.6.127`)
returns **0 hits**. Mainline reorganised the driver to
`drivers/media/platform/mediatek/vcodec/` (`common/` + `mtk_vcodec_*.c`) and has
no `mtk-vcu/`, so this bug cannot survive a tree switch on its own — it has to be
re-derived against the mainline vcodec core.

### Measured shape of the storm **[V]**

All 1 219 occurrences fall inside a **37.2 s** window, not the full 91 s log:

| Property | Value |
|---|---|
| First / last event | `51189.204764` / `51226.442743` (span **37.24 s**) |
| Rate inside the window | **32.7/s** (median inter-event gap 32 ms) |
| Rate averaged over 91 s | **1.4/min** |
| 5 s buckets | 165, 165, 165, 163, 165, 163, 164 — **flat**, no decay |
| Unique iovas | **10** |
| Sizes | 1 088–56 448 bytes (42–45 distinct values per iova) |

> **Correction:** earlier revisions of this document reported "~13/s". That figure
> divided 1 219 by the full 91 s window and mislabelled the result as a per-second
> rate. The real behaviour is **a 37 s burst at 33/s** superimposed on an otherwise
> quiet log — the same events are 1.4/min if you average the whole capture.

### The storm is *caused by* active VP9 decoding **[V]**

The burst is bounded to the millisecond by one decoder session:

```
51189.037752  fops_vcodec_open(),107: decoder capability 10
51189.104722  [VCU] mtk_vcu_open name: vdec_srv pid 1339 tgid 1269 open_cnt 2
51189.174491  vb2ops_vdec_buf_queue(),2271: [128] Init Vdec OK wxh=768x1280 pic wxh=720x1280
51189.179595  vb2ops_vdec_buf_queue(),2283: [128] bs VP90 fm M21S, num_planes 1, fb_sz[0] 1474560
51189.192626  [MTK_V4L2][ERROR] vidioc_vdec_s_fmt:1539: cap_q_ctx buffers already requested
51189.204764  Cache flush buffer fail, iova = 1fc000000, size = 56448   <-- first failure, 12 ms after the VP9 bitstream
   ... 1218 more, 165 per 5 s bucket, flat ...
51226.442743  Cache flush buffer fail, iova = 1f2c00000, size = 1152    <-- last failure
51226.467025  fops_vcodec_release(),138: [128] decoder
51226.470993  [VCU] mtk_vcu_release name: vdec_srv pid 1269 open_cnt 2
51226.472290  vcu_gce_clear_inst_id ctx 00000000eb53e1f0 not found!
```

Three controls make the causal link hard to argue with:

1. **It is the decode, not the open.** Between `51193.308` and `51193.545` the
   same decoder is opened and released five more times ([129]–[133],
   `VcodecProcess`). Each lives <0.3 s, none reaches `bs VP90` or `Init Vdec OK`,
   and **none produces a single flush failure**. Aborted opens are free; the
   flush only starts once VP9 frames are actually queued.
2. **It is the video decoder, not the audio DSP.** The identical
   `dma sz: 892` / `scp_send_msg_to_scp` traffic that runs *inside* the storm
   keeps running *after* it — `mtk_dsp_pcm_open` task_id 10 and 4 at `51231.129`
   and `51231.220`, 45 further DSP/SCP lines between `51226.47` and `51243.6` —
   with **zero** flush failures. Audio playback is neither necessary nor
   sufficient.
3. **The failing buffers are not the frame.** `fb_sz[0]` for this frame is
   1 474 560 bytes; every failing `size` is between 1 088 and 56 448. The flush is
   being attempted on the VCU's auxiliary/working buffer set, not on the picture.

### What the iovas actually are **[V]**

Not "arbitrary addresses" — **10 fixed addresses, none of them registered**. Read
at source level on 2026-10-06 against
`drivers/media/platform/mtk-vcu/mtk_vcodec_mem.c` (Xiaomi `ruby-s-oss` tree):

```c
/* vcu_buffer_cache_sync(), mtk_vcodec_mem.c:387 */
for (buffer = 0; buffer < num_buffers; buffer++) {
        vcu_buffer = &vcu_queue->bufs[buffer];
        if ((dma_addr + size) <= (vcu_buffer->iova + vcu_buffer->size) &&
            dma_addr >= vcu_buffer->iova) { ...sync...; return 0; }
}
pr_info("Cache %s buffer fail, iova = %lx, size = %d\n", ...);   /* :431 */
return -1;
```

A flush only succeeds if the whole requested range falls inside one buffer of the
queue. Every one of the 1 219 requests falls through that loop, so **the range is
outside every buffer this queue registered** — it belongs to a different VCU
region (the `pseudo_m4u-vpu-{code,data,vlm}` firmware pools seen in
`pstore-console-ramoops.txt`), not to a wrong stride inside the picture buffer.

And it is not silently ignored. The caller turns it into an error return:

```c
/* mtk_vcu_ioctl(), mtk_vcu.c:1870 — case VCU_CACHE_FLUSH_BUFF */
ret = vcu_buffer_cache_sync(dev, vcu_queue, mem_buff_data.iova, ...);
if (ret < 0)
        return -EINVAL;
```

So each line in the log is one **ioctl that failed with `-EINVAL`** and one cache
maintenance that did **not** happen. The severity therefore depends on whether
the CPU had dirty pages in those ranges — which the log cannot say (see §6).

Geometry of the 10 addresses (`0x1e7800000 … 0x1fc000000`, span **328 MB**):

```
0x1e7800000  0x1ef000000  0x1f2000000  0x1f2c00000  0x1f3c00000
0x1f4c00000  0x1f5c00000  0x1f6400000  0x1f8800000  0x1fc000000
```

The gaps are **irregular** (120/48/12/16/16/16/8/36/56 MB), not a fixed stride —
an earlier note in this file called it an "8 MB stride / ~80 MB pool"; that was
wrong and is retracted. All 127 distinct sizes are multiples of 64 B, from 1 088
to 56 448 B — descriptor/work-buffer sized, never frame sized. All ten addresses
sit above 32 GB, consistent with the `iommu_padding` path
(`mem_buff_data.iova |= 0x100000000UL`, `mtk_vcu.c:1880`).

Occurrence counts are near-uniform (132–139 each, with `0x1f3c00000` at 20
because the session ended mid-rotation), and the walk repeats in the **same
fixed order** every pass. A constant 165-per-5 s is a loop walking all 10
addresses and failing on every one, not a leak and not random.

### Revised root cause **[V]**

Not a wrong-stride flush of the picture buffer: **userspace (the MTK VCU client)
asks the `vdec` queue to flush ten addresses the queue never registered** — the
VP9 path's firmware/work-buffer regions. The kernel correctly refuses, prints,
and returns `-EINVAL`.

Still open as a lead: the `cap_q_ctx buffers already requested` error at
`51189.192626`, 12 ms before the first failure, leaving the capture queue
malformed — attractive because it is a **precondition** only this session hit.

Silencing the `pr_err` is **not** a fix. It hides 1 219 lines; the ioctl still
fails 33 times a second on every VP9 frame.

> **Correction to earlier triage, round 1:** ISSUE-002 attributed this to the
> Mali-G68 GPU/IOMMU. Wrong — it is the video codec. This document supersedes it.
>
> **Correction, round 2:** this document previously claimed *"the codec is not in
> use during idle, yet the flush keeps failing"*, implying a stale attachment.
> That is **false**: the flush fails precisely because the decoder is decoding.
> The stale-attachment hypothesis is discarded.

## 3. What is healthy **[V]**

- **cpufreq**: `scaling_available_governors = conservative powersave performance
  schedutil`; `scaling_available_frequencies` = 500 MHz … 2.0 GHz. Cores scale.
- **Thermals** (from `thermal.txt`): AP ~41 °C, CPU ~50 °C, PA ~52 °C — **no
  throttling** observed.
- **PMIC**: MT6359P present; MT6360 (chg/led/tcpc) present.

## 4. Improvement proposals

| # | Improvement | Detail | Applies to ruby | Risk | How to verify |
|---|-------------|--------|-----------------|------|---------------|
| K1 | **Fix the VP9 cache flush** | Root cause **[V]**: the VCU client flushes ten addresses the `vdec` queue never registered → `vcu_buffer_cache_sync()` misses, `mtk_vcu_ioctl()` returns `-EINVAL`, cache maintenance is skipped. Two ways out: (a) find the client-side bug (which region owns those addresses), or (b) make the mismatch observable instead of silent — log the queue's registered `[iova,iova+size)` list on a miss. Start from the `cap_q_ctx buffers already requested` error at `51189.192626` | High | Med | play a VP9 clip and count `Cache flush buffer fail` → 0 (currently 33/s) |
| K1b | Log hygiene for the same message | *Only after* K1: demote to `pr_debug_ratelimited` so a regression stays visible without 1 219 lines. **Hides the bug, does not fix it** | Med | Low | line count collapses while the rate metric stays non-zero |
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
  source; the reference tree used here is `MiCode/Xiaomi_Kernel_OpenSource`
  `ruby-s-oss` (Android 12 base; the device runs Android 16 — the log's message
  format is byte-identical, so the code path is the same). **[V]**

## 6. Open questions **[?]**

- Does the failing VP9 flush cause visible artifacts (tearing, corrupt frames),
  or is it a pure per-frame CPU cost? Needs a VP9 playback test with
  `dumpsys SurfaceFlinger --latency` to separate the two.
- Is `cap_q_ctx buffers already requested` the trigger, or merely a symptom of
  the same queue-setup bug? Needs a second capture that *does not* hit it and a
  VP9 play test that does.
- ~~Is the flush failing on buffers that are genuinely unmapped (so it is
  harmless-but-spurious) or on mapped buffers with a bad length (so it silently
  leaves stale cache contents, which *is* a correctness bug)?~~ **Answered
  [V]** 2026-10-06 at source level: neither — the range matches **no** registered
  buffer (`vcu_buffer_cache_sync()` misses its containment test), so the driver
  skips the flush and returns `-EINVAL` to userspace. The remaining question is
  only whether those pages are CPU-dirty; the log cannot say. Closing it needs
  either the MTK VCU client source (not published) or a kprobe on
  `vcu_buffer_cache_sync` dumping `vcu_queue->bufs` during a VP9 session.
- Real cause of the memory pressure: leak vs. too many cached apps? **Per-process
  RSS captured 2026-10-06** (`logs/2026-10-06/meminfo-procs.txt`, 354 processes).
  Answer: **no leak** — the largest holder is `com.whatsapp` at 333 MB PSS and the
  whole media stack stays under 115 MB (27 MB of it the codec path). The pressure is not in any process: CMA is
  **98.5 % consumed** (`CmaFree` 10 MB of 688 MB) and zram holds 380 MB physical
  for 1.2 GB of swap. See ISSUE-002 §3c.
