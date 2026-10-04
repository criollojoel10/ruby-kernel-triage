# Issues index

One file per issue. Each follows the template in `docs/02-methodology.md`.

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| [ISSUE-001](ISSUE-001-fingerprint-unlock.md) | No fingerprint unlock option (PIN/pattern only) | High | Investigating — root cause identified |
| [ISSUE-002](ISSUE-002-system-lag.md) | General UI/system lag | Medium | Investigating — factors identified |

## Backlog (to turn into ISSUE-xxx files)

- `Cache flush buffer fail` storm (GPU/IOMMU) — extracted from ISSUE-002, may
  deserve its own file once quantified.
- `[CONN_BUS_C]ahb_apb_timeout` connectivity-bus timeouts.
- Wi-Fi `qmHandleRxPackets` / `mtk_cfg80211_get_station` warning noise.
- `binder space running out while frozen` process kills.
