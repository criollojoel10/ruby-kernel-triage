# ruby-kernel-triage

Diagnostics, kernel logs and stability triage for the **Xiaomi Redmi Note 12 Pro 5G**
(codename `ruby` / `rubyx`, MediaTek **MT6877V** / Dimensity 1080) running
**LineageOS 23.2** (Android 16, kernel **6.6.127**).

This repository collects **real, device-derived evidence** to find out *what*
breaks on this device, *why* it breaks, and *how* to fix it — with a bias toward
comparing against other MTK/MT6877 devices and custom ROMs that are already
stable.

> Status: initial setup. Raw logs are collected over SSH from the live device
> and stored under `logs/<YYYY-MM-DD>/`.

## Current known issues

| ID | Issue | Severity | Status |
|----|-------|----------|--------|
| ISSUE-001 | No fingerprint unlock option (PIN/pattern only) | High | Investigating |
| ISSUE-002 | General UI/system lag | Medium | Investigating |

See [`docs/issues/`](docs/issues/) for the per-issue write-ups (symptom → evidence → hypothesis → fix).

## Repository layout

```
.
├── README.md
├── scripts/
│   └── collect-logs.sh        # Pulls logs from a device over SSH (read-only)
├── logs/
│   └── YYYY-MM-DD/            # One directory per collection run
│       ├── metadata.md        # Device/ROM/build identity for that run
│       ├── dmesg.txt
│       ├── logcat-*.txt
│       ├── ...
├── docs/
│   ├── 01-device-profile.md   # Hardware + software ground truth
│   ├── 02-methodology.md      # How logs are collected and sanitized
│   ├── issues/                # One file per ISSUE-xxx
│   └── references.md          # Comparable devices / ROMs to learn from
└── .gitignore
```

## Method (short)

1. **Collect** — `scripts/collect-logs.sh` runs over SSH and dumps kernel and
   userspace logs to `logs/<date>/`. It is **read-only** on the device.
2. **Sanitize** — serial numbers, IMEI, MAC addresses and other identifiers are
   redacted before anything is committed.
3. **Document** — every finding becomes an `ISSUE-xxx` file with a clear
   symptom, the raw evidence that supports it, a hypothesis and a proposed fix.
4. **Compare** — for each issue we look at how other devices (see
   `docs/references.md`) solve the same class of problem.

## Safety rules

- **Read-only by default.** No partition writes, no `rm`, no reboots triggered
  by these scripts.
- This device is the owner's **daily driver**; treat it as production.
- Never commit secrets, serial numbers, IMEI or raw MACs.

## License

Documentation: CC BY 4.0. Scripts: MIT.
