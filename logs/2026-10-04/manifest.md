# Collection manifest

- host: note12
- date (UTC): 2026-10-04T05:54:54Z
- files:
  - cmdline.txt (113 bytes)
  - cpufreq.txt (594 bytes)
  - dmesg-warn.txt (584 bytes)
  - dmesg.txt (2150189 bytes)
  - dumpsys-battery.txt (85 bytes)
  - dumpsys-cpuinfo.txt (85 bytes)
  - dumpsys-meminfo.txt (99 bytes)
  - fp-hal.txt (988 bytes)
  - fp-list.txt (216 bytes)
  - fp-services.txt (103 bytes)
  - fp-vendor.txt (557 bytes)
  - interrupts.txt (119 bytes)
  - kernel.txt (231 bytes)
  - loadavg.txt (184 bytes)
  - logcat-crash.txt (14772 bytes)
  - logcat-errors.txt (469 bytes)
  - logcat-events.txt (881761 bytes)
  - logcat-main.txt (4618209 bytes)
  - logcat-system.txt (12602644 bytes)
  - meminfo.txt (1337 bytes)
  - metadata.txt (6199 bytes)
  - modules.txt (94 bytes)
  - props-all.txt (45882 bytes)
  - pstore.txt (91 bytes)
  - softirqs.txt (115 bytes)
  - thermal.txt (1427 bytes)

## Known gaps in this capture

Seven files are header-only or contain only an error. Do **not** read them as
"nothing to report" — the collector failed, not the device.

| File | Size | Cause |
|---|---|---|
| `dumpsys-meminfo.txt` | 99 B | `/system/bin` not on the Termux sshd `PATH`, so bare `dumpsys` failed with "command not found"; `2>/dev/null` hid it. Also truncated by `head -n 120`, before the per-process RSS block. |
| `dumpsys-cpuinfo.txt` | 85 B | same `PATH` problem |
| `dumpsys-battery.txt` | 85 B | same `PATH` problem |
| `interrupts.txt` | 119 B | `cat: /proc/interrupts: Permission denied` — root-only source collected unprivileged |
| `softirqs.txt` | 115 B | `cat: /proc/softirqs: Permission denied` — same |
| `modules.txt` | 94 B | `/proc/modules` unreadable without root |
| `pstore.txt` | 91 B | `/sys/fs/pstore` unreadable without root |

Fixed in `scripts/collect-logs.sh` on 2026-10-06 (absolute `dumpsys` path,
`head` removed, four sources moved to `su_run`, plus an `# WARNING: empty
capture` marker). **The fix is unverified — `note12` has been unreachable since
2026-10-01.** Blocker for ISSUE-002 step 3 (per-process RSS).
