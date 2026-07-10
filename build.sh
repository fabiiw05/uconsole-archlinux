#!/usr/bin/env bash
#
# Arch Linux ARM (aarch64) SD-card image builder for the ClockworkPi uConsole (CM4).
#
#   sudo ./build.sh
#
# Most settings can be overridden via environment variables (see README).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- Settings ----------------------------------------------------------
IMG_SIZE="${IMG_SIZE:-6G}"
BOOT_SIZE="${BOOT_SIZE:-256M}"
# NOTE: bash auto-populates the builtin HOSTNAME variable, so we avoid that
# name (under sudo it would pick up the host machine's name). Use UC_HOSTNAME.
UC_HOSTNAME="${UC_HOSTNAME:-uconsole}"
TIMEZONE="${TIMEZONE:-Asia/Tokyo}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TARBALL_URL="${TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out}"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/cache}"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/work}"
SKIP_CHROOT="${SKIP_CHROOT:-}"

# uConsole kernel (ak-rex/ClockworkPi-linux, rpi-6.12.y, built from source).
# It carries new-batch LCD panel support (panel-cwu50 id_gpio detection +
# init_sequence2); without it the new panel shows horizontal lines / garbled.
# scripts/build-kernel.sh emits artifacts into kernel/out and kernel/modules.
KDIR="${KDIR:-${SCRIPT_DIR}/kernel}"
KERNEL_OUT="${KDIR}/out"
KERNEL_MODULES="${KDIR}/modules"

IMG_NAME="uconsole-archlinux-$(date +%Y%m%d).img"
IMG_PATH="${OUT_DIR}/${IMG_NAME}"
TARBALL_PATH="${CACHE_DIR}/$(basename "${TARBALL_URL}")"
ROOT_MNT="${WORK_DIR}/root"

# --- Prerequisite checks -----------------------------------------------
require_root
require_cmds sfdisk losetup mkfs.vfat mkfs.ext4 bsdtar
if command -v wget >/dev/null 2>&1; then DL=wget; \
elif command -v curl >/dev/null 2>&1; then DL=curl; \
else die "wget or curl is required"; fi

mkdir -p "${OUT_DIR}" "${CACHE_DIR}" "${WORK_DIR}"

# --- 1. Fetch base tarball ---------------------------------------------
fetch_tarball() {
  if [[ -f "${TARBALL_PATH}" ]]; then
    ok "tarball already cached: ${TARBALL_PATH}"
    return
  fi
  log "fetching base tarball: ${TARBALL_URL}"
  local tmp="${TARBALL_PATH}.part"
  if [[ "${DL}" == wget ]]; then
    wget -O "${tmp}" "${TARBALL_URL}"
  else
    curl -fL -o "${tmp}" "${TARBALL_URL}"
  fi
  mv "${tmp}" "${TARBALL_PATH}"

  # Verify md5 if available (skip if it cannot be fetched).
  local md5url="${TARBALL_URL}.md5" md5file="${TARBALL_PATH}.md5"
  if { [[ "${DL}" == wget ]] && wget -qO "${md5file}" "${md5url}"; } ||
     { [[ "${DL}" == curl ]] && curl -fsL -o "${md5file}" "${md5url}"; }; then
    log "verifying md5"
    ( cd "${CACHE_DIR}" && md5sum -c "$(basename "${md5file}")" ) \
      || die "md5 verification failed"
    ok "md5 verification OK"
  else
    warn "md5 unavailable; skipping verification"
  fi
}

# --- 2. Create image and partitions ------------------------------------
LOOPDEV=""
create_image() {
  log "creating empty image: ${IMG_PATH} (${IMG_SIZE})"
  rm -f "${IMG_PATH}"
  truncate -s "${IMG_SIZE}" "${IMG_PATH}"

  log "creating partition table (MBR: FAT32 boot + ext4 root)"
  # p1: FAT32 (type c, bootable) / p2: Linux (type 83), rest of the disk
  sfdisk "${IMG_PATH}" <<EOF
label: dos
unit: sectors
start=2048, size=${BOOT_SIZE}, type=c, bootable
type=83
EOF

  log "attaching loop device"
  LOOPDEV="$(losetup -f --show -P "${IMG_PATH}")"
  push_cleanup "losetup -d '${LOOPDEV}'"
  [[ -b "${LOOPDEV}p1" && -b "${LOOPDEV}p2" ]] \
    || die "partition devices not found (${LOOPDEV}p1/p2)"

  log "creating filesystems (BOOT=vfat, ROOT=ext4)"
  mkfs.vfat -F 32 -n BOOT "${LOOPDEV}p1" >/dev/null
  mkfs.ext4 -q -L ROOT "${LOOPDEV}p2"
}

