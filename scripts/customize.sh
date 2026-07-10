#!/usr/bin/env bash
#
# Initial customization run inside the chroot.
# Invoked by build.sh via qemu-aarch64-static.
# Reads the environment variables UC_HOSTNAME / TIMEZONE / LOCALE.
#
# Non-fatal steps continue on failure so the image stays usable.
set -uo pipefail

UC_HOSTNAME="${UC_HOSTNAME:-uconsole}"
TIMEZONE="${TIMEZONE:-Asia/Tokyo}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# Under qemu-user emulation, pacman's sandbox (Landlock) is unavailable and
# fails with "Landlock is not supported by the kernel", so disable it.
PAC="pacman --disable-sandbox"

echo "==> [chroot] initializing pacman keyring"
pacman-key --init          || echo "!! pacman-key --init failed (continuing)"
pacman-key --populate archlinuxarm || echo "!! populate failed (continuing)"

# Refresh the keyrings first. The ALARM base tarball ships a baked-in keyring
# that may be too old, which makes later package installs fail with signature
# errors ("signature is unknown trust" / "invalid or corrupted package").
# best-effort: continue even if this fails.
echo "==> [chroot] refreshing keyrings"
${PAC} -Sy --noconfirm --needed archlinuxarm-keyring archlinux-keyring \
  || echo "!! keyring refresh failed (continuing)"

# --- Remove stock kernel / U-Boot ------------------------------------
# Our self-built kernel (kernel8-cm4.img / overlays / modules) is already
# placed as files by build.sh's install_kernel(). Here we only remove the
# unused stock linux-aarch64 (an unused kernel8.img + modules) and
# uboot-raspberrypi (kernel8.img = U-Boot).
# -Rdd: stop the dependency cascade to protect raspberrypi-bootloader firmware.
echo "==> [chroot] removing stock kernel / U-Boot (using self-built kernel)"
for pkg in linux-aarch64 uboot-raspberrypi; do
  if pacman -Qq "${pkg}" &>/dev/null; then
    echo "   - remove ${pkg}"
    ${PAC} -Rdd --noconfirm "${pkg}" || echo "!! failed to remove ${pkg} (continuing)"
  fi
done

# Prevent a later on-device `pacman -Syu` from pulling the stock kernel / U-Boot
# back in (which would clobber our /boot setup). Pin them as ignored.
echo "==> [chroot] pinning IgnorePkg (linux-aarch64, uboot-raspberrypi)"
if ! grep -q '^IgnorePkg' /etc/pacman.conf; then
  sed -i 's/^#\s*IgnorePkg.*/IgnorePkg = linux-aarch64 uboot-raspberrypi/' /etc/pacman.conf
  grep -q '^IgnorePkg' /etc/pacman.conf \
    || echo 'IgnorePkg = linux-aarch64 uboot-raspberrypi' >> /etc/pacman.conf
fi

# Disable pacman's download sandbox on the target system too. Our self-built
# kernel (bcm2711_defconfig) has no CONFIG_SECURITY_LANDLOCK, so an on-device
# `pacman -Syu` otherwise dies with "Landlock is not supported by the kernel".
# GPG signature verification (SigLevel) is unaffected; only the network-facing
# downloader's isolation is dropped. Insert inside [options] so it takes effect.
echo "==> [chroot] disabling pacman sandbox (kernel lacks Landlock)"
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi

# Persist the journal for first-boot debugging (no display / no boot, etc.).
# Once it has booted, you can pull /var/log/journal off the SD to inspect it.
echo "==> [chroot] enabling persistent journald"
mkdir -p /var/log/journal

echo "==> [chroot] timezone: ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

echo "==> [chroot] locale: ${LOCALE}"
sed -i "s/^#\s*\(${LOCALE//./\\.} \)/\1/" /etc/locale.gen
grep -q "^${LOCALE}" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "==> [chroot] hostname: ${UC_HOSTNAME}"
echo "${UC_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${UC_HOSTNAME}.localdomain ${UC_HOSTNAME}
EOF

# Install and enable network management (NetworkManager).
# best-effort: keep the image usable even if this fails (e.g. no network).
echo "==> [chroot] installing NetworkManager"
if ${PAC} -Sy --noconfirm --needed networkmanager sudo; then
  systemctl enable NetworkManager || true
else
  echo "!! package install failed (continuing)"
fi

echo "==> [chroot] customization complete"
