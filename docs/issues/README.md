# Issues index

One file per issue. Each follows the template in `docs/02-methodology.md`.

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| [ISSUE-001](ISSUE-001-fingerprint-unlock.md) | No fingerprint unlock option (PIN/pattern only) | High | Investigating — root cause identified |
| [ISSUE-002](ISSUE-002-system-lag.md) | General UI/system lag | Medium | Investigating — factors identified |

## Backlog (to turn into ISSUE-xxx files)

- `Cache flush buffer fail` storm — **not GPU/IOMMU**: it is the VCU video codec
  failing a cache flush during **VP9** decode, 33/s for the length of each decode.
  Quantified in `docs/04-kernel-gpu-audit.md` §2; still tracked inside ISSUE-002
  (H3) pending a source-level review of `mtk_vcodec_mem.c`. Promote to its own
  file once the buffer-selection bug is pinned down.
- `[CONN_BUS_C]ahb_apb_timeout` connectivity-bus timeouts.
- Wi-Fi `qmHandleRxPackets` / `mtk_cfg80211_get_station` warning noise.
- `binder space running out while frozen` process kills.
