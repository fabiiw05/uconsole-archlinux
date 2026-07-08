#!/usr/bin/env bash
#
# uConsole (CM4) 向け Arch Linux ARM (aarch64) SD カードイメージビルダー
#
#   sudo ./build.sh
#
# 主要な設定は環境変数で上書き可能（README 参照）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- 設定 --------------------------------------------------------------
IMG_SIZE="${IMG_SIZE:-6G}"
BOOT_SIZE="${BOOT_SIZE:-256M}"
# NOTE: bash はマシン名を組み込み変数 HOSTNAME に自動設定するため、その名前は
# 使わない（sudo 実行時にホストのマシン名を拾ってしまう）。UC_HOSTNAME を使う。
UC_HOSTNAME="${UC_HOSTNAME:-uconsole}"
TIMEZONE="${TIMEZONE:-Asia/Tokyo}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TARBALL_URL="${TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out}"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/cache}"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/work}"
SKIP_CHROOT="${SKIP_CHROOT:-}"

# uConsole 用カーネル (kernel 6.16, OuinOuin74/linux-clockwork-arch のプリビルド pkg)
# CM4 / CM5 で成果物が異なる。CM4 を既定とする。
#   https://github.com/OuinOuin74/linux-clockwork-arch/releases
KPKG_MODULE="${KPKG_MODULE:-cm4}"
KPKG_VER="${KPKG_VER:-7.0.9-1}"
KPKG_NAME="linux-rpi-clockwork-${KPKG_MODULE}-${KPKG_VER}-aarch64.pkg.tar.xz"
KPKG_URL="${KPKG_URL:-https://github.com/OuinOuin74/linux-clockwork-arch/releases/download/v${KPKG_VER%-*}/${KPKG_NAME}}"

IMG_NAME="uconsole-archlinux-$(date +%Y%m%d).img"
IMG_PATH="${OUT_DIR}/${IMG_NAME}"
TARBALL_PATH="${CACHE_DIR}/$(basename "${TARBALL_URL}")"
KPKG_PATH="${CACHE_DIR}/${KPKG_NAME}"
ROOT_MNT="${WORK_DIR}/root"

# --- 前提チェック ------------------------------------------------------
require_root
require_cmds sfdisk losetup mkfs.vfat mkfs.ext4 bsdtar
if command -v wget >/dev/null 2>&1; then DL=wget; \
elif command -v curl >/dev/null 2>&1; then DL=curl; \
else die "wget か curl が必要です"; fi

mkdir -p "${OUT_DIR}" "${CACHE_DIR}" "${WORK_DIR}"

# --- 1. ベース tarball の取得 ------------------------------------------
fetch_tarball() {
  if [[ -f "${TARBALL_PATH}" ]]; then
    ok "tarball はキャッシュ済み: ${TARBALL_PATH}"
    return
  fi
  log "ベース tarball を取得: ${TARBALL_URL}"
  local tmp="${TARBALL_PATH}.part"
  if [[ "${DL}" == wget ]]; then
    wget -O "${tmp}" "${TARBALL_URL}"
  else
    curl -fL -o "${tmp}" "${TARBALL_URL}"
  fi
  mv "${tmp}" "${TARBALL_PATH}"

  # md5 があれば検証（取得できなければスキップ）
  local md5url="${TARBALL_URL}.md5" md5file="${TARBALL_PATH}.md5"
  if { [[ "${DL}" == wget ]] && wget -qO "${md5file}" "${md5url}"; } ||
     { [[ "${DL}" == curl ]] && curl -fsL -o "${md5file}" "${md5url}"; }; then
    log "md5 を検証中"
    ( cd "${CACHE_DIR}" && md5sum -c "$(basename "${md5file}")" ) \
      || die "md5 検証に失敗しました"
    ok "md5 検証 OK"
  else
    warn "md5 が取得できないため検証をスキップ"
  fi
}

# --- 1.5 uConsole カーネル pkg の取得 ----------------------------------
fetch_kernel_pkg() {
  if [[ -f "${KPKG_PATH}" ]]; then
    ok "カーネル pkg はキャッシュ済み: ${KPKG_PATH}"
    return
  fi
  log "uConsole カーネル pkg を取得: ${KPKG_URL}"
  local tmp="${KPKG_PATH}.part"
  if [[ "${DL}" == wget ]]; then
    wget -O "${tmp}" "${KPKG_URL}"
  else
    curl -fL -o "${tmp}" "${KPKG_URL}"
  fi
  mv "${tmp}" "${KPKG_PATH}"
  ok "カーネル pkg 取得完了: ${KPKG_PATH}"
}

