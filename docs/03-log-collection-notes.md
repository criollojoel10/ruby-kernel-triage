# Log collection notes

Operational notes and gotchas found while collecting from the live device.

## Quirks fixed in `scripts/collect-logs.sh`

1. **`/proc/cmdline` needs root.** Even with the Termux shell, `cat
   /proc/cmdline` returns `Permission denied`. Read it via `su -c` and route it
   through `su_run` instead of `run`.
2. **Remote grep quoting.** The error logcat step was written as
   `logcat -d | grep -iE ' E |error|...'`; over SSH the `|` and spaces were
   consumed by the remote shell, producing `error: command not found`. Fix:
   wrap the whole remote command and escape/quote the pattern correctly, or use
   a `grep -f` pattern file shipped to the device.

## Redaction

Before committing, the following were found in raw logs and **redacted**:

| Kind | Location | Replacement |
|------|----------|-------------|
| IMEI (slot 1/2) | `props-all.txt` | `REDACTED_IMEI` |
| Wi-Fi MAC | `dmesg.txt` | `AA:BB:CC:DD:EE:01` |
| BT MAC | `props-all.txt` | `AA:BB:CC:DD:EE:02/03` |

Re-run this scan before every push:

```sh
grep -rhoiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' logs/ | sort -u
grep -rhiE 'imei|serialno' logs/ | sort -u
```

## Privacy rule

This repo is **public**. Any run that contains a device identifier must be
redacted *before* the commit. When in doubt, redact.
