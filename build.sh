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

# uConsole 用カーネル（ak-rex/ClockworkPi-linux, rpi-6.12.y を自前ビルド）。
# 新ロット LCD パネル対応（panel-cwu50 の id_gpio 判定 + init_sequence2）が
# 入っており、これが無いと新パネルは横線・崩れで表示されない。
# scripts/build-kernel.sh が kernel/out と kernel/modules に成果物を出す。
KDIR="${KDIR:-${SCRIPT_DIR}/kernel}"
KERNEL_OUT="${KDIR}/out"
KERNEL_MODULES="${KDIR}/modules"

IMG_NAME="uconsole-archlinux-$(date +%Y%m%d).img"
IMG_PATH="${OUT_DIR}/${IMG_NAME}"
TARBALL_PATH="${CACHE_DIR}/$(basename "${TARBALL_URL}")"
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
  # install_kernel() が自前ビルド成果物 (kernel/out, kernel/modules) から配置する。

  # /etc/fstab に boot を明示
  cat > "${ROOT_MNT}/etc/fstab" <<'EOF'
# <file system> <dir>  <type>  <options>          <dump> <pass>
/dev/mmcblk0p1  /boot  vfat    defaults           0      0
EOF

  echo "${UC_HOSTNAME}" > "${ROOT_MNT}/etc/hostname"
}

# --- 4.5 自前ビルドのカーネルを配置 -----------------------------------
# scripts/build-kernel.sh が出力した kernel8.img / dtb / overlays / modules
# を rootfs に直接展開する。config.txt は kernel=kernel8-cm4.img を参照。
install_kernel() {
  if [[ ! -f "${KERNEL_OUT}/kernel8.img" ]]; then
    die "自前カーネルが未ビルドです。先に ./scripts/build-kernel.sh を実行してください（${KERNEL_OUT}/kernel8.img が必要）"
  fi
  local kver; kver="$(cat "${KERNEL_OUT}/kver.txt" 2>/dev/null || true)"
  [[ -n "${kver}" ]] || die "kver.txt が読めません（ビルドが不完全）"
  log "自前カーネルを配置 (kver=${kver})"

  # カーネル本体（config.txt の kernel=kernel8-cm4.img に合わせる）
  install -m 0644 "${KERNEL_OUT}/kernel8.img" "${ROOT_MNT}/boot/kernel8-cm4.img"

  shopt -s nullglob
  # dtb
  local dtbs=("${KERNEL_OUT}"/*.dtb)
  ((${#dtbs[@]})) && install -m 0644 "${dtbs[@]}" "${ROOT_MNT}/boot/"
  # overlays（clockworkpi-uconsole-cm4.dtbo を含む）
  mkdir -p "${ROOT_MNT}/boot/overlays"
  local ovls=("${KERNEL_OUT}"/overlays/*.dtbo)
  ((${#ovls[@]})) && install -m 0644 "${ovls[@]}" "${ROOT_MNT}/boot/overlays/"
  [[ -f "${KERNEL_OUT}/overlays/README" ]] \
    && install -m 0644 "${KERNEL_OUT}/overlays/README" "${ROOT_MNT}/boot/overlays/"
  shopt -u nullglob

  # modules（modules_install 済み。modules.dep 等の相対パスはそのまま有効）
  [[ -d "${KERNEL_MODULES}/lib/modules/${kver}" ]] \
    || die "モジュールが見つかりません: ${KERNEL_MODULES}/lib/modules/${kver}"
  mkdir -p "${ROOT_MNT}/usr/lib/modules"
  cp -a "${KERNEL_MODULES}/lib/modules/${kver}" "${ROOT_MNT}/usr/lib/modules/"

  ok "カーネル配置完了: /boot/kernel8-cm4.img + overlays + /usr/lib/modules/${kver}"
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

# --- 5.5 ブート設定の再適用・検証 -------------------------------------
# 自前カーネル方式では pacman の .install フックが無いため config.txt を
# 壊す要因は無いが、chroot 後に念のため再適用して整合を保証する。
# 自前カーネルは initramfs 不要（mmc/ext4 はビルトイン）。
reapply_boot_config() {
  log "ブート設定を再適用・検証 (config.txt / cmdline.txt)"
  install -m 0644 "${SCRIPT_DIR}/config/boot/config.txt"  "${ROOT_MNT}/boot/config.txt"
  install -m 0644 "${SCRIPT_DIR}/config/boot/cmdline.txt" "${ROOT_MNT}/boot/cmdline.txt"

  [[ -f "${ROOT_MNT}/boot/kernel8-cm4.img" ]] \
    || warn "kernel8-cm4.img が /boot にありません（install_kernel が失敗した可能性）"
  [[ -f "${ROOT_MNT}/boot/overlays/clockworkpi-uconsole-cm4.dtbo" ]] \
    || warn "clockworkpi-uconsole-cm4.dtbo が overlays にありません（新パネルが動かない可能性）"
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
  create_image
  extract_rootfs
  apply_config
  install_kernel
  customize_chroot
  reapply_boot_config
  finalize
}

main "$@"
