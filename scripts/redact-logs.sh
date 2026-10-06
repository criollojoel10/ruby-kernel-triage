#!/usr/bin/env bash
# Redact device identifiers from captured logs, in place.
#
# Why this exists: the 2026-10-04 capture was committed to this PUBLIC repo
# with the device IMEI, the WiFi/Bluetooth MACs, the connected AP's BSSID and
# the home WiFi SSID in plain text. Captures are raw `getprop`/`logcat`/dmesg
# dumps, so they carry identifiers by default and nobody redacts them by hand
# reliably.
#
# Two deliberate design choices:
#
#  * The rules are key- and structure-aware rather than blanket regexes, because
#    blanket rules destroy the evidence they are meant to protect. A naive
#    15-digit pattern also eats logcat timestamps; a naive MAC pattern also
#    eats the masked MACs the MTK wifi driver already prints
#    (`02:00:**:**:**:00`), which are anonymous. So only fully-hex MACs and only
#    named fields are rewritten, and a capture stays diagnosable afterwards.
#
#  * Each rule is a separate `sed` call. They ran as one `-e` list first and a
#    single bad expression aborted the whole set, which silently skipped the
#    serial-number rule — the exact failure mode this script exists to prevent.
#
# Usage: redact-logs.sh <dir> [<dir>...]
# Idempotent: re-running is a no-op.

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") <dir> [<dir>...]" >&2
  exit 2
fi

# Only fully-hex 6-octet MACs. Masked forms contain '*' and must not match.
MAC='\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b'

status=0