# --- 2. イメージ作成とパーティション ----------------------------------
LOOPDEV=""
create_image() {
  log "空イメージを作成: ${IMG_PATH} (${IMG_SIZE})"
  rm -f "${IMG_PATH}"
  truncate -s "${IMG_SIZE}" "${IMG_PATH}"

  log "パーティションテーブルを作成 (MBR: FAT32 boot + ext4 root)"
  # p1: FAT32 (type c, bootable) / p2: Linux (type 83) 残り全部
  sfdisk "${IMG_PATH}" <<EOF
label: dos
unit: sectors
start=2048, size=${BOOT_SIZE}, type=c, bootable
type=83
EOF

  log "loop デバイスに接続"
  LOOPDEV="$(losetup -f --show -P "${IMG_PATH}")"
  push_cleanup "losetup -d '${LOOPDEV}'"
  [[ -b "${LOOPDEV}p1" && -b "${LOOPDEV}p2" ]] \
    || die "パーティションデバイスが見つかりません (${LOOPDEV}p1/p2)"

  log "ファイルシステムを作成 (BOOT=vfat, ROOT=ext4)"
  mkfs.vfat -F 32 -n BOOT "${LOOPDEV}p1" >/dev/null
  mkfs.ext4 -q -L ROOT "${LOOPDEV}p2"
}

# --- 3. tarball 展開 ---------------------------------------------------
extract_rootfs() {
  log "ファイルシステムをマウント"
  mkdir -p "${ROOT_MNT}"
  mount "${LOOPDEV}p2" "${ROOT_MNT}"
  push_cleanup "umount -Rl '${ROOT_MNT}'"
  mkdir -p "${ROOT_MNT}/boot"
  mount "${LOOPDEV}p1" "${ROOT_MNT}/boot"

  log "ベース rootfs を展開中（数分かかります）"
  bsdtar -xpf "${TARBALL_PATH}" -C "${ROOT_MNT}"
  sync
}

# --- 4. uConsole 設定の適用 -------------------------------------------
apply_config() {
  log "uConsole 用ブート設定を適用"
  install -m 0644 "${SCRIPT_DIR}/config/boot/config.txt"  "${ROOT_MNT}/boot/config.txt"
  install -m 0644 "${SCRIPT_DIR}/config/boot/cmdline.txt" "${ROOT_MNT}/boot/cmdline.txt"

  # overlays/*.dtbo があればコピー
  shopt -s nullglob
  local dtbos=("${SCRIPT_DIR}"/config/overlays/*.dtbo)
  shopt -u nullglob
  if ((${#dtbos[@]})); then
    log "追加 overlay を配置: ${#dtbos[@]} 件"
    mkdir -p "${ROOT_MNT}/boot/overlays"
    install -m 0644 "${dtbos[@]}" "${ROOT_MNT}/boot/overlays/"
  fi
  # kernel8-cm4.img / clockworkpi-uconsole-cm4 overlay / dtb / modules は
  # customize.sh 内の pacman -U (linux-rpi-clockwork pkg) が配置する。

  # /etc/fstab に boot を明示
  cat > "${ROOT_MNT}/etc/fstab" <<'EOF'
# <file system> <dir>  <type>  <options>          <dump> <pass>
/dev/mmcblk0p1  /boot  vfat    defaults           0      0
EOF

  echo "${UC_HOSTNAME}" > "${ROOT_MNT}/etc/hostname"
}

# --- 4.5 カーネル pkg をチルート内へ配置 ------------------------------
# ダウンロード済みの linux-rpi-clockwork pkg を rootfs にコピーしておき、
# customize.sh (chroot 内) で pacman -U 導入する。
stage_kernel_pkg() {
  if [[ ! -f "${KPKG_PATH}" ]]; then
    warn "カーネル pkg が無い (${KPKG_PATH}) — DSI パネルは動きません"
    return
  fi
  log "カーネル pkg を rootfs に配置"
  install -m 0644 "${KPKG_PATH}" "${ROOT_MNT}/root/kernel.pkg.tar.xz"
}

# --- 5. chroot カスタマイズ -------------------------------------------
customize_chroot() {
  if [[ -n "${SKIP_CHROOT}" ]]; then
    warn "SKIP_CHROOT が設定されているため chroot カスタマイズを省略"
    return
  fi
  local qemu; qemu="$(command -v qemu-aarch64-static || true)"
  if [[ -z "${qemu}" ]]; then
    warn "qemu-aarch64-static が無いため chroot カスタマイズを省略"
    warn "初回起動後に scripts/customize.sh 相当を手動実行してください"
    return
  fi

  log "chroot でカスタマイズ (qemu-user-static)"
  install -Dm755 "${qemu}" "${ROOT_MNT}/usr/bin/$(basename "${qemu}")"

  # 疑似ファイルシステムと DNS を用意
  mount -t proc  /proc            "${ROOT_MNT}/proc"
  mount --rbind  /sys             "${ROOT_MNT}/sys"
  mount --rbind  /dev             "${ROOT_MNT}/dev"
  # lazy(-l) を付ける: chroot 内で起動した gpg-agent 等が /dev/pts を掴んで
  # busy になっても確実に外せるようにする。
  push_cleanup "umount -Rl '${ROOT_MNT}/proc' '${ROOT_MNT}/sys' '${ROOT_MNT}/dev' 2>/dev/null || true"
  cp --remove-destination /etc/resolv.conf "${ROOT_MNT}/etc/resolv.conf"

  install -m 0755 "${SCRIPT_DIR}/scripts/customize.sh" "${ROOT_MNT}/root/customize.sh"
  chroot "${ROOT_MNT}" /usr/bin/env \
      UC_HOSTNAME="${UC_HOSTNAME}" TIMEZONE="${TIMEZONE}" LOCALE="${LOCALE}" \
      /bin/bash /root/customize.sh
  rm -f "${ROOT_MNT}/root/customize.sh"

  # chroot 内で残った gpg-agent 等を停止しないと後続の umount が busy になる。
  chroot "${ROOT_MNT}" /usr/bin/gpgconf --kill all 2>/dev/null || true
  kill_chroot_procs
}

# ROOT_MNT 配下を root とするプロセスを終了させる（gpg-agent 等の掃除）。
kill_chroot_procs() {
  local p rootlink
  for p in /proc/[0-9]*; do
    rootlink="$(readlink "${p}/root" 2>/dev/null)" || continue
    [[ "${rootlink}" == "${ROOT_MNT}" || "${rootlink}" == "${ROOT_MNT}/"* ]] \
      && kill "${p##*/}" 2>/dev/null || true
  done
}

