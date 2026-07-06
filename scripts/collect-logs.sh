#!/usr/bin/env bash
#
# uConsole で一度起動したあとの SD カードから起動ログを回収する。
# （イメージは journald 永続化済みであること = 本リポジトリの現行 build.sh）
#
#   sudo ./scripts/collect-logs.sh /dev/sdX
#
# 第2パーティション(root)をマウントし、journal・dmesg・関連情報を ./logs へ集める。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

DEV="${1:-}"
[[ -n "${DEV}" ]] || die "使い方: sudo $0 /dev/sdX  (例: /dev/sdb)"
require_root

# パーティション名の決定 (/dev/sdb -> /dev/sdb2, /dev/mmcblk0 -> /dev/mmcblk0p2)
if [[ "${DEV}" =~ [0-9]$ ]]; then ROOTPART="${DEV}p2"; else ROOTPART="${DEV}2"; fi
[[ -b "${ROOTPART}" ]] || die "root パーティションが見つかりません: ${ROOTPART}"

MNT="$(mktemp -d)"
OUT="${REPO_DIR}/logs"
mkdir -p "${OUT}"
cleanup() { umount -Rl "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true; }
trap cleanup EXIT

log "root パーティションをマウント: ${ROOTPART}"
mount -o ro "${ROOTPART}" "${MNT}"

if [[ -d "${MNT}/var/log/journal" ]]; then
  log "journal を回収"
  cp -a "${MNT}/var/log/journal" "${OUT}/journal"
  if command -v journalctl >/dev/null; then
    journalctl -D "${MNT}/var/log/journal" --no-pager > "${OUT}/journal-all.txt" 2>&1 || true
    journalctl -D "${MNT}/var/log/journal" --no-pager -k > "${OUT}/dmesg.txt" 2>&1 || true
    journalctl -D "${MNT}/var/log/journal" --no-pager -p warning \
      > "${OUT}/journal-warn.txt" 2>&1 || true
  fi
  ok "logs/ に回収しました (journal-all.txt, dmesg.txt, journal-warn.txt)"
else
  warn "${MNT}/var/log/journal がありません（永続化前のイメージか、未起動）"
  warn "現行 build.sh で再ビルド→再フラッシュ→一度起動 の後に再実行してください"
fi

# 補助情報
{
  echo "### /etc/hostname"; cat "${MNT}/etc/hostname" 2>/dev/null
  echo; echo "### uname (modules dir)"; ls "${MNT}/usr/lib/modules" 2>/dev/null
  echo; echo "### /etc/fstab"; cat "${MNT}/etc/fstab" 2>/dev/null
} > "${OUT}/system-info.txt" 2>&1

ok "完了: ${OUT}"