# --- 3. Extract tarball ------------------------------------------------
extract_rootfs() {
  log "mounting filesystems"
  mkdir -p "${ROOT_MNT}"
  mount "${LOOPDEV}p2" "${ROOT_MNT}"
  push_cleanup "umount -Rl '${ROOT_MNT}'"
  mkdir -p "${ROOT_MNT}/boot"
  mount "${LOOPDEV}p1" "${ROOT_MNT}/boot"

  log "extracting base rootfs (this takes a few minutes)"
  bsdtar -xpf "${TARBALL_PATH}" -C "${ROOT_MNT}"
  sync
}

# --- 4. Apply uConsole configuration -----------------------------------
apply_config() {
  log "applying uConsole boot configuration"
  install -m 0644 "${SCRIPT_DIR}/config/boot/config.txt"  "${ROOT_MNT}/boot/config.txt"
  install -m 0644 "${SCRIPT_DIR}/config/boot/cmdline.txt" "${ROOT_MNT}/boot/cmdline.txt"

  # Copy overlays/*.dtbo if present.
  shopt -s nullglob
  local dtbos=("${SCRIPT_DIR}"/config/overlays/*.dtbo)
  shopt -u nullglob
  if ((${#dtbos[@]})); then
    log "installing extra overlays: ${#dtbos[@]}"
    mkdir -p "${ROOT_MNT}/boot/overlays"
    install -m 0644 "${dtbos[@]}" "${ROOT_MNT}/boot/overlays/"
  fi
  # kernel8-cm4.img / clockworkpi-uconsole-cm4 overlay / dtb / modules are
  # placed by install_kernel() from our build artifacts (kernel/out, kernel/modules).

  # Declare boot explicitly in /etc/fstab.
  cat > "${ROOT_MNT}/etc/fstab" <<'EOF'
# <file system> <dir>  <type>  <options>          <dump> <pass>
/dev/mmcblk0p1  /boot  vfat    defaults           0      0
EOF

  echo "${UC_HOSTNAME}" > "${ROOT_MNT}/etc/hostname"
}

# --- 4.5 Install our self-built kernel ---------------------------------
# Deploy the kernel8.img / dtb / overlays / modules produced by
# scripts/build-kernel.sh directly into the rootfs. config.txt references
# kernel=kernel8-cm4.img.
install_kernel() {
  if [[ ! -f "${KERNEL_OUT}/kernel8.img" ]]; then
    die "self-built kernel missing. Run ./scripts/build-kernel.sh first (${KERNEL_OUT}/kernel8.img required)"
  fi
  local kver; kver="$(cat "${KERNEL_OUT}/kver.txt" 2>/dev/null || true)"
  [[ -n "${kver}" ]] || die "cannot read kver.txt (incomplete build)"
  log "installing self-built kernel (kver=${kver})"

  # Kernel image (matches kernel=kernel8-cm4.img in config.txt).
  install -m 0644 "${KERNEL_OUT}/kernel8.img" "${ROOT_MNT}/boot/kernel8-cm4.img"

  shopt -s nullglob
  # dtb
  local dtbs=("${KERNEL_OUT}"/*.dtb)
  ((${#dtbs[@]})) && install -m 0644 "${dtbs[@]}" "${ROOT_MNT}/boot/"
  # overlays (includes clockworkpi-uconsole-cm4.dtbo)
  mkdir -p "${ROOT_MNT}/boot/overlays"
  local ovls=("${KERNEL_OUT}"/overlays/*.dtbo)
  ((${#ovls[@]})) && install -m 0644 "${ovls[@]}" "${ROOT_MNT}/boot/overlays/"
  [[ -f "${KERNEL_OUT}/overlays/README" ]] \
    && install -m 0644 "${KERNEL_OUT}/overlays/README" "${ROOT_MNT}/boot/overlays/"
  shopt -u nullglob

  # modules (already modules_install'd; relative paths in modules.dep stay valid)
  [[ -d "${KERNEL_MODULES}/lib/modules/${kver}" ]] \
    || die "modules not found: ${KERNEL_MODULES}/lib/modules/${kver}"
  mkdir -p "${ROOT_MNT}/usr/lib/modules"
  cp -a "${KERNEL_MODULES}/lib/modules/${kver}" "${ROOT_MNT}/usr/lib/modules/"

  ok "kernel installed: /boot/kernel8-cm4.img + overlays + /usr/lib/modules/${kver}"
}

# --- 5. chroot customization -------------------------------------------
customize_chroot() {
  if [[ -n "${SKIP_CHROOT}" ]]; then
    warn "SKIP_CHROOT is set; skipping chroot customization"
    return
  fi
  local qemu; qemu="$(command -v qemu-aarch64-static || true)"
  if [[ -z "${qemu}" ]]; then
    warn "qemu-aarch64-static not found; skipping chroot customization"
    warn "run the equivalent of scripts/customize.sh manually after first boot"
    return
  fi

  log "customizing in chroot (qemu-user-static)"
  install -Dm755 "${qemu}" "${ROOT_MNT}/usr/bin/$(basename "${qemu}")"

  # Set up pseudo filesystems and DNS.
  mount -t proc  /proc            "${ROOT_MNT}/proc"
  mount --rbind  /sys             "${ROOT_MNT}/sys"
  mount --rbind  /dev             "${ROOT_MNT}/dev"
  # IMPORTANT: make the rbind mounts private. On systemd hosts / is rshared,
  # so without this the cleanup's recursive umount propagates to the host and
  # unmounts the host's /dev/pts (devpts), breaking sudo with
  # "unable to allocate pty".
  mount --make-rprivate "${ROOT_MNT}/sys"
  mount --make-rprivate "${ROOT_MNT}/dev"
  # Use lazy (-l): even if a process started inside the chroot (e.g. gpg-agent)
  # holds /dev/pts busy, this still detaches reliably.
  push_cleanup "umount -Rl '${ROOT_MNT}/proc' '${ROOT_MNT}/sys' '${ROOT_MNT}/dev' 2>/dev/null || true"
  cp --remove-destination /etc/resolv.conf "${ROOT_MNT}/etc/resolv.conf"

  install -m 0755 "${SCRIPT_DIR}/scripts/customize.sh" "${ROOT_MNT}/root/customize.sh"
  chroot "${ROOT_MNT}" /usr/bin/env \
      UC_HOSTNAME="${UC_HOSTNAME}" TIMEZONE="${TIMEZONE}" LOCALE="${LOCALE}" \
      /bin/bash /root/customize.sh
  rm -f "${ROOT_MNT}/root/customize.sh"

  # Stop leftover processes (e.g. gpg-agent) or the following umount stays busy.
  chroot "${ROOT_MNT}" /usr/bin/gpgconf --kill all 2>/dev/null || true
  kill_chroot_procs
}

# Kill processes whose root is under ROOT_MNT (cleans up gpg-agent, etc.).
kill_chroot_procs() {
  local p rootlink
  for p in /proc/[0-9]*; do
    rootlink="$(readlink "${p}/root" 2>/dev/null)" || continue
    if [[ "${rootlink}" == "${ROOT_MNT}" || "${rootlink}" == "${ROOT_MNT}/"* ]]; then
      kill "${p##*/}" 2>/dev/null || true
    fi
  done
}