# --- 5.5 ブート設定の再適用 -------------------------------------------
# カーネル pkg の .install フック (patch_cmdline) はチルート内で findmnt を
# 使い root デバイスを推定するが、/proc はホスト由来のためホストの PARTUUID
# を書き込んでしまう。最終的に必ず自前の config.txt / cmdline.txt で上書きする。
reapply_boot_config() {
  log "ブート設定を再適用 (config.txt / cmdline.txt)"
  install -m 0644 "${SCRIPT_DIR}/config/boot/config.txt"  "${ROOT_MNT}/boot/config.txt"
  install -m 0644 "${SCRIPT_DIR}/config/boot/cmdline.txt" "${ROOT_MNT}/boot/cmdline.txt"

  # initramfs が生成されているか確認（config.txt がこれを参照している）
  local initrd="${ROOT_MNT}/boot/initramfs-linux-rpi-clockwork-${KPKG_MODULE}.img"
  if [[ -f "${initrd}" ]]; then
    ok "initramfs 確認: $(basename "${initrd}")"
  else
    warn "initramfs が見つかりません: $(basename "${initrd}")"
    warn "config.txt の initramfs 行をコメントアウトして initramfs なしで起動させます"
    sed -i 's#^initramfs #\#initramfs #' "${ROOT_MNT}/boot/config.txt"
  fi

  # 起動確認用に kernel8-cm4.img が配置されたか確認
  if [[ ! -f "${ROOT_MNT}/boot/kernel8-${KPKG_MODULE}.img" ]]; then
    warn "kernel8-${KPKG_MODULE}.img が /boot にありません。カーネル pkg 導入に失敗した可能性があります"
  fi
}

# --- 6. 仕上げ ---------------------------------------------------------
finalize() {
  sync
  ok "イメージ生成完了: ${IMG_PATH}"
  log "SD カードへの書き込み例:"
  printf '    sudo dd if=%s of=/dev/sdX bs=4M conv=fsync status=progress\n' "${IMG_PATH}"
}

main() {
  fetch_tarball
  fetch_kernel_pkg
  create_image
  extract_rootfs
  apply_config
  stage_kernel_pkg
  customize_chroot
  reapply_boot_config
  finalize
}

main "$@"
