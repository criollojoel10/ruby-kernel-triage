# Issues index

One file per issue. Each follows the template in `docs/02-methodology.md`.

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| [ISSUE-001](ISSUE-001-fingerprint-unlock.md) | No fingerprint unlock option (PIN/pattern only) | High | Investigating — root cause identified |
| [ISSUE-002](ISSUE-002-system-lag.md) | General UI/system lag | Medium | Investigating — factors identified |

## Backlog (to turn into ISSUE-xxx files)

- `Cache flush buffer fail` storm — **not GPU/IOMMU**: during **VP9** decode the
  VCU client asks the `vdec` queue to flush 10 fixed addresses the queue never
  registered, 33/s for the length of each decode. Mechanism confirmed at source
  level 2026-10-06 (`vcu_buffer_cache_sync()` misses its containment test →
  `-EINVAL`); quantified in `docs/04-kernel-gpu-audit.md` §2, tracked as H3 in
  ISSUE-002. Promote to its own file once the remaining question is settled —
  whether those pages are CPU-dirty (correctness bug) or untouched (noise).
- `[CONN_BUS_C]ahb_apb_timeout` connectivity-bus timeouts.
- Wi-Fi `qmHandleRxPackets` / `mtk_cfg80211_get_station` warning noise.
- `binder space running out while frozen` process kills.
