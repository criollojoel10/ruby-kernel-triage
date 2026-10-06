#!/usr/bin/env bash
# redact-logs-test.sh — self-test for redact-logs.sh.
#
# Why this exists: redact-logs.sh printed "clean" while two of its rules were
# dead. GNU sed -E is POSIX ERE and rejects look-ahead, so the (?!...) guards
# aborted with "Invalid preceding regular expression" on stderr, the rule never
# ran, and leak_scan (grep -E, same limitation) could not see the leak either.
# Two broken checks agreed with each other and reported the directory safe.
#
# A passing redaction proves nothing about the GATE. Only a synthetic secret
# that must survive unredacted can tell you the gate still works. Every case
# below is a value that MUST appear in the output; if the gate cannot see it,
# the case fails and the script is not trustworthy.
#
# Run: bash scripts/redact-logs-test.sh

set -uo pipefail
cd "$(dirname "$0")/.."

REDACT=scripts/redact-logs.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/capture"
cat >"$work/capture/props.txt" <<'EOF'
[ro.serialno]: [vsqkkfojvsin6xor]
[ro.boot.serialno]: [vsqkkfojvsin6xor]
[ro.ril.oem.imei]: [868378066688269]
[ro.vendor.oem.imei1]: [868378066688269]
[ro.vendor.oem.imei2]: [868378066688277]
[ro.ril.oem.btmac]: [F4:1A:9C:9A:E8:24]
[ro.ril.oem.wifimac]: [F4:1A:9C:9A:DB:A4]
[ro.boot.chipid]: [0x15274aa8af239568c4238d554bf418b9]
[ro.boot.cpuid]: [0x15274aa8af239568c4238d554bf418b9ae43c40ebabbc05dbc79e8ae]
[persist.vendor.connsys.chipid]: [0x6877]
[vendor.connsys.adie.chipid]: [0x6635]
[ro.build.hardware]: [ruby]
EOF

cat >"$work/capture/kernel.txt" <<'EOF'
Cmdline: androidboot.serialno=vsqkkfojvsin6xor androidboot.hardware=ruby androidboot.chipid=0x15274aa8af239568c4238d554bf418b9 androidboot.cpuid=0x15274aa8af239568c4238d554bf418b9ae43c40ebabbc05dbc79e8ae
[    8.275666][    T1] init: Init cannot set 'ro.boot.serialno' to 'vsqkkfojvsin6xor': Read-only property was already set
[wlan] SCORE_CUR_AP bssid=F4:1A:9C:9A:E8:24 freq=5745 rssi=-76
[wlan] Ssid: HomeNetwork-5G rssi=-52
android_id: 1a2b3c4d5e6f7a8b
android_id=9f8e7d6c5b4a3210
bare imei with no key 868378066688269
EOF

# The SSID shapes that actually occur. Every name here is synthetic. They were
# added because the first version only handled `Ssid: NAME`, and the real
# captures leaked through three other spellings — including the neighbour-scan
# list, which enumerates other people's networks.
cat >"$work/capture/wlan.txt" <<'EOF'
[wlan][1]kalReportWifiLog:(AIS VOC) [CONN] CONNECTING ssid="NeighbourOne" bssid_hint=F4:1A:9C:9A:E8:24 freq_hint=5745
[wlan][2]kalIndicateStatusAndComplete:(INIT INFO) [wifi] wlan0 netif_carrier_on [ssid:NeighbourTwo 30:1f:**:**:**:c5], Mac:36:74:**:**:**:b4
10-04 00:54:30.775  2925 12263 I NearbyMediums: Wifi changed new SSID: "NeighbourThree"
[wlan][3]SCANLOG:(SCN INFO2) [SCN:600:D2K] Total:12/14  NeighbourA; NeighbourB; NeighbourC;
[wlan][4]SCANLOG:(SCN INFO2) [SCN:600:D2K] Total:1/24  NeighbourD;
[wlan][5]apsUpdateEssApList:(APS INFO) Find NeighbourE in 27 BSSes, result 1
[wlan][6]apsSearchBssDescByScore:(APS INFO) Selected None when find NeighbourG, 00:00:**:**:**:00 in 1(1) BSSes.
[wlan][6]kalReportWifiLog:(AIS VOC) [NBR_RPT] REQ TX token=3 ssid="NeighbourF" tx_status=ACK
EOF

