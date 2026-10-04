# References — comparable devices, ROMs and trees

Devices and projects we can learn from when fixing `ruby`. Grouped by how close
they are to our problem.

## Same SoC family (MT6877)

- **`Nxages/redmi-note-11-pro-postmarketos-server`** — postmarketOS (headless) on
  `pissarro` (MT6877, Dimensity 920). **Downstream 4.14** kernel. Shows a real
  pmOS bring-up on the exact SoC, but with an old vendor kernel.
  https://github.com/Nxages/redmi-note-11-pro-postmarketos-server
- **`xiaomi-mt6893-dev/kernel_xiaomi_mt6893`** — downstream kernel source shared
  by `pissarro` (MT6877) and `agate`/`ares`/`choppin`. Useful for comparing
  vendor driver behaviour across MT6877 devices.
- **`rubyx-devs/*`, `YagizErdemir06/*`** — device trees and Android kernel for
  `rubyx`. The device tree (`device_xiaomi_rubyx`) is the place to fix the
  fingerprint HAL declaration (ISSUE-001).

## Same vendor, moved to mainline (the target architecture)

- **`bengris32/linux-mtk`** — MediaTek mainline work by Bengris32 (credited in
  the ruby mainline boot). Base of the WIP `mt6877` work (v7.1-rc4 at
  `6779b50faa562e6cca1aa6a4649a4d764c6c7e28`).
- **`MT6878-mainline/linux`** — mainline kernel for **MT6878** (Dimensity 7300),
  same generational block as MT6877. **Best template** for `pinctrl-mt6877.c`,
  `clk-mt6877-*`, `mt6877.dtsi`.
- **`mt6785-mainline/linux`** — mainline for MT6785 (`begonia`), shipped in
  pmaports as `linux-postmarketos-mediatek-mt6785` (6.16.4). Reference for how a
  MediaTek mainline device is packaged in postmarketOS.
- **`ellyq/mtk_g99-mainline`** (GitLab PMOS) — mainline MT6789 (Helio G99).
  Examples of DTS/pinctrl/clk/phy commits.

## MTK mainline forks and tooling

- **`MT6878-mainline`** (org) — kernel + u-boot + TF-A + EDK2 + lk for MT6878.
- **`bkerler/mtkclient`** — MediaTek flash/repair tool (read-only use in this
  repo's context).

## Other ROMs on similar MTK kernels (stability lessons)

- **`vitoramaral10/pmos-xiaomi-thunder`** — postmarketOS downstream on MT6833
  (Dimensity 700). Documents Wi-Fi/BT/GPU bring-up and a **Panfrost backport** on
  a vendor kernel. Same class of problem (MTK `gen4m` connectivity, Mali GPU,
  Novatek touch).
- **`Begonia`** (`begonia-kupfer-linux`, `begonia-pmos-tianma`) — MT6785 on
  mainline/Kupfer. Lessons on firmware paths, panel variants, `vbmeta --flags 2`.

## Concrete issues to audit against these references

| Issue | Closest reference | What to compare |
|-------|-------------------|-----------------|
| ISSUE-001 fingerprint | `rubyx-devs/device_xiaomi_rubyx` DS + other Goodix MTK ROMs | HAL (HIDL vs AIDL) declaration, `init.rc` service, `manifest.xml` |
| ISSUE-002 lag / GPU | `MT6878-mainline/linux`, Mali kbase in 6.6 tree | cache-flush / IOMMU code, LMKD tuning |

## Fingerprint HAL background (for ISSUE-001)

Android's biometric stack moved from **HIDL** (`@2.1`) to **AIDL**
(`android.hardware.biometrics.fingerprint.IFingerprint`) in Android 12+.
LineageOS 23.2 (Android 16) is AIDL-first. Devices that still ship a HIDL vendor
HAL need either:

- a working `HidlToAidlSensorAdapter` bridge, **or**
- the vendor HAL converted to AIDL, **or**
- the HIDL service explicitly declared and started in `vendor/etc/init/`.

Our logs (`Fingerprint HAL not available`, `HIDL daemon is null`) show the
bridge cannot find the HIDL daemon — so the first thing to check is whether the
device tree installs and starts a HIDL fingerprint service at all.
