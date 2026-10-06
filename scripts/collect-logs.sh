#!/usr/bin/env bash
# collect-logs.sh — Pull diagnostics from a `ruby` device over SSH.
#
# Read-only on the device. Never writes, never reboots, never touches
# partitions. Output goes to logs/<UTC date>/ on this machine.
#
# Usage:
#   scripts/collect-logs.sh                 # uses SSH host alias "note12"
#   SSH_HOST=myhost scripts/collect-logs.sh
#
# Requirements on the device: sshd (Termux or adb-over-tcp). Root is optional
# but unlocks dmesg/full logcat; without it we still capture what is readable.
#
# Two device-side gotchas this script works around, both learned from the
# 2026-10-04 capture that silently produced empty files:
#   1. `/system/bin` is NOT on the PATH of a Termux sshd session, so bare
#      `dumpsys` fails with rc=127 "command not found" and captures nothing.
#      Always use the absolute path.
#   2. `dumpsys <service>` needs ROOT, not just the absolute path: run
#      unprivileged it answers "Can't find service: <name>" even for services
#      that exist, because the ServiceManager lookup is permission-gated.
#      Verified 2026-10-06: `/system/bin/dumpsys meminfo` unprivileged ->
#      "Can't find service: meminfo"; via su_run -> real report.
#   3. /proc/interrupts, /proc/softirqs, /proc/modules and /sys/fs/pstore are
#      root-only on Android; an unprivileged read returns "Permission denied".

set -uo pipefail

SSH_HOST="${SSH_HOST:-note12}"
SSH_OPTS=(-o ConnectTimeout=12 -o BatchMode=yes)
# Extra ssh flags, word-split on purpose. Needed because the hole punch from
# begonia to the phone is unreliable: on 2026-10-06 begonia reported
# `MappingVariesByDestIP: true` and every probe to 100.120.64.12:8022 timed out,
# while rpi3b reached the same address directly in 40 ms. Route through it:
#   SSH_EXTRA_OPTS="-J rpi3b" ./scripts/collect-logs.sh
[ -n "${SSH_EXTRA_OPTS:-}" ] && SSH_OPTS+=($SSH_EXTRA_OPTS)
STAMP="$(date +%Y-%m-%d)"
OUT="logs/${STAMP}"

mkdir -p "$OUT"

log() { printf '%s\n' "== $*" >&2; }

