# ISSUE-002 — General UI/system lag

- **Severity:** Medium
- **Status:** Investigating — memory hypothesis open; codec-flush trigger
  identified, root cause still needs source review
- **Collected:** 2026-10-04, `logs/2026-10-04/`
- **Related files:** `loadavg.txt`, `cpufreq.txt`, `meminfo.txt`,
  `dmesg.txt`, `logcat-events.txt`, `thermal.txt`,
  `dumpsys-meminfo.txt` *(empty — collector bug, see Fix step 3)*
- **Revised:** 2026-10-06 — §3b and H3 rewritten; two earlier claims withdrawn
  (the "~13/s" rate and the "codec idle / stale attachment" hypothesis). Fix
  step 3 unblocked by a `collect-logs.sh` fix (unverified: device offline).

## Symptom

The system feels laggy: stutters in the UI, slow app switching, occasional
jank. Not constant, but frequent enough to notice.

## Evidence

### 1. Memory pressure is high

`meminfo.txt` (2026-10-04):

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

`dumpsys meminfo` agrees and names the cost: `status moderate`, `Lost RAM
693 110K`, `ZRAM: 379 968K physical used for 1 216 644K in swap`.

### 1b. Where the RAM went — *no leak; it is CMA* **[V]**

`logs/2026-10-06/meminfo-procs.txt`, **354 processes** with `VmRSS` and PSS straight
from `/proc` (root capture, `scripts/collect-logs.sh` source `meminfo-procs`):

| pid | process | VmRSS | PSS |
|-----|---------|-------|-----|
| 1792 | `system_server` | 654 MB | **326 MB** |
| 16553 | `com.whatsapp` | 645 MB | 333 MB |
| 9322 | `gle.android.gms` | 380 MB | 212 MB |
| 2665 | `systemui` | 370 MB | 154 MB |
| 1250 | `camerahalserver` | 103 MB | 85 MB |
| 1220 | `mediaserver64` | 28 MB | 7.4 MB |
| 1916 | `c2@1.2-mediatek` | 17 MB | 7.8 MB |
| 975 | `composer@2.3-se` | 15 MB | 6.1 MB |
| 1216 | `mediaextractor` | 18 MB | 3.4 MB |
| 1272 | `vpud` | 3.7 MB | 2.0 MB |

**There is no runaway process.** The largest PSS is 333 MB (a chat app) and
326 MB (`system_server`); the **video-codec** processes of §3b — `vpud`,
`mediaserver64`, `c2@1.2-mediatek`, `composer@2.3-se`, `mediaextractor` — total
**~27 MB PSS**. Even adding `camerahalserver` (85 MB, the camera pipeline, a
different suspect) the whole media stack is ~112 MB, and its largest single line
is the camera HAL, not the codec. So H1's "a vendor daemon is leaking" is
**disproved**.

Summing all 354 processes gives 2.93 GiB of PSS and 14.20 GiB of summed `VmRSS`
(shared pages counted once per process, which is why RSS exceeds the 7.5 GiB of
physical RAM and why PSS is the column to read). Nothing there is anomalous for
Android 16 with this many cached apps.

The RAM is not in a process at all. `/proc/meminfo` on the same boot:

```
CmaTotal:         704512 kB
CmaFree:           10424 kB     ← 98.5% consumed
Mlocked:          493788 kB
Slab:             437108 kB     (SUnreclaim 286464 kB)
```

**CMA — the pool contiguous carve-outs must come from — is drained to 1.5%.**
That single line explains what `dumpsys meminfo` reports as `Lost RAM` (693 MB),
and it is a far better lag candidate than any app: when camera, video encode,
display or the VCU ask for a contiguous block and CMA is empty, the allocation
stalls or falls back to a non-contiguous path. `Mlocked` 494 MB on top means much
of what is left is pinned and unreclaimable.

### 2. CPU reported at the minimum frequency — *disproved, see H2*

