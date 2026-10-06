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
  failing `size` is 1 088–56 448. The iovas are **10 fixed addresses** on a
  **0x800000 (8 MB) stride**, `0x1e7800000 … 0x1fc000000`, walked in the same
  fixed order every pass — an ~80 MB VCU working-buffer pool, not the frame.

So this is a **wrong-buffer cache flush in the VP9 decode path**, not background
noise and not a stale attachment from an idle codec.

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
   any foreground work competes with page reclaim. *Open.*
2. **A failing VCU cache flush during video playback.** Real, per-frame cost —
   see §3b. *Open; trigger identified, buffer selection not yet.*
3. **Log flooding on the kernel path.** `goodixFP` (18 483 lines), `FTS_TS`
   (3 510), `wlan` (1 836), `CONN_BUS` (1 020) and `haptic_hv` (1 366) print on
   hot paths; `ahb_apb_timeout` adds 85 in the same window. Logging on the
   critical path costs latency and power, and obscures real faults.

~~CPU frequency suspicion~~ — **disproved**, see H2. CPU scaling works; the
900 MHz reading was an idle sample. Dropped from the stacked-effects list.

Effect 2 deserves emphasis on cost. 1 219 `pr_err` writes on the serial console is
real overhead, but the underlying `dma_buf` cache-maintenance call is failing 33
times a second for the entire duration of every VP9 decode — that cost is paid on
the video path whether or not anyone reads the log.

## Root cause / hypothesis

- **H1 (memory):** too many cached/frozen apps for 7.5 GiB → swap thrash and
  `binder space running out` kills. *Fix direction:* tune LMKD/frozen-process
  limits, reduce `MAX_CACHED_PROCESSES`, or check for a memory leak in a vendor
  daemon.
- **H2 (cpufreq):** ~~the governor may be missing/misconfigured.~~ **Disproved
  [V]:** governors `schedutil/performance/conservative/powersave` are present and
  cores observed scaling to 1.26/1.54 GHz and up to 2.0 GHz. The earlier
  "900 MHz" reading was an idle sample. Remaining work is *tuning* schedutil,
  not fixing a stuck clock.
- **H3 (codec cache flush):** `Cache flush buffer fail` is the **video codec**
  (`mtk_vcodec_mem.c`) failing a `dma_buf` cache flush on the VCU's auxiliary
  buffers during **VP9** decode — 33/s for the whole decode, 1 219 events per
  video session. *Fix:* correct the buffer/stride selection in the VP9 path, not
  the log level. Demoting `pr_err` alone is log hygiene, not a fix. See §3b and
  `docs/04` K1/K1b.
- **H4 (logging):** rate-limit or silence the noisy `wlan`/`CONN_BUS`/`goodixFP`
  messages (29 971 dmesg lines in 91 s).

## Fix proposal (ordered)

1. **Measure, don't guess:** ~~capture `scaling_cur_freq` ...~~ **done** — CPU
   scaling works (H2 disproved).
2. **Quantify codec noise:** ~~count per minute ...~~ **done** — 33/s during VP9
   decode, 0 otherwise, bounded by `fops_vcodec_open`/`release`. The trigger is
   known; what remains is *which* buffer selection is wrong (H3). See §3b.
3. **Memory:** record per-process RSS (`dumpsys meminfo`) to find the hog.
   **Blocked — collector bug found and fixed, needs a re-collection.**
   `logs/2026-10-04/dumpsys-meminfo.txt` is empty. Two independent causes, both
   in `scripts/collect-logs.sh`:
   - `/system/bin` is not on the PATH of a Termux sshd session, so the bare
     `dumpsys` call failed with "command not found", swallowed by `2>/dev/null`;
   - even with a working `dumpsys`, `| head -n 120` truncated the report exactly
     before the per-process RSS breakdown.

   The same two bugs emptied `dumpsys-cpuinfo.txt` and `dumpsys-battery.txt`, and
   `interrupts.txt` / `softirqs.txt` captured `Permission denied` because
   `/proc/interrupts` and `/proc/softirqs` are root-only but were collected
   unprivileged. Fixed: absolute `/system/bin/dumpsys` paths, `head` removed,
   and the four root-only sources moved to `su_run`. The collector now also
   appends `# WARNING: empty capture` when a source returns nothing, so a silent
   failure cannot be mistaken for a clean result again.
   **Not yet verified — `note12` has been unreachable since 2026-10-01.**
4. **Source-level H3:** read `mtk_vcodec_mem.c` and decide whether the failed
   flush is on unmapped buffers (spurious) or on mapped buffers with a bad length
   (silent cache corruption — a correctness bug, higher severity). The log cannot
   distinguish these.
5. Only then choose fixes; do not tune blindly.

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
- Per-process RSS captured for the memory hypothesis (currently blocked on
  re-collection, see step 3).
