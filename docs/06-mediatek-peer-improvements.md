# 06 — MediaTek peer improvements (what other devices/ROMs do)

- Date: 2026-10-04
- Purpose: distil what comparable **MediaTek** kernels/ROMs do for performance,
  optimization, stability and battery, and what is applicable to `ruby`
  (MT6877V, kernel 6.6 downstream).
- Legend: **[V]** verified via repo/API · **[I]** inferred · **[?]** unknown

## Comparable projects (validated)

| Project | SoC | Kernel | Why it matters |
|---------|-----|--------|----------------|
| `MT6878-mainline/linux` [V] | MT6878 (D7300) | mainline 7.2 | Same generational block; clean drivers/DT |
| `mt6785-mainline/linux` [V] | MT6785 (begonia) | mainline 6.16.4 | pmOS-shipped MTK mainline |
| `vitoramaral10/pmos-xiaomi-thunder` [V] | MT6833 (D700) | vendor 4.19 | Downstream + GPU/Panfrost backport, connectivity |
| `xiaomi-mt6893-dev/kernel_xiaomi_mt6893` [V] | MT6893/6877 | vendor | agate/ares/choppin/pissarro shared tree |
| `Nxages/...postmarketos-server` [V] | MT6877 (pissarro) | downstream 4.14 | Real pmOS on this exact SoC |
| `OnePlusOSS/android_kernel_oneplus_mt6877` [V] | MT6877 | vendor | Same codec/GPU source to diff |

## Improvement matrix (what to do, where it comes from, applicability)

| # | Improvement | Peer source | Applies to ruby | Risk | Verify by |
|---|-------------|-------------|-----------------|------|-----------|
| M1 | Clean/limit MTK vendor log spam (`CONN_BUS`, `wlan`, codec) | MT6878-mainline style | **High** | Low | dmesg line rate |
| M2 | Fix VP9 `dma_buf` flush path (`mtk_vcodec_mem.c`) | OnePlus mt6877 / upstream mtk-vcodec | **High** | Med | `Cache flush buffer fail` = 0 during VP9 playback |
| M3 | zram/LMKD tuning for 7.5 GiB | pmos-thunder, Lineage defaults | **High** | Med | PSI, no binder kills |
| M4 | GPU: Mali kbase backport vs Panfrost | pmos-thunder (Panfrost), MT6878 (mainline) | Med | Med | `dumpsys gfxinfo`, glmark |
| M5 | cpuidle / EAS / PELT tuning | mt6785-mainline, MT6878 | Med | Med | idle power, jank |
| M6 | Thermal / DVFSRC governor tuning | MTK vendor trees | Med | Med | temp + sustained perf |
| M7 | UFS I/O scheduler + read_ahead | general | Med | Low | fio, app launch |
| M8 | Battery: doze/powerhint/suspend tuning | Lineage defaults | Med | Med | idle drain (mAh/h) |
| M9 | Wi-Fi `gen4m` stack robustness | pmos-thunder bring-up | Med | High | reconnect tests |

## Detail on the most valuable items

### M1 — Log hygiene **[V]**
Our 91 s dmesg window had 29 971 lines (~330/s), dominated by per-interrupt
prints (`goodixFP` 18 483, `FTS_TS` 3 510, `wlan` 1 836, `haptic_hv` 1 366).
Production kernels demote these to `*_ratelimited`/debug. Peer trees that are
"quiet" by default (mainline-style) are the model.

### M2 — Codec flush fix **[V]** trigger · **[I]** fix
The `Cache flush buffer fail` string is from `mtk_vcodec_mem.c`, on the VP9 decode
path: all 1 219 occurrences in the 2026-10-04 capture fall in a 37 s burst at
33/s bounded to the millisecond by one `fops_vcodec_open`/`release` pair, over 10
fixed 8 MB-strided VCU buffers that are not the picture buffer. The fix is in the
buffer/stride selection for VP9, not in the log level and not in an
"unmapped attachment" guard — that hypothesis was disproved. Upstream `mtk-vcodec`
is the reference. **Not a GPU bug.** See `docs/04-kernel-gpu-audit.md` §2.

### M3 — Memory tuning **[V]**
`MemFree` ~300 MB, swap ~72% used, and `am_kill: binder space running out while
frozen`. Peers with 6–8 GiB LPDDR4X tune zram size + compressor and LMKD
thresholds. Cheap, safe, high-impact.

### M4 — GPU strategy **[I]**
Two paths, both validated in peers:
- **Keep vendor Mali kbase** (what Lineage does now) and improve it.
- **Panfrost** (what pmos-thunder backports) — cleaner but a large effort on
  Valhall G68 MC4; risk of feature gaps.

For a *daily-driver* Lineage ROM, staying on Mali kbase and fixing surrounding
issues is the pragmatic choice.

## What peers explicitly do NOT do

- They do **not** patch Mali for the codec flush (different subsystem).
- They do **not** run the display stack on simplefb once DRM works (ruby mainline
  is still partial on one panel).

## Applicability summary

- **Do now (low risk, high value):** M1, M2, M3, M7.
- **Do next (medium):** M5, M6, M8.
- **Big bets (plan carefully):** M4 (Panfrost), M9 (Wi-Fi robustness).

## Open questions **[?]**

- Exact quantitative gain of each item on ruby (needs A/B on device).
- Whether the codec flush failure has user-visible consequences or is mostly
  cost in log volume.
