#!/usr/bin/env bash
#
# Update the self-built kernel + boot config on an ALREADY-RUNNING uConsole,
# without re-flashing the SD card. Pulls a release tarball produced by
# scripts/package-kernel.sh from GitHub Releases and installs it in place.
#
#   sudo ./scripts/update.sh                 # install the latest release
#   sudo ./scripts/update.sh --tag v20260710 # install a specific release
#   sudo ./scripts/update.sh --file pkg.tgz  # install a local tarball (offline)
#   sudo ./scripts/update.sh --force         # reinstall even if up to date
#
# Only the kernel and boot config are handled here; update the base Arch Linux
# ARM system separately with `sudo pacman -Syu`.
#
# This installs only PUBLISHED, hardware-verified releases (never a branch HEAD);
# see MAINTAINING.md for the verification gate before a release is cut.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# --- Settings (overridable via environment) ----------------------------
REPO_SLUG="${REPO_SLUG:-fabiiw05/uconsole-archlinux}"
ASSET_NAME="uconsole-kernel.tar.gz"
SIDECAR_NAME="uconsole-kernel.version"
# Target root. "" = the live "/". A directory here installs into a fake root
# (for testing without hardware); see MAINTAINING.md / the plan.
DEST_ROOT="${DEST_ROOT:-}"

TAG=""
LOCAL_FILE=""
FORCE=""

# Print the top-of-file comment banner (skip the shebang; stop at the first
# non-comment line).
usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    --tag)   TAG="${2:?--tag needs a value}"; shift 2 ;;
    --file)  LOCAL_FILE="${2:?--file needs a path}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# Root is only required for a live install; a DEST_ROOT test dir does not need it.
[[ -n "${DEST_ROOT}" ]] || require_root
require_cmds tar

BOOT="${DEST_ROOT}/boot"
MARKER="${BOOT}/uconsole-kernel.release"

# --- Downloader --------------------------------------------------------
DL=""
if [[ -z "${LOCAL_FILE}" ]]; then
  if command -v curl >/dev/null 2>&1; then DL=curl
  elif command -v wget >/dev/null 2>&1; then DL=wget
  else die "curl or wget is required to download a release (or use --file)"; fi
fi

# dl <url> <dest> : fetch a URL, return non-zero on failure (no die).
dl() {
  local url="$1" dest="$2"
  if [[ "${DL}" == curl ]]; then curl -fL --retry 3 -o "${dest}" "${url}"
  else wget -O "${dest}" "${url}"; fi
}

release_base() {
  if [[ -n "${TAG}" ]]; then
    echo "https://github.com/${REPO_SLUG}/releases/download/${TAG}"
  else
    echo "https://github.com/${REPO_SLUG}/releases/latest/download"
  fi
}

current_marker() { cat "${MARKER}" 2>/dev/null || true; }

# --- Working area ------------------------------------------------------
tmp="$(mktemp -d)"
push_cleanup "rm -rf '${tmp}'"

# --- Cheap pre-check: compare the sidecar before pulling the big tarball --
if [[ -z "${LOCAL_FILE}" && -z "${FORCE}" ]]; then
  if dl "$(release_base)/${SIDECAR_NAME}" "${tmp}/remote.version" 2>/dev/null; then
    remote_line="$(cat "${tmp}/remote.version")"
    if [[ -n "${remote_line}" && "${remote_line}" == "$(current_marker)" ]]; then
      ok "already up to date (${remote_line}); nothing to do. Use --force to reinstall."
      exit 0
    fi
  fi
fi

# --- Obtain the tarball ------------------------------------------------
tarball="${tmp}/pkg.tar.gz"
if [[ -n "${LOCAL_FILE}" ]]; then
  [[ -f "${LOCAL_FILE}" ]] || die "no such file: ${LOCAL_FILE}"
  tarball="${LOCAL_FILE}"
  log "using local tarball: ${tarball}"
else
  log "downloading ${ASSET_NAME} (${TAG:-latest}) from ${REPO_SLUG}"
  dl "$(release_base)/${ASSET_NAME}" "${tarball}" \
    || die "download failed (tag=${TAG:-latest}); check the release exists"
fi

# --- Extract and validate ----------------------------------------------
log "extracting"
mkdir -p "${tmp}/x"
tar -xzf "${tarball}" -C "${tmp}/x"
src="${tmp}/x"
[[ -f "${src}/out/kernel8.img" ]] \
  || die "tarball missing out/kernel8.img (not a uconsole-kernel package?)"

kver="$(cat "${src}/out/kver.txt" 2>/dev/null || true)"
[[ -n "${kver}" ]] || die "tarball has no out/kver.txt"
new_tag="$(grep '^tag=' "${src}/VERSION" 2>/dev/null | cut -d= -f2- || true)"
[[ -n "${new_tag}" ]] || new_tag="${TAG:-unknown}"
new_line="${new_tag} ${kver}"

if [[ -z "${FORCE}" && "${new_line}" == "$(current_marker)" ]]; then
  ok "already up to date (${new_line}); nothing to do. Use --force to reinstall."
  exit 0
fi

log "updating to: ${new_line} (currently: $(current_marker | sed 's/^$/none/'))"

# --- Back up the current boot files for rollback -----------------------
# On FAT32 /boot, so recoverable from any machine if the new kernel won't boot.
mkdir -p "${BOOT}"
for f in kernel8-cm4.img config.txt cmdline.txt; do
  [[ -f "${BOOT}/${f}" ]] && cp -a "${BOOT}/${f}" "${BOOT}/${f}.bak"
done
# The old kernel's modules live in their own /usr/lib/modules/<kver> dir and are
# intentionally left in place (a differing new kver installs alongside them).

# --- Install kernel artifacts (shared with build.sh via lib/common.sh) --
install_kernel_artifacts "${src}/out" "${src}/modules" "${DEST_ROOT}"

# --- Install boot config -----------------------------------------------
if [[ -f "${src}/boot-config/config.txt" ]]; then
  install -m 0644 "${src}/boot-config/config.txt"  "${BOOT}/config.txt"
  install -m 0644 "${src}/boot-config/cmdline.txt" "${BOOT}/cmdline.txt"
fi

# --- Regenerate module deps (best-effort; build modules.dep is already valid) --
if [[ -z "${DEST_ROOT}" ]]; then
  depmod "${kver}" 2>/dev/null || warn "depmod failed (build's modules.dep is still valid)"
else
  depmod -b "${DEST_ROOT}" "${kver}" 2>/dev/null \
    || warn "depmod -b ${DEST_ROOT} skipped (test root); build's modules.dep is used"
fi

# --- Record the installed version --------------------------------------
printf '%s\n' "${new_line}" > "${MARKER}"
sync

ok "updated to ${new_line}"
log "REBOOT to apply: sudo reboot"
log "rollback (if it won't boot): from another machine, mount the FAT32 boot"
log "  partition and restore ${BOOT#"${DEST_ROOT}"}/kernel8-cm4.img.bak -> kernel8-cm4.img"