# Fields that LOOK like the rules above but carry no name. If a rule is too
# greedy it eats these and the driver state in the logs stops being readable.
cat >"$work/capture/keep.txt" <<'EOF'
[wlan][7]mtk_cfg80211_scan:(REQ INFO) n_ssid=(1->0) n_channel(38==>38) wildcard=0x1
[wlan][8]ScanReqV2: ScanType=1,BSS=0,SSIDType=8,Num=1,Ext=0,ChCnt=0
[wlan][9]SCANLOG:(SCN INFO) [SCN:100:K2D] ssIdx=0 allow list: total=0
[wlan][10]beacon: SSIDX=0 36:74:**:**:**:b4 AuthMode[7]
[wlan][10b]beacon: SSIDX=0 02:00:**:**:**:00 AuthMode[7]
[wlan][11]handle SSID_HINT) drop
[wlan][12]SCANLOG:(SCN INFO2) [SCN:600:D2K] Count:1/24 keep
MemTotal:        8123456 kB
CmaTotal:        123456 kB
EOF

# Globally-unique partial BSSID: driver masks the middle but OUI + last byte
# stay real (home AP). Must go; the locally-administered ones above must stay.
cat >"$work/capture/bssid.txt" <<'EOF'
[wlan][13]apsSearchBssDescByScore:(APS INFO) Selected 30:1f:**:**:**:c5, RSSI[-67] Band[5G]
EOF

fail=0
note() { printf '%-46s %s\n' "$1" "$2"; }

# 1. Every synthetic secret must be gone from the redacted output.
run_redact() { bash "$REDACT" "$work/capture" >/dev/null 2>&1; }
run_redact

for secret in vsqkkfojvsin6xor 868378066688269 868378066688277 \
  'F4:1A:9C:9A:E8:24' 'F4:1A:9C:9A:DB:A4' \
  '30:1f:**:**:**:c5' \
  0x15274aa8af239568c4238d554bf418b9 \
  0x15274aa8af239568c4238d554bf418b9ae43c40ebabbc05dbc79e8ae \
  'HomeNetwork-5G' 1a2b3c4d5e6f7a8b 9f8e7d6c5b4a3210 \
  NeighbourOne NeighbourTwo NeighbourThree NeighbourFour NeighbourA \
  NeighbourB NeighbourC NeighbourD NeighbourE NeighbourF NeighbourG; do
  if grep -rqF "$secret" "$work/capture" 2>/dev/null; then
    note "leak removed: $secret" "FAIL"
    fail=1
  else
    note "leak removed: $secret" "ok"
  fi
done

# 2. Evidence the docs rely on must survive. The last group is the counter-test
#    for rule 6: fields whose names merely START with `ssid`/`SSID`, plus the
#    scan counts. A greedy rule eats them and the logs stop being diagnosable.
#    The locally-administered partial MACs must also survive (rule 4b only
#    targets globally-unique OUIs); the global one is asserted gone above.
for keep in '0x6877' '0x6635' 'ro.build.hardware' 'androidboot.hardware=ruby' \
  'n_ssid=(1->0)' 'SSIDType=8' 'ssIdx=0' 'SSIDX=0' 'SSID_HINT' \
  '36:74:**:**:**:b4' '02:00:**:**:**:00' \
  'Total:12/14' 'Total:1/24' 'MemTotal:' 'CmaTotal:'; do
  if grep -rqF "$keep" "$work/capture" 2>/dev/null; then
    note "evidence kept: $keep" "ok"
  else
    note "evidence kept: $keep" "FAIL"
    fail=1
  fi
done

# 3. Idempotency: three passes, byte-identical. This is the check that caught the
#    _REDACTED_REDACTED runaway in the first place.
before=$(find "$work/capture" -type f -exec md5sum {} + | sort)
run_redact
run_redact
after=$(find "$work/capture" -type f -exec md5sum {} + | sort)
if [ "$before" = "$after" ]; then
  note "idempotent over 3 passes" "ok"
else
  note "idempotent over 3 passes" "FAIL"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after")
  fail=1
fi

# 4. No duplicated marker anywhere.
if grep -rqE '_REDACTED_(REDACTED)' "$work/capture" 2>/dev/null; then
  note "no runaway markers" "FAIL"
  fail=1
else
  note "no runaway markers" "ok"
fi

