English | [日本語](MAINTAINING.ja.md)

# Maintaining uconsole-archlinux

This is the maintenance runbook: what has to be kept up to date, the recurring
Arch-specific operational gotchas, and the recorded versions that were verified
on real hardware.

## Verified versions

The combination below was cross-built and verified booting on real hardware
(new-batch DSI panel). When bumping anything, update this table after a fresh
on-hardware re-verification (see the checklist below).

| Component        | Value                                                        |
| ---------------- | ------------------------------------------------------------ |
| Kernel repo      | `ak-rex/ClockworkPi-linux`                                   |
| Kernel branch    | `rpi-6.12.y`                                                 |
| Kernel commit    | `0234e320bec7748fc6f1fb6904a055de10f0a727` (2026-07-05)      |
| Kernel release   | `6.12.94-v8+`                                                |
| Base tarball     | `ArchLinuxARM-rpi-aarch64-latest.tar.gz` (fetched 2026-06-06) |
| Base tarball md5 | `fd593833765dd6a09f8835010cc1e114`                          |
| Build image      | `ubuntu:24.04` (digest not pinned)                          |
| HW verified      | 2026-07-10 (new-batch panel)                                |

> Nothing is force-pinned in the build. `build-kernel.sh` clones the branch
> **HEAD**, `build.sh` fetches the **rolling** `-latest` tarball, and docker
> pulls the rolling `ubuntu:24.04`. This table is the record of what actually
> worked; use it to reproduce or bisect when a fresh build misbehaves.

## What needs ongoing maintenance

### 1. Upstream kernel (the biggest cost)

`build-kernel.sh` runs `git clone --depth 1 --branch rpi-6.12.y`, i.e. the
branch **HEAD**. Upstream changes — especially in
`drivers/gpu/drm/panel/panel-cwu50.c` (old/new panel detection) — take effect
immediately.

Risks: upstream force-push / branch deletion, `rpi-6.12.y` reaching EOL or moving
to a newer branch, panel-driver regressions. Every kernel bump requires an
on-hardware re-verification (below). Record the working commit in the table above.

The `.github/workflows/upstream-watch.yml` job checks the branch HEAD weekly and
opens an issue when it drifts from the recorded commit.

### 2. Arch Linux ARM base (rolling)

**Keyring expiry is the most common operational failure.** In `customize.sh`,
`pacman -Sy` (NetworkManager/sudo) can fail with signature errors when the
keyring baked into the base tarball is too old. `customize.sh` already refreshes
`archlinuxarm-keyring archlinux-keyring` before installing packages; if it still
fails, see the keyring section below.

Also watch for: repository moves / partial-upgrade breakage, and the risk of the
ALARM project itself stalling. If a mirror or the whole `-latest` URL becomes
unavailable, override `TARBALL_URL` with an alternate source.

### 3. On-hardware re-verification (cannot be automated — the real cost)

CI cannot replace this. After any kernel or base bump, flash and verify on a real
uConsole. This is the fundamental maintenance cost. **The bar for cutting a
release is passing this checklist.**

Re-verification checklist:

- [ ] Boots to userspace (no black screen / hang before login).
- [ ] DSI panel displays correctly — ideally on **both old and new batch**
      panels (this is the whole point of the ak-rex kernel).
- [ ] NetworkManager is up (`nmcli` / can connect Wi-Fi).
- [ ] Audio works.
- [ ] `scripts/collect-logs.sh /dev/sdX` yields a fresh journal (see the caveat
      below), with no alarming errors in `dmesg.txt` / `journal-warn.txt`.

> Caveat: the ALARM base tarball ships a baked-in journal from *its* build host,
> so an "empty / no new boot" result from `collect-logs.sh` means the device
> never reached userspace — not that logging is broken.

### 4. Toolchain / environment drift

`ubuntu:24.04` (docker), `qemu-user-static` + binfmt, and the host's
`util-linux` (losetup/sfdisk) / `bsdtar`. These rarely break compatibility, but
a bump can. Requests to build on non-Arch hosts may also arrive (dependency
command names differ across distros).

## Arch-specific operations

### Keyring

Symptoms: `signature is unknown trust` / `invalid or corrupted package`.
Fix (prefer this over the slow `pacman-key --refresh-keys`):

```sh
pacman -Sy archlinuxarm-keyring archlinux-keyring
# if still failing:
pacman-key --init && pacman-key --populate archlinuxarm
```

`customize.sh` does the first step automatically before installing packages.

### Rolling updates vs. the self-built kernel

`linux-aarch64` and `uboot-raspberrypi` are removed in the chroot, so a later
on-device `pacman -Syu` will not normally reinstall them. As belt-and-suspenders,
`customize.sh` writes `IgnorePkg = linux-aarch64 uboot-raspberrypi` into
`/etc/pacman.conf` so a dependency or firmware update cannot pull them back and
clobber the `/boot` setup. Firmware (`raspberrypi-bootloader`) updates can still
change `/boot`; re-check after a large upgrade.

### pacman sandbox / Landlock

Symptom on the device: `pacman -Syu` dies with `restricting filesystem access
failed because Landlock is not supported by the kernel!`. Our self-built kernel
(`bcm2711_defconfig`) has no `CONFIG_SECURITY_LANDLOCK`, so pacman 7's download
sandbox cannot start. `customize.sh` writes `DisableSandbox` into the
`[options]` section of `/etc/pacman.conf`, so shipped images are unaffected.

This drops only the network-facing downloader's isolation; GPG signature
verification (`SigLevel`) still applies, so package integrity is unchanged. To
restore the sandbox instead, a kernel rebuild with `CONFIG_SECURITY_LANDLOCK=y`
would be required (not enabled by the defconfig). For an already-flashed device
that predates this change, add `DisableSandbox` under `[options]` by hand.

### Tracking ALARM news

Watch the front-page announcements and forum on
[archlinuxarm.org](https://archlinuxarm.org/), and
[archlinuxarm/PKGBUILDs](https://github.com/archlinuxarm/PKGBUILDs) on GitHub.

## Future directions

- **Package the kernel as a PKGBUILD** instead of file-injection. Under pacman
  management, on-device kernel updates and rollback protection become clean.
  This is the "proper Arch" approach; larger effort, out of current scope.
- **Release distribution.** To avoid making everyone run a 30-60 min build,
  publish only re-verified images (xz-compressed) on GitHub Releases with the
  verified-version table attached. Mind the ~6G image size.
- **Version pinning.** If reproducibility matters, thread `KSRC_COMMIT` through
  `build-kernel.sh` and a versioned `TARBALL_URL` through `build.sh`, then pin
  the values in the table above.

## Cutting a release

1. Bump what needs bumping (kernel commit, base tarball, etc.).
2. `bash -n build.sh scripts/*.sh lib/*.sh` and `shellcheck` are green (CI does
   this on every push/PR).
3. Full build: `./scripts/build-kernel.sh` then `sudo ./build.sh`.
4. Flash and pass the on-hardware re-verification checklist above.
5. Update the verified-versions table (both this file and `MAINTAINING.ja.md`).
6. (Optional) Upload the xz-compressed image to GitHub Releases.