# --- 5.5 Re-apply and verify boot config -------------------------------
# With the self-built-kernel approach there is no pacman .install hook to clobber
# config.txt, but re-apply it after chroot to guarantee consistency.
# No initramfs is needed (mmc/ext4 are built-in).
reapply_boot_config() {
  log "re-applying and verifying boot config (config.txt / cmdline.txt)"
  install -m 0644 "${SCRIPT_DIR}/config/boot/config.txt"  "${ROOT_MNT}/boot/config.txt"
  install -m 0644 "${SCRIPT_DIR}/config/boot/cmdline.txt" "${ROOT_MNT}/boot/cmdline.txt"

  [[ -f "${ROOT_MNT}/boot/kernel8-cm4.img" ]] \
    || warn "kernel8-cm4.img not in /boot (install_kernel may have failed)"
  [[ -f "${ROOT_MNT}/boot/overlays/clockworkpi-uconsole-cm4.dtbo" ]] \
    || warn "clockworkpi-uconsole-cm4.dtbo not in overlays (new panel may not work)"
}

# --- 6. Finalize -------------------------------------------------------
finalize() {
  sync
  ok "image build complete: ${IMG_PATH}"
  log "example write to SD card:"
  printf '    sudo dd if=%s of=/dev/sdX bs=4M conv=fsync status=progress\n' "${IMG_PATH}"
}

main() {
  fetch_tarball
  create_image
  extract_rootfs
  apply_config
  # IMPORTANT: run customize_chroot (which removes linux-aarch64) BEFORE
  # install_kernel. In the reverse order, `pacman -Rdd linux-aarch64` would
  # delete the /boot/bcm2711-rpi-cm4.dtb etc. that install_kernel placed (those
  # paths are owned by linux-aarch64), leaving the device unbootable due to a
  # missing DTB (overlays survive since they are unowned, so only the dtb goes).
  customize_chroot
  install_kernel
  reapply_boot_config
  finalize
}

main "$@"