`cpufreq.txt` shows every core at its lowest OPP, with no governor listed:

```
--- /sys/devices/system/cpu/cpu0/cpufreq/      900000
--- /sys/devices/system/cpu/cpu7/cpufreq/      910000
```

At capture time that read as "all cores stuck at 900 MHz". Two readings were
possible and needed disambiguating: an idle sample, or a governor that never
scales. **The second is disproved** — governors `schedutil/performance/
conservative/powersave` are present and cores were observed at 1.26/1.54 GHz and
up to 2.0 GHz. Kept here because it is the reading that produced the wrong
hypothesis, and the `cpufreq.txt` file still shows only the idle state.

### 3. The kernel log is flooded

`dmesg.txt` (2.1 MB in a single boot) is dominated by hot-path debug logging:

| Count | Message |
|-------|---------|
| 1 219 | `Cache flush buffer fail, iova = ...` (video codec, **not** GPU — see below) |
| 51+ | `[CONN_BUS_C]ahb_apb_timeout:[...]` (connectivity bus) |
| 39 | `[wlan] qmHandleRxPackets:(RX WARN) ... non-interesting type` |
| 30 | `[wlan] mtk_cfg80211_get_station:(REQ WARN) last Rx link speed` |

A `dmesg` this noisy on the serial console / log path is itself a source of
latency (logging on the critical path) and hides real errors.

### 3b. The codec flush is a 37-second burst caused by one VP9 decode **[V]**

The 1 219 `Cache flush buffer fail` lines are **not** spread across the capture.
Every one falls between `51189.204764` and `51226.442743` — a **37.2 s** window
at **32.7/s** (165 per 5 s bucket, flat). Over the full 91 s log that averages
1.4/min. *(An earlier revision of this issue quoted "~13/s"; that was 1 219 ÷ 91 s
mislabelled as a per-second rate.)*

The window is bounded to the millisecond by one decoder session:

```
51189.104722  mtk_vcu_open name: vdec_srv ... open_cnt 2
51189.179595  vb2ops_vdec_buf_queue: [128] bs VP90 fm M21S, fb_sz[0] 1474560
51189.192626  [MTK_V4L2][ERROR] vidioc_vdec_s_fmt: cap_q_ctx buffers already requested
51189.204764  Cache flush buffer fail ...   <-- 12 ms after the VP9 bitstream
...1218 more at 33/s, flat...
51226.442743  Cache flush buffer fail ...
51226.467025  fops_vcodec_release(),138: [128] decoder
51226.470993  mtk_vcu_release name: vdec_srv ... open_cnt 2
51226.472290  vcu_gce_clear_inst_id ctx ... not found!
```

Three controls pin this down:

- **Decode, not open.** Five more opens/releases of the same decoder at
  `51193.308`–`51193.545` ([129]–[133]) abort in <0.3 s without reaching
  `bs VP90`, and produce **zero** failures. VP9 frames must actually be queued.
- **Video, not audio.** The `scp_send_msg_to_scp` / `mtk_dsp_pcm_*` traffic that
  interleaves with the storm keeps running after it — 45 further DSP/SCP lines
  and two full `mtk_dsp_pcm_open` + `hw_prepare` + `hw_trigger` cycles
  (`51231.129`, `51231.220`) with **zero** failures. Audio playback is neither
  necessary nor sufficient.
- **The failing buffers are not the picture.** `fb_sz[0]` is 1 474 560 bytes; every
  failing `size` is 1 088–56 448, all multiples of 64 B. The iovas are **10 fixed
  addresses**, `0x1e7800000 … 0x1fc000000` (span 328 MB), walked in the same
  fixed order every pass.
