# Device profile — `ruby`

Ground truth for the device this repository is about. Everything here is
verified on the live device unless marked otherwise.

## Hardware

| Item | Value |
|------|-------|
| Marketing name | Xiaomi Redmi Note 12 Pro 5G |
| Codename | `ruby` / `rubyx` |
| SoC | MediaTek **MT6877V** (Dimensity 1080) |
| CPU | 2x Cortex-A78 @ 2.6 GHz + 6x Cortex-A55 @ 2.0 GHz |
| GPU | ARM **Mali-G68 MC4** @ 950 MHz |
| RAM | 7.5 GiB (LPDDR4X) |
| Storage | 256 GB UFS |
| Display | 1080x2400, M16_42 DSC panel |
| Fingerprint | **Goodix** (`persist.vendor.sys.fp.vendor=goodix`) |
| NFC | ST21 NFC |
| Wi-Fi/BT | MediaTek `connac`/gen4m, chip soc5_0 |

## Software (as collected)

| Item | Value |
|------|-------|
| ROM | **LineageOS 23.2** `23.2-20261002-UNOFFICIAL-rubyx` |
| Android | 16 (`BP4A.251205.006`), security patch `2026-08-01` |
| Kernel | `6.6.127-4k-ged71a8f07b9c-dirty` |
| Kernel compiler | Clang/LLVM r563880, LLD 21.0.0 (+pgo +bolt +lto +mlgo) |
| Build fingerprint | `Redmi/ruby_global/ruby:14/UP1A.230620.001/OS2.0.11.0.UMOMIXM:user/release-keys` |
| Active slot | `_b` |
| Verified boot | `green` / `locked` / verity `enforcing` |

> The build fingerprint still reports `:14/UP1A...` (the vendor blobs are from
> Android 14 / HyperOS 2), while the system is Android 16. This mismatch is
> expected for a bring-up ROM but is worth keeping in mind for HAL compatibility.

## Collection provenance

- Collected over SSH (Termux `sshd`) from user `u0_a199`, root via KernelSU.
- Date: see `logs/<date>/manifest.md`.
- The device is the owner's daily driver: collection is **strictly read-only**.
