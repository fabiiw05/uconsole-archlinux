#!/usr/bin/env bash
#
# Collect boot logs from the SD card of a uConsole that has booted at least once.
# (The image must have persistent journald = this repo's current build.sh.)
#
#   sudo ./scripts/collect-logs.sh /dev/sdX
#
# Mounts the second partition (root) and gathers journal / dmesg / related info
# into ./logs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

DEV="${1:-}"
[[ -n "${DEV}" ]] || die "usage: sudo $0 /dev/sdX  (e.g. /dev/sdb)"
require_root

# Determine the partition name (/dev/sdb -> /dev/sdb2, /dev/mmcblk0 -> /dev/mmcblk0p2)
if [[ "${DEV}" =~ [0-9]$ ]]; then ROOTPART="${DEV}p2"; else ROOTPART="${DEV}2"; fi
[[ -b "${ROOTPART}" ]] || die "root partition not found: ${ROOTPART}"

MNT="$(mktemp -d)"
OUT="${REPO_DIR}/logs"
mkdir -p "${OUT}"
cleanup() { umount -Rl "${MNT}" 2>/dev/null || true; rmdir "${MNT}" 2>/dev/null || true; }
trap cleanup EXIT

log "mounting root partition: ${ROOTPART}"
mount -o ro "${ROOTPART}" "${MNT}"

if [[ -d "${MNT}/var/log/journal" ]]; then
  log "collecting journal"
  cp -a "${MNT}/var/log/journal" "${OUT}/journal"
  if command -v journalctl >/dev/null; then
    journalctl -D "${MNT}/var/log/journal" --no-pager > "${OUT}/journal-all.txt" 2>&1 || true
    journalctl -D "${MNT}/var/log/journal" --no-pager -k > "${OUT}/dmesg.txt" 2>&1 || true
    journalctl -D "${MNT}/var/log/journal" --no-pager -p warning \
      > "${OUT}/journal-warn.txt" 2>&1 || true
  fi
  ok "collected into logs/ (journal-all.txt, dmesg.txt, journal-warn.txt)"
else
  warn "${MNT}/var/log/journal is missing (image predates persistence, or never booted)"
  warn "rebuild with the current build.sh, reflash, boot once, then rerun this"
fi

# Auxiliary info
{
  echo "### /etc/hostname"; cat "${MNT}/etc/hostname" 2>/dev/null
  echo; echo "### uname (modules dir)"; ls "${MNT}/usr/lib/modules" 2>/dev/null
  echo; echo "### /etc/fstab"; cat "${MNT}/etc/fstab" 2>/dev/null
} > "${OUT}/system-info.txt" 2>&1

ok "done: ${OUT}"