- **Read at source level on 2026-10-06** (`MiCode/Xiaomi_Kernel_OpenSource`
  `ruby-s-oss`, `drivers/media/platform/mtk-vcu/mtk_vcodec_mem.c:387`): a flush
  succeeds only if the requested range lies wholly inside one buffer the queue
  registered, and **none of these ten does**. The driver skips the cache
  maintenance and `mtk_vcu_ioctl()` returns `-EINVAL` (`mtk_vcu.c:1887`). These are
  firmware/work-buffer regions (`pseudo_m4u-vpu-{code,data,vlm}`, visible in
  `pstore-console-ramoops.txt`), not the picture. *(Retracting the earlier
  "fixed 8 MB stride / ~80 MB pool" reading in this bullet: the gaps between the
  ten addresses are irregular — 120/48/12/16/16/16/8/36/56 MB.)*

So this is **the VCU client asking the decode queue to flush ranges it never
registered**, 33 times a second, for the whole VP9 decode. Not background noise.

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

This is **not one bug** — it is three stacked effects:

1. **RAM starvation / swap thrash.** With ~300 MB free and heavy zram/swap use,
   any foreground work competes with page reclaim. **No single process is
   responsible** (§1b) — but **CMA is 98.5% consumed**, so contiguous carve-outs
   are the scarce resource, not process RSS. *Open; leak disproved, CMA open.*
2. **A failing VCU cache flush during video playback.** Real, per-frame cost —
   see §3b. *Trigger and mechanism identified: the client flushes ranges the
   queue never registered; kernel skips maintenance and returns `-EINVAL`.*
   Open: whether those pages are CPU-dirty (stale data reaching the VPU) or not.
3. **Log flooding on the kernel path.** `goodixFP` (18 483 lines), `FTS_TS`
   (3 510), `wlan` (1 836), `CONN_BUS` (1 020) and `haptic_hv` (1 366) print on
   hot paths; `ahb_apb_timeout` adds 85 in the same window. Logging on the
   critical path costs latency and power, and obscures real faults.

~~CPU frequency suspicion~~ — **disproved**, see H2. CPU scaling works; the
900 MHz reading was an idle sample. Dropped from the stacked-effects list.

Effect 2 deserves emphasis on cost. 1 219 log writes are real overhead, but each
one is also a **failed `ioctl` on the video path**: 33 of them per second for the
whole VP9 decode, whether or not anyone reads the log.

## Root cause / hypothesis

- **H1 (memory):** ~~too many cached/frozen apps for 7.5 GiB, or a leaking vendor
  daemon.~~ **Partly disproved [V]:** 354 processes captured; nothing leaks
  (largest PSS 333 MB) and the codec stack is under 30 MB. What *is* wrong is
  **CMA at 1.5% free** (§1b) plus zram at 380 MB physical / 1.2 GB swap, with
  `Mlocked` 494 MB. *Fix direction:* CMA reservation accounting and LMKD tuning,
  **not** hunting a leak.
- **H2 (cpufreq):** ~~the governor may be missing/misconfigured.~~ **Disproved
  [V]:** governors `schedutil/performance/conservative/powersave` are present and
  cores observed scaling to 1.26/1.54 GHz and up to 2.0 GHz. The earlier
  "900 MHz" reading was an idle sample. Remaining work is *tuning* schedutil,
  not fixing a stuck clock.
- **H3 (codec cache flush):** **identified at source level [V].** During **VP9**
  decode the VCU client issues `VCU_CACHE_FLUSH_BUFF` for 10 fixed addresses that
  **no buffer in the `vdec` queue covers** (33/s, 1 219 events per session).
  `vcu_buffer_cache_sync()` finds no match, skips the cache maintenance, prints,
  and `mtk_vcu_ioctl()` returns **`-EINVAL`**. So the flush does not happen *and*
  userspace learns it failed. The 10 addresses match the VPU firmware/work-buffer
  regions (`pseudo_m4u-vpu-{code,data,vlm}`).
  *Severity hinges on one fact the log cannot give:* whether the CPU had dirty
  pages there. Dirty → the VPU reads stale data (**silent corruption**, the worse
  outcome). Clean → the flush was never needed and this is log noise plus 33
  failed ioctls/s. *Fix:* make the mismatch observable (log the queue's registered
  `[iova, iova+size)` list on a miss) so the client bug becomes locatable;
  demoting the message alone hides 1 219 lines without fixing anything. See §3b
  and `docs/04` K1/K1b.