redact_file() {
  local f="$1" before after

  before=$(wc -c <"$f")

  # 1. SIM identifiers, key-aware: only the value after a named IMEI/IMSI key.
  sed -i -E 's/(\b(imei|imsi)[0-9]*\]?[[:space:]]*:[[:space:]]*\[)[0-9]{14,17}\]/\1IMEI_REDACTED]/Ig' "$f"

  # 1b. Bare IMEI with no key in front of it. Anchored on the 15-digit, leading-8
  #     shape so it cannot eat logcat timestamps: threadtime stamps are
  #     "MM-DD HH:MM:SS.mmm" and epoch-ms values are 13 digits, so a 15-digit
  #     run starting with 8 is an IMEI in practice (TAC 86xxxx).
  sed -i -E 's/\b8[0-9]{14}\b/IMEI_REDACTED/g' "$f"

  # 2. android_id, key-aware (it is a stable per-sign-in identifier). Two
  #    shapes: the bracketed getprop form and the bare `key: value` form that
  #    dumps and some HAL logs use. The bracketed rule alone missed the bare
  #    one, which is what redact-logs-test.sh caught.
  sed -i -E 's/(\bandroid_id[a-z_0-9]*\]?[[:space:]]*:[[:space:]]*\[)[0-9a-fA-F]{8,}\]/\1ANDROID_ID_REDACTED]/Ig' "$f"
  #    `\b` closes the value so a longer hex token is not half-matched.
  #    Idempotent because the marker cannot START an 8-hex-digit run: `A` is hex
  #    but `N` in ANDROID is not, so the class dies at length 1 and the rule
  #    never re-matches its own output.
  sed -i -E 's/(\bandroid_id[a-z_0-9]*\]?[[:space:]]*[:=][[:space:]]*)[0-9a-fA-F]{8,}\b/\1ANDROID_ID_REDACTED/Ig' "$f"

  # 3. Factory MAC properties (ro.ril.oem.btmac / .wifimac and friends).
  sed -i -E 's/(\.(bt|btmac|wifimac|wifi_mac|mac)\]:[[:space:]]*\[)[0-9a-fA-F:]+\]/\1MAC_REDACTED]/Ig' "$f"

  # 4. Any remaining fully-hex MAC anywhere (covers bssid=, BSSID=, peer
  #    addresses, interface listings). The key is kept so the line still reads
  #    as "there was a BSSID here".
  sed -i -E "s/$MAC/MAC_REDACTED/g" "$f"

  # 4b. Partially-masked BSSIDs with a globally-unique OUI
  #    (e.g. `30:1f:**:**:**:c5`). The MTK wifi driver masks the middle bytes
  #    but leaves OUI + last byte in clear; when the OUI is globally administered
  #    (first byte & 0x02 == 0, i.e. 2nd hex digit in 0,1,4,5,8,9,c,d) that is a
  #    stable identifier of someone's AP. Locally-administered partials
  #    (02:xx, 06:xx, 36:74, 56:2a, ...) are randomized and stay, they are the
  #    diagnostic part. Idempotent: the marker contains no `**` pattern.
  #    No trailing boundary: the driver glues the address to what follows
  #    (`...:c5ACM`, `...:c5Tx=1`), and the glue starts with a hex letter, so a
  #    `[^hex]` / `\b` guard never matches. Safe without it because the `**`
  #    inside can never be part of a longer hex token.
  sed -i -E 's/(^|[^0-9a-fA-F])([0-9a-fA-F][014589cCdD]:[0-9a-fA-F]{2}:\*\*:\*\*:\*\*:[0-9a-fA-F]{2})/\1BSSID_REDACTED/g' "$f"

  # 5. Android serial number, in each shape it actually appears in.
  #    Idempotency: the value class INCLUDES `_`, so an already-redacted
  #    `SERIAL_REDACTED` is matched whole and rewritten to itself.
  #    The earlier version used `[0-9a-zA-Z]+` plus a `([^0-9a-zA-Z]|$)`
  #    delimiter group, and the comment claimed the `_` inside the marker kept
  #    the rule from re-matching. That was wrong: `_` cannot enter the VALUE
  #    class, but it does satisfy the DELIMITER class, so the rule re-matched
  #    `SERIAL` + `_` and produced `SERIAL_REDACTED_REDACTED` on every pass.
  #    `cmdline token: androidboot.serialno=vsqkkfojvsin6xor`
  sed -i -E 's/androidboot\.serialno=[0-9a-zA-Z_]+/androidboot.serialno=SERIAL_REDACTED/g' "$f"
  #    init error quoting the read-only property:
  #    Init cannot set 'ro.boot.serialno' to 'vsqkkfojvsin6xor': ...
  sed -i -E "s/('ro\.boot\.serialno'[[:space:]]+to[[:space:]]+')[0-9a-zA-Z_]+(')/\1SERIAL_REDACTED\2/Ig" "$f"
  #    getprop line: [ro.serialno]: [vsqkkfojvsin6xor]
  sed -i -E 's/(\.serialno\]?[[:space:]]*:[[:space:]]*\[)[0-9a-zA-Z_]+\]/\1SERIAL_REDACTED]/Ig' "$f"

  # 6. Network names. Structural, not a hardcoded list: the MTK wifi driver logs
  #    "Ssid: <name>" and Android logs "ANQP entry not found for: <MAC>:<name>".
  #    A home network name identifies the user as much as an address does.
  #    Case-insensitive (`I`) and tolerant of a value in quotes, because the same
  #    field appears as `Ssid: NAME`, `ssid=NAME`, `ssid:NAME` and
  #    `SSID: "NAME"`. `\b` before `ssid` is load-bearing: it keeps the rule off
  #    `n_ssid=`, `SSIDType=`, `SSIDX=`, `ssIdx=` and `SSID_HINT`, none of which
  #    carry a name.
  sed -i -E 's/(\bssid[[:space:]]*[=:][[:space:]]*"?)[^",[:space:]]+("?)/\1SSID_REDACTED\2/Ig' "$f"
  sed -i -E 's/(ANQP entry not found for:[[:space:]]*MAC_REDACTED:).*/\1SSID_REDACTED/g' "$f"
  # 6b. The neighbour-scan result list. This is the one that leaks OTHER people:
  #     a scan dump enumerates every nearby network, and real networks carry real
  #     household names. So the whole list goes, not just the one we joined.
  #     The `N/M` counts survive because they are the diagnostic part (how many
  #     SSIDs the scan resolved); only the names after them are dropped.
  sed -i -E 's/(Total:[0-9]+\/[0-9]+[[:space:]]+).*/\1SSID_LIST_REDACTED;/' "$f"
  # 6c. The AP-selection logs name the network in free text, in two shapes:
  #     "apsUpdateEssApList:(APS INFO) Find <name> in 27 BSSes"
  #     "apsSearchBssDescByScore:(APS INFO) Selected None when find <name>, <bssid> in 1(1) BSSes."
  #     In both, the name runs up to a comma or to " in ".
  sed -i -E 's/(Find )[^,[:space:]]+( in [0-9]+ BSSes)/\1SSID_REDACTED\2/' "$f"
  sed -i -E 's/([Ww]hen find )[^,[:space:]]+/\1SSID_REDACTED/' "$f"

  # 7. Per-unit silicon identifiers. ro.boot.chipid / ro.boot.cpuid carry a
  #    32- or 44-hex-digit factory hash, unique to the handset, so they identify
  #    the device exactly as well as a serial does. The small SoC revision
  #    fields (persist.vendor.connsys.chipid, vendor.connsys.adie.chipid) are
  #    left alone: those are the chip *family* (0x6877 = MT6877), not a unit id,
  #    and the docs cite them as evidence.
  #    The value is written 0x-prefixed (0x15274aa8...), so the hex run starts
  #    after that prefix; matching [0-9a-fA-F]{16,} against the "0x" head finds
  #    nothing. The closing bracket is part of the match, which keeps the rule
  #    idempotent for the same reason as rule 5.
  sed -i -E 's/(\b(ro\.boot|ro)\.(cpuid|chipid)\]?[[:space:]]*:[[:space:]]*\[)(0x)?[0-9a-fA-F]{16,}\]/\1CHIPID_REDACTED]/Ig' "$f"
  #    7b. The same hashes also appear as bare bootargs tokens
  #      (`androidboot.cpuid=0x15274aa8...` in /proc/cmdline), which the
  #      bracket-anchored rule above cannot see: no `]: [` around the value.
  #      Caught on the 2026-10-06 capture, where the factory hashes in
  #      cmdline.txt were still in clear. Idempotent because the marker drops
  #      the `0x` head, so `0x[0-9a-fA-F]{16,}` never matches it again.
  sed -i -E 's/androidboot\.(cpuid|chipid)=0x[0-9a-fA-F]{16,}/androidboot.\1=CHIPID_REDACTED/g' "$f"

  after=$(wc -c <"$f")
  if [ "$after" != "$before" ]; then
    echo "redacted: $f ($before -> $after bytes)"
  fi
}

