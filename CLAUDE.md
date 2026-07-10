# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A set of Bash scripts that build a bootable **Arch Linux ARM (aarch64) SD-card image for the ClockworkPi uConsole (CM4)**. There is no application code — everything assembles a disk image on a Linux host.

**Language convention:** code comments and script logs/`echo` output are in **English**; match that style. User-facing docs are **bilingual, split by file**: English is the default (`README.md`, `MAINTAINING.md`) and Japanese lives in `*.ja.md` (`README.ja.md`, `MAINTAINING.ja.md`), cross-linked with a language switcher at the top. Keep both language versions of a doc in sync when editing.

## Build & flash (two stages, order matters)

The build is split into two independent stages. Stage 1 must run before stage 2.

```sh
# Stage 1: cross-compile the kernel in Docker (non-root). ~30–60 min.
#   Outputs kernel/out/ (kernel8.img, *.dtb, overlays/) and kernel/modules/.
./scripts/build-kernel.sh

# Stage 2: assemble the image (root; uses loop devices + qemu chroot).
#   Dies immediately if kernel/out/kernel8.img is missing.
sudo ./build.sh

# Flash (verify the device name — wrong device destroys another drive):
sudo dd if=out/uconsole-archlinux-YYYYMMDD.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Debug a device that has booted at least once (mounts p2 read-only, pulls journal/dmesg to `./logs/`):

```sh
sudo ./scripts/collect-logs.sh /dev/sdX
```

There is **no test/lint framework**. Sanity-check scripts with `bash -n build.sh scripts/*.sh`.

Regenerated / gitignored (never commit): `kernel/`, `cache/`, `out/`, `work/`, `logs/`.

Key env overrides: `KSRC_BRANCH`/`KDEFCONFIG`/`JOBS`/`BUILD_IMAGE` (build-kernel.sh); `IMG_SIZE`/`UC_HOSTNAME`/`TIMEZONE`/`LOCALE`/`SKIP_CHROOT`/`TARBALL_URL` (build.sh).

## Architecture & non-obvious invariants

`build.sh` orchestrates (see `main()`): fetch ALARM `rpi-aarch64` tarball → partition/loop image (FAT32 boot + ext4 root) → extract rootfs → `apply_config` → `customize_chroot` → `install_kernel` → `reapply_boot_config`. `scripts/*.sh` and `build.sh` all source `lib/common.sh` (`log/ok/warn/die`, `require_root`, `require_cmds`, a `push_cleanup`/trap-based cleanup stack for loop devices and mounts, and `install_kernel_artifacts <out> <modules> <dest_root>`).

**On-device updates:** the kernel is file-injected, not a pacman package, so existing installs get kernel/boot updates via `scripts/update.sh` (on the device), which installs a GitHub Release tarball produced by `scripts/package-kernel.sh` using the *same* `install_kernel_artifacts` helper as `build.sh` (so the two paths can't drift). Only published, hardware-verified releases are pulled — never a branch HEAD. Base OS updates are separate (`pacman -Syu`).

Understand these before editing the pipeline — they are landmines that caused real, hard-to-debug failures:

- **`customize_chroot` MUST run before `install_kernel`.** `customize.sh` runs `pacman -Rdd linux-aarch64` (and `uboot-raspberrypi`) in the chroot. `linux-aarch64` *owns* `/boot` DTB paths (e.g. `bcm2711-rpi-cm4.dtb`). If `install_kernel` placed our DTBs first, the removal deletes them → no CM4 device tree → the kernel hangs before userspace (black screen, no journal; overlays survive because they aren't owned by `linux-aarch64`). `-Rdd` is used deliberately (not `-Rns`) to avoid cascade-removing `raspberrypi-bootloader` firmware.

- **The chroot rbind mounts are made `--make-rprivate`** (in `customize_chroot`). On systemd hosts `/` is rshared, so without this the cleanup's recursive `umount` **propagates to the host** and unmounts the host's `/dev/pts`, breaking `sudo` with `unable to allocate pty`. Do not remove this.

- **Boot bypasses U-Boot.** The RPi VideoCore firmware reads `config/boot/config.txt`; `kernel=kernel8-cm4.img` + `arm_64bit=1` makes it load our arm64 `Image` directly (`install_kernel` copies `kernel/out/kernel8.img` → `/boot/kernel8-cm4.img`). `uboot-raspberrypi` and `linux-aarch64` are removed in the chroot. **No initramfs** — mmc/ext4 are built-in in `bcm2711_defconfig`; panel/vc4/backlight are modules loaded after root mount.

- **The kernel choice is load-bearing domain knowledge, not incidental.** `build-kernel.sh` builds **ak-rex/ClockworkPi-linux `rpi-6.12.y`** (Rex's tree, used by the official images) specifically because the uConsole's **2026+ new screen batch** changed the DSI panel. Only a kernel whose `panel-cwu50` driver auto-detects old vs new panels via `id_gpio` (`is_new_panel` → `cwu50_init_sequence2()`) drives the new panel correctly; without it the panel shows horizontal lines / garbled / black under *any* userspace (console or compositor). Do not "simplify" back to a prebuilt package (e.g. OuinOuin74) — those lack the new-panel support. `build-kernel.sh` re-clones when `kernel/linux` is a different repo (guards against reusing a stale tree and silently building the wrong kernel).

- **qemu chroot quirk:** `customize.sh` runs under `qemu-aarch64-static` and uses `pacman --disable-sandbox` because Landlock is unsupported under qemu emulation.

- **The image is a fixed `IMG_SIZE` (default 6G); the SD card is filled on first boot, not at build time.** `customize.sh` installs a self-disabling systemd oneshot (`uconsole-resize-rootfs.service` + `/usr/local/sbin/uconsole-resize-rootfs`) that grows the root partition (`sfdisk -N`) and ext4 (`resize2fs`, online) to the whole device, guarded/armed by `/var/lib/uconsole-resize-rootfs.stamp` (removed only on success, so a failure retries next boot). It uses **only** util-linux + e2fsprogs (already in the ALARM base) so it runs offline with no extra package. Don't assume `df` on a fresh flash reflects the card size until after the first boot.

- **Collected logs can be misleading:** the ALARM base tarball ships a baked-in journal from *its* build host. So an "empty / no new boot" result from `collect-logs.sh` means the flashed device never reached userspace — not that logging is broken. journald persistence (`/var/log/journal`) is enabled in `customize.sh`.