- **H4 (logging):** rate-limit or silence the noisy `wlan`/`CONN_BUS`/`goodixFP`
  messages (29 971 dmesg lines in 91 s).

## Fix proposal (ordered)

1. **Measure, don't guess:** ~~capture `scaling_cur_freq` ...~~ **done** — CPU
   scaling works (H2 disproved).
2. **Quantify codec noise:** ~~count per minute ...~~ **done** — 33/s during VP9
   decode, 0 otherwise, bounded by `fops_vcodec_open`/`release`. See §3b.
3. **Memory:** ~~record per-process RSS to find the hog.~~ **done 2026-10-06**
   (`logs/2026-10-06/meminfo-procs.txt`, 354 processes): **no hog exists.** Largest
   PSS is `com.whatsapp` at 333 MB, then `system_server` 326 MB; the whole codec
   path is 27 MB PSS. The scarce resource is **CMA** (10 MB free of 688 MB)
   and zram (1.2 GB swapped), not process RSS. Two collector bugs had emptied the
   2026-10-04 evidence and are fixed: bare `dumpsys` is not on a Termux sshd
   `PATH` (it died with "command not found", hidden by `2>/dev/null`), and
   `dumpsys <service>` needs **root**, not the absolute path alone — unprivileged
   it answers "Can't find service: <name>". `run`/`su_run` now also append
   `# WARNING: empty capture`, so a silent failure cannot pass for a clean result.
4. **Source-level H3:** ~~read `mtk_vcodec_mem.c` and decide unmapped vs.
   bad-length.~~ **done 2026-10-06.** Answer: **neither.** The range matches *no*
   registered buffer, so `vcu_buffer_cache_sync()` skips the maintenance and
   `mtk_vcu_ioctl()` returns `-EINVAL`. Remaining question, and the only one that
   decides severity: were those pages CPU-dirty? Needs a kprobe on
   `vcu_buffer_cache_sync` dumping `vcu_queue->bufs` during a VP9 session (or the
   unpublished MTK VCU client source). See §3b.
5. **CMA accounting (new, from step 3):** find who holds the 678 MB of CMA —
   `dumpsys meminfo` shows `DMA-BUF 180 MB / GPU 154 MB dmabuf`, so most of it is
   long-lived carve-outs (display, camera, ION/dmabuf heaps), not one hog.
   Read `/proc/iomem` + the DT `reserved-memory`/`linux,cma` nodes in the device
   tree and check each consumer's release path.
6. Only then choose fixes; do not tune blindly.

## How other devices solved it

See `docs/references.md`. In particular, comparable MTK trees with a Mali
patchset backport and their LMKD tuning are the closest references.

## Verification plan

- Lag reproduced under a repeatable scenario (cold app switch, scroll).
- `scaling_cur_freq` rises under load (H2 disproved/fixed).
- Play a VP9 clip for >60 s and count `Cache flush buffer fail` → 0. Baseline is
  ~33/s for the duration of the decode, so this metric is meaningful only while
  the clip is playing. **Not** a GPU fix.
- `dumpsys gfxinfo <app>` janky-frame % drops.
- Per-process RSS captured — **done**, and it cleared the leak hypothesis (step 3).
  Replacement metric for the memory work: **`CmaFree` during a camera/video
  workload**, which is the resource actually running out.
- kprobe on `vcu_buffer_cache_sync` during a VP9 session dumps `vcu_queue->bufs`
  and the requested range, proving whether the failed ranges are CPU-dirty
  (correctness bug) or not (noise). This is the single check that sets H3's
  severity.
