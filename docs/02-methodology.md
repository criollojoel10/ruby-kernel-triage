# Methodology — how logs are collected and documented

## Principle

**Evidence first.** Every claim in `docs/issues/` must point at a raw log or a
reproducible command. Hypotheses are clearly separated from facts.

## Collection

Logs are pulled from the live device over SSH by `scripts/collect-logs.sh`,
which is **read-only**:

- No writes, no partition operations, no reboots triggered by the script.
- Root (KernelSU) is used only to read `dmesg`, full `logcat` and
  `/proc` counters that an unprivileged shell cannot see.
- Each run lands in `logs/<YYYY-MM-DD>/` with a `manifest.md` describing what
  was captured.

### What is captured

| Group | Files | Purpose |
|-------|-------|---------|
| Identity | `metadata`, `kernel`, `cmdline`, `props-all` | Exact build/hardware context |
| Kernel | `dmesg`, `dmesg-warn`, `modules`, `interrupts`, `softirqs` | Driver errors, IRQ storms |
| Load | `loadavg`, `cpuinfo`, `meminfo`, `thermal`, `cpufreq` | Lag / scheduling / thermal |
| Fingerprint | `fp-services`, `fp-list`, `fp-hal`, `fp-vendor` | Biometric HAL state |
| Userspace | `logcat-main`, `logcat-system`, `logcat-crash`, `logcat-errors` | Framework crashes |
| Power | `dumpsys-battery` | Battery/thermal baseline |

### Known collection quirks (to fix)

- **`cmdline`**: `/proc/cmdline` is `Permission denied` even via the Termux
  shell — read it with `su -c 'cat /proc/cmdline'` instead.
- **`logcat-errors`**: the grep pattern was interpreted by the remote shell
  (the `|` and spaces broke quoting). Re-quote the remote command properly.

## Sanitization rules

Before anything is committed, remove:

- Device serial numbers, IMEI/MEID, phone numbers.
- Wi-Fi/BT MAC addresses.
- Any account, token or personal identifier.
- Location data.

`logcat` and `dmesg` are scanned for these patterns. Build fingerprints and
kernel releases are kept (they are public build identifiers, not personal).

## Documenting an issue

Each issue file follows the same template:

```
# ISSUE-XXX — <short title>

- Severity / Status
- Symptom (what the user sees)
- Evidence (raw log excerpts + log path)
- Analysis (what the evidence means)
- Root cause / hypothesis (marked)
- Fix proposal
- How other devices solved it (references)
- Verification plan
```

Keep one issue per file so it can be linked from a bug report.