# ONLY="meminfo-procs dumpsys-meminfo" limits the run to those sources.
# Default (empty) = everything. Useful for a fast top-up over a slow relay
# link, where the multi-MB logcat buffers would cost more than the whole
# diagnosis: `logcat -b main` alone is ~9 MB over DERP.
ONLY="${ONLY:-}"
want() {
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# finish <file> <name>: flag a capture that came back with no data, so an
# empty file is never mistaken for "nothing to report" later.
finish() {
  local file="$1" name="$2" payload
  payload="$(tail -n +5 "$file" 2>/dev/null)"
  if [ -z "${payload//[[:space:]]/}" ]; then
    echo "# WARNING: empty capture — source produced no output" >>"$file"
    log "WARNING: $name is empty"
  fi
}

# run <name> <remote-command>  -> writes $OUT/<name>.txt
run() {
  local name="$1"; shift
  want "$name" || return 0
  log "collecting $name"
  {
    echo "# collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# host: ${SSH_HOST}"
    echo "# cmd: $*"
    echo
    timeout 90 ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$*" 2>&1
  } >"$OUT/${name}.txt"
  finish "$OUT/${name}.txt" "$name"
}

# su_run: same, but wrapped in `su -c` for root-only sources.
# The command is single-quoted for the device shell, so any single quote inside
# it must be escaped as '\'' — otherwise the outer quote closes early and the
# device shell runs a truncated command. That silently truncated
# `meminfo-procs` on 2026-10-06: the remote loop never executed and the capture
# held nothing but the CSV header.
su_run() {
  local name="$1"; shift
  want "$name" || return 0
  local q=${*//\'/\'\\\'\'}
  log "collecting $name (root)"
  {
    echo "# collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# host: ${SSH_HOST}"
    echo "# cmd (root): $*"
    echo
    timeout 90 ssh "${SSH_OPTS[@]}" "$SSH_HOST" "su -c '$q'" 2>&1
  } >"$OUT/${name}.txt"
  finish "$OUT/${name}.txt" "$name"
}

## --- Device identity -------------------------------------------------------
run metadata "getprop | grep -E 'ro.build|ro.product|ro.vendor.build|ro.boot' | sort"
# /proc/version and /proc/cmdline are SELinux-gated on Android: unprivileged
# they return "Permission denied" (verified 2026-10-06), same family as the
# other four root-only sources above.
su_run kernel "uname -a; cat /proc/version"
su_run cmdline "cat /proc/cmdline"

## --- Kernel / hardware -----------------------------------------------------
su_run dmesg "dmesg"
su_run dmesg-warn "dmesg | grep -iE 'error|fail|warn|denied|timeout|panic|oom' | tail -n 2000"
su_run pstore "ls -la /sys/fs/pstore"
su_run modules "cat /proc/modules | sort"
su_run interrupts "cat /proc/interrupts"
su_run softirqs "cat /proc/softirqs"
run loadavg "cat /proc/loadavg; cat /proc/pressure/cpu 2>/dev/null; cat /proc/pressure/io 2>/dev/null"
run meminfo "cat /proc/meminfo"
run thermal "for z in /sys/class/thermal/thermal_zone*/; do echo \"--- \$z\"; cat \$z/type 2>/dev/null; cat \$z/temp 2>/dev/null; done"
run cpufreq "for c in /sys/devices/system/cpu/cpu*/cpufreq/; do echo \"--- \$c\"; cat \$c/scaling_governor 2>/dev/null; cat \$c/scaling_cur_freq 2>/dev/null; done"

## --- Fingerprint (ISSUE-001) ----------------------------------------------
# Absolute path: bare `dumpsys` is not on a Termux sshd PATH (rc=127).
su_run fp-services "/system/bin/dumpsys fingerprint 2>/dev/null | head -n 200"
run fp-list "pm list features 2>/dev/null | grep -i fingerprint; pm list packages 2>/dev/null | grep -iE 'finger|biometric|goodix|fpc'"
run fp-hal "getprop | grep -iE 'finger|biometric|goodix|fpc' | sort"
run fp-vendor "ls -la /vendor/bin/hw 2>/dev/null | grep -iE 'finger|biometric'; ls -la /vendor/lib64/hw 2>/dev/null | grep -iE 'finger|biometric'"

## --- Userspace logs --------------------------------------------------------
su_run logcat-main "logcat -d -b main -v threadtime"
su_run logcat-system "logcat -d -b system -v threadtime"
su_run logcat-crash "logcat -d -b crash -v threadtime"
su_run logcat-events "logcat -d -b events -v threadtime"
su_run logcat-errors "logcat -d -v threadtime | grep -iE ' E |error|exception|fatal|denied' | tail -n 3000"
## --- Services / system -----------------------------------------------------
# Absolute path: bare `dumpsys` is not on a Termux sshd PATH.
# No `head` on meminfo: the per-process RSS breakdown we need for ISSUE-002
# lives *after* the ~120-line summary block, so truncating there loses exactly
# the part we are looking for.
su_run dumpsys-meminfo "/system/bin/dumpsys meminfo"
# Per-process RSS/PSS straight from /proc, as CSV. `dumpsys meminfo` gives the
# framework's own view; this gives the kernel's, and unlike dumpsys it needs no
# service to exist (see notes). VmRSS is resident, Pss is proportional-set-size
# from smaps_rollup — the column that shows which process actually holds RAM.
su_run meminfo-procs "echo 'pid,comm,vms_rss_kb,pss_kb'; for p in /proc/[0-9]*; do pid=\${p#/proc/}; n=\$(cat \$p/comm 2>/dev/null | tr ',' '_'); r=\$(awk '/^VmRSS/{print \$2}' \$p/status 2>/dev/null); s=\$(awk '/^Pss/{print \$2}' \$p/smaps_rollup 2>/dev/null); [ -n \"\$r\" ] && echo \"\$pid,\$n,\$r,\${s:-0}\"; done | sort -t, -k3 -nr"
su_run dumpsys-cpuinfo "/system/bin/dumpsys cpuinfo"
su_run dumpsys-battery "/system/bin/dumpsys battery"
run props-all "getprop | sort"

## --- Manifest --------------------------------------------------------------
{
  echo "# Collection manifest"
  echo
  echo "- host: ${SSH_HOST}"
  echo "- date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$ONLY" ]; then
    echo "- run: PARTIAL (ONLY=$ONLY) — sources not listed here were not"
    echo "  requested in this run; an absent file does not mean an empty capture."
  else
    echo "- run: FULL"
  fi
  echo "- files:"
  for f in "$OUT"/*.txt; do
    [ -e "$f" ] || continue
    printf '  - %s (%s bytes)\n' "$(basename "$f")" "$(wc -c <"$f")"
  done
} >"$OUT/manifest.md"

log "done -> $OUT"