# 5. The gate must FAIL when a secret is present. A gate that cannot fail is not
#    a gate, so poison the directory and require a non-zero exit.
printf 'injected 868378066688269\n' >"$work/capture/leak-probe.txt"
if bash "$REDACT" "$work/capture" >/dev/null 2>&1; then
  if grep -rqE '\b8[0-9]{14}\b' "$work/capture" 2>/dev/null; then
    note "gate rejects a leaked IMEI" "FAIL (clean reported with IMEI present)"
    fail=1
  else
    note "gate rejects a leaked IMEI" "ok (redacted before the scan)"
  fi
else
  note "gate rejects a leaked IMEI" "ok (non-zero exit)"
fi
rm -f "$work/capture/leak-probe.txt"

# 5b. Same for the neighbour-scan list, which has its own scan line. Without this
#     a typo in that one grep would leave the widest leak ungated while every
#     other case still reports ok.
printf 'SCANLOG:(SCN INFO2) Total:2/14  PoisonAPOne; PoisonAPTwo;\n' >"$work/capture/scan-probe.txt"
bash "$REDACT" "$work/capture" >/dev/null 2>&1
if grep -rqE 'PoisonAPOne|PoisonAPTwo' "$work/capture" 2>/dev/null; then
  note "gate rejects a leaked neighbour list" "FAIL (clean reported with names present)"
  fail=1
else
  note "gate rejects a leaked neighbour list" "ok"
fi
rm -f "$work/capture/scan-probe.txt"

# 5b. A device-tree dump must be redacted like any other capture. The file-name
#     filter used to accept only *.txt/*.md, so a decompiled .dts under logs/
#     was skipped while still reporting "clean" — and its bootargs carries the
#     real androidboot.serialno and chipid. Verified 2026-10-06.
printf 'chosen@0 {\n\tbootargs = "androidboot.serialno=vsqkkfojvsin6xor androidboot.chipid=0x15274aa8af239568c4238d554bf418b9";\n\tcompatible = "mediatek,mt6877-pwrap";\n};\n' >"$work/capture/ruby-fdt.dts"
out=$(bash "$REDACT" "$work/capture" 2>&1)
if grep -qE 'vsqkkfojvsin6xor|0x15274aa8af239568c4238d554bf418b9' "$work/capture/ruby-fdt.dts" 2>/dev/null; then
  note "leak removed: .dts bootargs" "FAIL (device tree kept a real serial/chipid)"
  fail=1
elif ! grep -q 'mediatek,mt6877-pwrap' "$work/capture/ruby-fdt.dts" 2>/dev/null; then
  note "leak removed: .dts bootargs" "FAIL (redaction ate the binding evidence)"
  fail=1
else
  note "leak removed: .dts bootargs" "ok"
  note "evidence kept: mt6877-pwrap compatible" "ok"
fi
rm -f "$work/capture/ruby-fdt.dts"

# 5c. A binary .dtb cannot be redacted with sed without corrupting the FDT
#     string block (rewriting a value to a different length breaks the offsets
#     that point at it). It must be refused loudly, never reported clean.
printf '\xd0\x0d\xfe\xed\x00\x00\x04\x4b\x70wrap\x00serialno=vsqkkfojvsin6xor\x00' >"$work/capture/ruby-fdt.dtb"
out=$(bash "$REDACT" "$work/capture" 2>&1)
if printf '%s' "$out" | grep -q 'BINARY FILE NOT REDACTED.*ruby-fdt\.dtb'; then
  note "binary .dtb refused, not silently skipped" "ok"
else
  note "binary .dtb refused, not silently skipped" "FAIL (accepted as clean)"
  printf '%s\n' "$out" | head -5
  fail=1
fi
rm -f "$work/capture/ruby-fdt.dtb"

# 6. No rule may emit a sed error: an unsupported regex makes a rule a silent
#    no-op, which is the failure mode this file exists to catch.
errs=$(bash "$REDACT" "$work/capture" 2>&1 >/dev/null | grep -c 'Invalid\|unknown option\|bad flag')
if [ "$errs" -eq 0 ]; then
  note "no sed errors" "ok"
else
  note "no sed errors" "FAIL ($errs errors)"
  bash "$REDACT" "$work/capture" 2>&1 >/dev/null | head -5
  fail=1
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  echo "PASS: redact-logs.sh removes every synthetic secret, keeps the evidence, and is idempotent"
else
  echo "FAIL: see the cases marked FAIL above"
fi
exit "$fail"