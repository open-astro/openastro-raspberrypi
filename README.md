# OpenAstro for Raspberry Pi

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

OpenAstro OS for the **Raspberry Pi 3B+, 4, and 5**: a
[Raspberry Pi OS Lite](https://www.raspberrypi.com/software/operating-systems/)
(arm64, no GUI) based image with a WiFi access point and everything ready for
[AlpacaBridge](https://github.com/open-astro/AlpacaBridge).

**One image covers all three boards** — Raspberry Pi firmware selects the
right kernel/device tree automatically. The OS **runs from the microSD
card** — flash it, insert it, power on.

## Supported hardware

| Device | Kernel | Status |
|--------|--------|--------|
| Raspberry Pi 5 | Raspberry Pi OS stock | 🚧 Pending validation |
| Raspberry Pi 4 / 400 | Raspberry Pi OS stock | 🚧 Pending validation |
| Raspberry Pi 3B+ | Raspberry Pi OS stock | 🚧 Pending validation |

> **ZWO EAF/EFW:** the stock Raspberry Pi OS kernel ships with HIDRAW
> enabled, and the image bakes in a udev rule granting device access, so ZWO
> HID accessories should work out of the box. Validation on hardware (as done
> for the Orange Pi 4 Pro image) is pending.

## Install

### 1. Download + flash

Grab the latest `openastro-raspberrypi.img.xz` from the
[Releases](../../releases) page and flash it to a microSD card (8 GB+) with
[Raspberry Pi Imager](https://www.raspberrypi.com/software/),
[balenaEtcher](https://etcher.balena.io/), or `dd`:

```bash
xzcat openastro-raspberrypi.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

(Use Imager's "No customisation" option — credentials and WiFi are already
baked in.)

### 2. Boot

Insert the microSD and power on. The board boots and runs entirely from the
SD card — leave it in.

## First boot defaults

| Setting | Value |
|---------|-------|
| Hostname | `openastro` |
| Login | `astro` / `astro` — **change immediately:** `passwd` |
| WiFi AP | `OpenAstro-XXXX` (5 GHz, ch 36), password `12345678` |
| AP address | `172.24.1.1` (DHCP for clients) |
| Ethernet | DHCP |

`XXXX` is the last 4 hex digits of the board's WiFi MAC address (e.g.
`OpenAstro-915D`), applied automatically on first boot so multiple boards in
the same place each get a unique hotspot name.

Reach it over ethernet (`ssh astro@<ip>`) or by joining the `OpenAstro-XXXX`
WiFi. The access point starts automatically at every boot, so even if the
board can't be reached over your network you can always join its hotspot and
log in at `172.24.1.1`.

### Connect to your own network instead (optional)

All networking is managed by NetworkManager; `wlan0` runs the access point
by default. To put the board on your LAN, use the ethernet port, or switch
WiFi to client mode with `nmcli` (e.g.
`sudo nmcli dev wifi connect <SSID> password <pass>` — note this takes down
the hotspot; the upcoming AlpacaBridge WiFi manager will handle this from
the web portal with automatic hotspot fallback).

## Install AlpacaBridge

AlpacaBridge is **not** baked into the image. Install it by following the
[AlpacaBridge install guide](https://github.com/open-astro/AlpacaBridge),
which adds the OpenAstro apt repository and installs the package — the same
as on every other platform.

## Build the image yourself

The release image is built from a stock Raspberry Pi OS Lite (arm64) image
plus the OpenAstro layer. On an **aarch64** host (an arm64 Debian box, or a
Pi itself — it's a native chroot, no emulation):

```bash
# 1. grab the latest Raspberry Pi OS Lite arm64 image
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz

# 2. bake in the OpenAstro layer and repack
sudo apt install parted e2fsprogs dosfstools
sudo build/build-openastro-image.sh 2025-05-13-raspios-bookworm-arm64-lite.img.xz images/openastro-raspberrypi.img.xz
```

- [`build/build-openastro-image.sh`](build/build-openastro-image.sh) — customizes
  the Raspberry Pi OS image in a chroot and produces a compressed, flashable
  `.img.xz`.
- [`openastro/openastro-setup.sh`](openastro/openastro-setup.sh) — the OpenAstro
  layer (WiFi AP, baked-in credentials, ZWO udev rule). Idempotent; also
  runnable directly on a booted Raspberry Pi OS board.

## Sibling projects

- [openastro-orangepi4pro](https://github.com/open-astro/openastro-orangepi4pro)
  — same OpenAstro layer for the Orange Pi 4 Pro (Allwinner A733).

## License

See [LICENSE.md](LICENSE.md).