# leak_scan <dir> — print anything still recognisable, return 0 when clean.
leak_scan() {
  local dir="$1"
  grep -rInE "$MAC" "$dir" 2>/dev/null | grep -vE 'MAC_REDACTED' | head -20
  # Globally-unique partial BSSIDs (see rule 4b). Locally-administered ones
  # (2nd hex digit 2,3,6,7,a,b,e,f) are randomized and not scanned.
  # No trailing \b on purpose: the driver glues the address (`:c5ACM`, `:c5Tx`).
  grep -rInE '[0-9a-fA-F][014589cCdD]:[0-9a-fA-F]{2}:\*\*:\*\*:\*\*:[0-9a-fA-F]{2}' "$dir" 2>/dev/null | head -20
  grep -rInE "\b(imei|imsi)[0-9]*\]?[[:space:]]*:[[:space:]]*\[[0-9]{14,17}" "$dir" 2>/dev/null | head -20
  grep -rInE "(androidboot\.serialno|ro\.boot\.serialno|ro\.serialno|android_id)[^0-9A-Za-z]{0,4}[0-9a-zA-Z]{8}" "$dir" 2>/dev/null | grep -vE 'REDACTED' | head -20
  # `-i` mirrors the `I` flag on the rule above; a scan that is stricter about
  # case than the rule cannot see a leak the rule was supposed to catch.
  grep -rInEi "\bssid[[:space:]]*[=:][^[:space:]]*[A-Za-z0-9]" "$dir" 2>/dev/null | grep -vE 'SSID_REDACTED' | head -20
  grep -rInE "ANQP entry not found for:[^ ]*:[A-Za-z0-9]" "$dir" 2>/dev/null | grep -vE 'SSID_REDACTED' | head -20
  # The neighbour-scan list and the AP-selection line. Both carry names of
  # networks the device merely SAW, which is third-party data, so they are
  # checked explicitly instead of relying on the ssid-key rules above.
  grep -rInE "Total:[0-9]+/[0-9]+[[:space:]]+[A-Za-z0-9]" "$dir" 2>/dev/null | grep -vE 'SSID_LIST_REDACTED' | head -20
  grep -rInE "Find [^,[:space:]]+ in [0-9]+ BSSes" "$dir" 2>/dev/null | grep -vE 'SSID_REDACTED' | head -20
  grep -rInEi "[Ww]hen find [^,[:space:]]+" "$dir" 2>/dev/null | grep -vE 'SSID_REDACTED' | head -20
  # Per-unit silicon ids: 16+ hex digits behind a cpuid/chipid key, optionally
  # 0x-prefixed. The SoC family values the docs rely on are short (0x6877) and
  # must not match. ERE only, for the same reason as the sed rules.
  grep -rInE "\b(ro\.boot|ro)\.(cpuid|chipid)\]?[[:space:]]*:[[:space:]]*\[(0x)?[0-9a-fA-F]{16,}" "$dir" 2>/dev/null | grep -vE 'CHIPID_REDACTED' | head -20
  # Runaway markers: a duplicated marker means a rule re-matched its own output.
  grep -rInE "(IMEI|MAC|SERIAL|SSID|ANDROID_ID|CHIPID)_REDACTED_(REDACTED|)" "$dir" 2>/dev/null | head -20
}

