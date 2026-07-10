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

# --- First-boot root filesystem expansion ----------------------------
# The image is built at a fixed IMG_SIZE (e.g. 6G), so a freshly flashed SD
# card only exposes that much space regardless of its real capacity. Grow the
# root partition + ext4 to fill the whole card on the first boot, then disable
# the service (a stamp file guards it so it only runs once).
#
# Uses only tools already present in the ALARM base (sfdisk from util-linux,
# resize2fs from e2fsprogs) so it needs no extra packages and works offline.
echo "==> [chroot] installing first-boot root-fs expansion service"
cat > /usr/local/sbin/uconsole-resize-rootfs <<'RESIZE'
#!/usr/bin/env bash
# Grow the root partition and its filesystem to fill the storage device.
set -uo pipefail

ROOT_SRC="$(findmnt -no SOURCE /)"   # e.g. /dev/mmcblk0p2 or /dev/sda2
case "${ROOT_SRC}" in
  /dev/*[0-9]p[0-9]*)  # mmcblk0p2, nvme0n1p2 -> disk keeps its trailing digit
    DISK="${ROOT_SRC%p[0-9]*}"
    PART="${ROOT_SRC##*p}" ;;
  /dev/*[0-9])         # sda2 -> sda, 2
    PART="${ROOT_SRC##*[!0-9]}"
    DISK="${ROOT_SRC%"${PART}"}" ;;
  *)
    echo "uconsole-resize-rootfs: cannot parse root device '${ROOT_SRC}'" >&2
    exit 1 ;;
esac

echo "uconsole-resize-rootfs: growing ${DISK} partition ${PART}"
# ',+' = keep the start, extend the size to the end of the device.
echo ',+' | sfdisk -N "${PART}" --no-reread --force "${DISK}" || true
partx -u "${DISK}" 2>/dev/null || partprobe "${DISK}" 2>/dev/null || true

# Online-resize the mounted ext4 root. resize2fs is idempotent, so this is a
# no-op if the filesystem already fills the partition.
resize2fs "${ROOT_SRC}"
RESIZE
chmod 0755 /usr/local/sbin/uconsole-resize-rootfs

cat > /etc/systemd/system/uconsole-resize-rootfs.service <<'UNIT'
[Unit]
Description=Expand root filesystem to fill the storage on first boot
ConditionPathExists=/var/lib/uconsole-resize-rootfs.stamp
After=systemd-remount-fs.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/uconsole-resize-rootfs
# Only removed when ExecStart succeeded; a failure keeps the stamp so it
# retries on the next boot.
ExecStartPost=/usr/bin/rm -f /var/lib/uconsole-resize-rootfs.stamp
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# The stamp both arms the service (ConditionPathExists) and, once removed on
# success, prevents it from ever running again.
mkdir -p /var/lib
: > /var/lib/uconsole-resize-rootfs.stamp
systemctl enable uconsole-resize-rootfs.service || true

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
