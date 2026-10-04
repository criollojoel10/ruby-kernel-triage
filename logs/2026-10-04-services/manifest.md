# Service sweep — 2026-10-04

Live sweep of init services, HALs and power/GNSS state on `ruby`.

| File | Content |
|------|---------|
| `svc-init.txt` | All `init.svc.*` properties (263 entries) |
| `lshal.txt` | All registered HALs (79 entries) |
| `gnss.txt` | GNSS/GPS/AGPS properties |
| `live-sweep.txt` | Power/HAL/GNSS/power_supply live dump |

## Highlights

- **94 services running, 38 stopped** (mostly expected one-shots).
- **GNSS HAL present** (`android.hardware.gnss@2.1`), `agpsd` + `vendor.gnss-default` running.
- **`vendor.mediatek.hardware.mtkpower@1.2` is declared in the device tree
  (`configs/vintf/manifest.xml`) but NOT available on the device** (only 1.0/1.1
  register). VINTF inconsistency — see `docs/08-services-audit.md`.
- At capture time the device was **not plugged in** (`usb online=0`, `ac online=0`,
  `Not charging`), so charging could not be measured live.