for dir in "$@"; do
  if [ ! -d "$dir" ]; then
    echo "skip (not a dir): $dir" >&2
    continue
  fi
  # Text captures: redact, whatever the extension. The list used to be
  # *.txt/*.md only, so a decompiled .dts was skipped while the directory still
  # reported "clean" — and a device tree's bootargs carries the real
  # androidboot.serialno and chipid. Found 2026-10-06.
  while IFS= read -r -d '' f; do
    redact_file "$f"
  done < <(find "$dir" -type f \
             \( -name '*.txt' -o -name '*.md' \
                -o -name '*.dts' -o -name '*.dtsi' \) -print0)

  # Binaries carry the same identifiers as raw bytes (a dumped .dtb has
  # androidboot.serialno= and androidboot.chipid= in its string block), and
  # rewriting one with `sed -i` corrupts the blob: the FDT string block is
  # addressed by offset, so replacing a value with a different length shifts
  # every string after it. Refuse them loudly instead of letting them pass as
  # "clean" — which is exactly what the extension filter used to do.
  while IFS= read -r -d '' f; do
    if LC_ALL=C grep -Iq . "$f" 2>/dev/null; then
      continue
    fi
    if LC_ALL=C grep -qUa . "$f" 2>/dev/null; then
      echo "BINARY FILE NOT REDACTED: $f" >&2
      status=1
    fi
  done < <(find "$dir" -type f ! -path '*/.git/*' -print0)

  # Gate: never report a directory clean while anything recognisable is left.
  if [ -n "$(leak_scan "$dir")" ]; then
    echo "LEAK STILL PRESENT under $dir — review manually:" >&2
    leak_scan "$dir" >&2
    status=1
  else
    echo "clean: $dir"
  fi
done

exit "$status"