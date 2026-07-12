English | [日本語](README.ja.md)

# uconsole-archlinux

Scripts that build a bootable **Arch Linux ARM (aarch64) SD-card image for the
ClockworkPi uConsole (CM4)**.

Based on the official Arch Linux ARM Raspberry Pi tarball (`rpi-aarch64`), the
image bakes in uConsole-specific boot configuration (DSI display, audio, etc.)
and a **self-built kernel** with uConsole support.

> [!IMPORTANT]
> The uConsole's 5-inch DSI panel (cwu50), PMU, backlight, etc. do **not** work
> with Arch's stock `linux-aarch64`. Moreover, **the 2026-and-later new batch
> changed the panel vendor/spec**, and kernels without the corresponding patch
> (old ClockworkPi 5.10, OuinOuin74 6.16, ...) leave the **backlight on but the
> panel showing horizontal lines / garbled / black**. This repo builds
> **ak-rex/ClockworkPi-linux (`rpi-6.12.y`)** from source. Its `panel-cwu50`
> driver **auto-detects old vs new panels via `id_gpio`**
> (`is_new_panel` → `cwu50_init_sequence2()`), driving the new batch correctly.
> See [About the kernel](#about-the-kernel).

## Requirements

- The build runs **as root on a Linux host** (it uses loop devices).
- **docker** for the kernel build (cross-compiled inside the `ubuntu:24.04` image).
- Required commands:
  - `docker` (kernel build)
  - `wget` or `curl`
  - `bsdtar` (`libarchive`)
  - `mkfs.vfat` (`dosfstools`), `mkfs.ext4` (`e2fsprogs`)
  - `sfdisk`, `losetup` (`util-linux`)
  - (for chroot customization) `qemu-aarch64-static` + `binfmt` (`qemu-user-static`)

One-shot install on an Arch host:

```sh
sudo pacman -S --needed docker wget libarchive dosfstools e2fsprogs util-linux \
  qemu-user-static qemu-user-static-binfmt
sudo systemctl start docker
```

## Usage

```sh
# 1. Build the kernel (first time only; 30-60 min; cross-compiled in docker)
./scripts/build-kernel.sh

# 2. Build the SD-card image (pulls in the self-built kernel)
sudo ./build.sh
```

`build-kernel.sh` emits its artifacts into `kernel/out` (kernel8.img, dtb,
overlays) and `kernel/modules`, and `build.sh` deploys them directly into the
image. The base tarball (~800MB) is cached under `cache/` on the first run.

Output: `out/uconsole-archlinux-YYYYMMDD.img`

Write to an SD card (verify the device name — **the wrong device destroys
another drive**):

```sh
sudo dd if=out/uconsole-archlinux-*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

The image is a fixed `IMG_SIZE` (6G by default), but you do **not** need to
manually grow it: on the **first boot** the root partition and its filesystem
are automatically expanded to fill the whole SD card (a one-shot systemd
service that disables itself afterwards).

### Main settings (overridable via environment variables)

| Variable      | Default                             | Description                     |
| ------------- | ----------------------------------- | ------------------------------- |
| `IMG_SIZE`    | `6G`                                | Total image size                |
| `BOOT_SIZE`   | `256M`                              | Boot (FAT32) partition          |
| `UC_HOSTNAME` | `uconsole`                          | Hostname                        |
| `TIMEZONE`    | `Asia/Tokyo`                        | Timezone                        |
| `LOCALE`      | `en_US.UTF-8`                       | Locale                          |
| `TARBALL_URL` | ArchLinuxARM official rpi-aarch64   | Base tarball URL                |
| `KSRC_BRANCH` | `rpi-6.12.y`                        | Kernel branch to build          |
| `KDEFCONFIG`  | `bcm2711_defconfig`                 | Kernel defconfig (CM4)          |
| `JOBS`        | `nproc`                             | Kernel build parallelism        |
| `OUT_DIR`     | `./out`                             | Output directory                |
| `SKIP_CHROOT` | (unset)                             | `1` to skip chroot customization |
| `AIO_BOARD`   | (unset)                             | `v1`/`v2` to enable the [AIO extension board](#aio-extension-board-optional) |

Example:

```sh
sudo IMG_SIZE=8G UC_HOSTNAME=myuconsole ./build.sh
```

## Updating an already-running device

You do **not** need to re-flash to pick up a newer kernel. The base Arch Linux
ARM system updates itself with `sudo pacman -Syu` (rolling); the self-built
**kernel + boot config** are delivered separately via GitHub Releases and
installed in place:

```sh
# on the uConsole itself
sudo ./scripts/update.sh            # install the latest released kernel
sudo ./scripts/update.sh --force    # reinstall / re-apply explicitly
sudo reboot                         # changes apply on reboot
```

`update.sh` downloads the release tarball, backs up the current
`/boot/kernel8-cm4.img` (+ `config.txt` / `cmdline.txt`) to `*.bak`, installs the
new kernel / modules / DTBs / overlays and boot config, then records the version
in `/boot/uconsole-kernel.release` (so re-running is a no-op when already
current). Only **published, hardware-verified** releases are installed — never a
branch HEAD. If a new kernel won't boot, restore `kernel8-cm4.img.bak` from any
machine that can mount the FAT32 boot partition.

> Maintainers cut a release with `scripts/package-kernel.sh` — see
> [MAINTAINING.md](MAINTAINING.md).

## AIO extension board (optional)

The [HackerGadgets uConsole AIO V1/V2](https://hackergadgets.com/pages/hackergadgets-uconsole-rtl-sdr-lora-gps-rtc-usb-hub-all-in-one-extension-board-setup-guide)
adds RTL-SDR, LoRa (Semtech SX1262), GPS, a battery-backed PCF85063A RTC, and a
USB hub. Support is **opt-in** via `AIO_BOARD` — the default image is unchanged:

```sh
AIO_BOARD=v1 sudo ./build.sh   # AIO V1 (all rails on by default)
AIO_BOARD=v2 sudo ./build.sh   # AIO V2 (GPIO-gated rails powered on at boot)
```

What the flag bakes in (**hardware enablement only**):

- **config.txt overlays** appended for CM4: RTC (`i2c-rtc,pcf85063a`), LoRa SPI1
  (`spi1-1cs`), and GPS over the already-enabled UART. `v2` additionally drives
  the GPS/LoRa/SDR/internal-USB power-enable GPIOs high (`gpio=...=op,dh`), since
  on V2 those rails are off until pulled high.
- **kernel modules** `rtc-pcf85063` and `spidev` (enabled unconditionally in
  `build-kernel.sh`; they only load when the board is present).
- an `/etc/modprobe.d` blacklist of the RTL2832 DVB TV drivers so libusb SDR
  tools can claim the dongle.
- **`v2` only:** `libgpiod` + a `uconsole-aio-gpio.service` that re-asserts and
  **holds** the enable GPIOs high after boot. The firmware `gpio=…=op,dh` alone is
  *not* enough — it is released when the kernel GPIO subsystem initialises, so the
  rails power off ~8 s in (observed on hardware: the RTL-SDR enumerates then
  USB-disconnects). The service (`gpioset` holding BCM 7/16/23/27) keeps them on.

The RTC works out of the box (the kernel binds `/dev/rtc0` from the overlay and
systemd reads it at boot). The **userspace SDR/LoRa apps are not baked in** — the
vendor's `apt`/`.deb` packages don't exist on Arch. Install them yourself, e.g.
from the official repo / AUR: **`rtl-sdr`** (required for the RTL-SDR — provides
`librtlsdr` that SDR++'s `rtl_sdr_source` plugin dlopens, plus `rtl_test` and the
udev `uaccess` rule), `sdrpp-git`, `meshtasticd`. Meshtastic's LoRa `config.yaml`
uses `spidev1.0`.

> [!NOTE]
> The exact V2 GPIO pin numbers and RTC I²C address follow the vendor guide and
> should be re-checked against your board revision.

> [!WARNING]
> On-device `scripts/update.sh` reinstalls `config.txt` from the release tarball
> (which is built without AIO), so a kernel update **resets these AIO lines**.
> Restore them from `config.txt.bak` (or re-flash) afterwards. See
> [MAINTAINING.md](MAINTAINING.md).

## Layout

```
build.sh                Main build script (pulls in the self-built kernel)
lib/common.sh           Shared helpers (logging, dependency checks, cleanup)
config/
  boot/config.txt       Boot config for uConsole CM4
  boot/cmdline.txt      Kernel command line
  overlays/             Place extra .dtbo files here (optional)
scripts/
  build-kernel.sh       Cross-build ak-rex/ClockworkPi-linux (rpi-6.12.y)
  customize.sh          In-chroot customization (locale, NetworkManager, etc.)
  collect-logs.sh       Debug helper to pull boot logs off a booted SD card
  package-kernel.sh     Package kernel artifacts into a release tarball
  update.sh             On-device kernel/boot updater (no re-flash)
cache/                  Downloaded tarballs (gitignored)
kernel/                 Kernel build artifacts out/ modules/ (gitignored)
```

## About the kernel

The uConsole's DSI panel (cwu50), PMU, backlight, etc. do not work with the
stock Arch kernel. In addition, **the 2026-and-later new batch changed the panel
spec**, and kernels without new-panel support show horizontal lines / garbled /
black (a known issue on the ClockworkPi forum; the new panel uses GPIO8 as its
`id_gpio`, etc.).

This repo cross-builds **ak-rex/ClockworkPi-linux `rpi-6.12.y`** (the tree Rex
uses for the official images) from source. The key is the `panel-cwu50` driver:

```c
ctx->id_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_IN);
ctx->is_new_panel = gpiod_get_value_cansleep(ctx->id_gpio);
...
if (ctx->is_new_panel) cwu50_init_sequence2(ctx);  /* new batch */
else                   cwu50_init_sequence(ctx);   /* old batch */
```

- `scripts/build-kernel.sh` builds `bcm2711_defconfig` inside docker.
- It emits `kernel8.img`, dtb, overlays (including
  `clockworkpi-uconsole-cm4.dtbo`), and modules.
- `build.sh` deploys them as `/boot/kernel8-cm4.img` etc. (booted directly by
  the RPi firmware).
- No initramfs is needed (mmc/ext4 are built-in).

Use `KSRC_BRANCH` / `KDEFCONFIG` to switch the branch or defconfig.

## Status

- [x] Base image build pipeline
- [x] Boot config for uConsole CM4
- [x] Self-built new-batch-capable kernel (ak-rex 6.12.y) built and integrated
- [x] Verified on real hardware (new-batch DSI panel display) ✅ 2026-07-10

## Maintenance

For the upstream-tracking policy (ak-rex kernel / ArchLinuxARM), handling
keyring expiry, the on-hardware re-verification checklist, and the recorded
verified versions, see [MAINTAINING.md](MAINTAINING.md).

## License / Credits

The **scripts** in this repo are under the [MIT License](LICENSE) (© 2026 fabiiw05).

However, the **artifacts** that get built/downloaded follow **their own licenses**:

- **Kernel**: [ak-rex/ClockworkPi-linux](https://github.com/ak-rex/ClockworkPi-linux)
  (`rpi-6.12.y`, GPL-2.0), including the new-batch-capable `panel-cwu50`.
- **rootfs**: the licenses of the individual [Arch Linux ARM](https://archlinuxarm.org/)
  packages.

Credits: [ClockworkPi](https://www.clockworkpi.com/) /
[ak-rex](https://github.com/ak-rex) (maintaining the uConsole kernel tree) /
[Arch Linux ARM](https://archlinuxarm.org/).
