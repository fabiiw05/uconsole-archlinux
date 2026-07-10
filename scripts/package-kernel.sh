#!/usr/bin/env bash
#
# Package the self-built kernel into a release tarball for on-device updates.
#
#   TAG=v20260710 ./scripts/package-kernel.sh      # or: ./scripts/package-kernel.sh v20260710
#
# Bundles the artifacts from scripts/build-kernel.sh (kernel/out, kernel/modules)
# together with the repo's boot config (config/boot) into a single tarball that
# scripts/update.sh installs onto an already-running device (no re-flash).
#
# Outputs (into out/):
#   uconsole-kernel.tar.gz    the artifact (STABLE name, so the GitHub
#                             "latest release" download URL is fixed)
#   uconsole-kernel.version   sidecar: one line "<tag> <kver>" for a cheap
#                             pre-download version check by update.sh
#
# Publish with, e.g.:
#   gh release create "<tag>" out/uconsole-kernel.tar.gz out/uconsole-kernel.version
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# --- Settings (overridable via environment) ----------------------------
KDIR="${KDIR:-${REPO_DIR}/kernel}"
KERNEL_OUT="${KERNEL_OUT:-${KDIR}/out}"
KERNEL_MODULES="${KERNEL_MODULES:-${KDIR}/modules}"
OUT_DIR="${OUT_DIR:-${REPO_DIR}/out}"
BOOT_CONFIG_DIR="${REPO_DIR}/config/boot"
# Release tag: env TAG, else first positional arg. Empty -> a dev placeholder.
TAG="${TAG:-${1:-}}"

require_cmds tar gzip

ASSET="${OUT_DIR}/uconsole-kernel.tar.gz"
SIDECAR="${OUT_DIR}/uconsole-kernel.version"

# --- Sanity: artifacts present -----------------------------------------
[[ -f "${KERNEL_OUT}/kernel8.img" ]] \
  || die "kernel artifacts missing (${KERNEL_OUT}/kernel8.img). Run ./scripts/build-kernel.sh first."
kver="$(cat "${KERNEL_OUT}/kver.txt" 2>/dev/null || true)"
[[ -n "${kver}" ]] || die "cannot read ${KERNEL_OUT}/kver.txt (incomplete build)"
[[ -d "${KERNEL_MODULES}/lib/modules/${kver}" ]] \
  || die "modules not found: ${KERNEL_MODULES}/lib/modules/${kver}"
[[ -f "${BOOT_CONFIG_DIR}/config.txt" && -f "${BOOT_CONFIG_DIR}/cmdline.txt" ]] \
  || die "boot config missing under ${BOOT_CONFIG_DIR}"

if [[ -z "${TAG}" ]]; then
  TAG="dev-$(date +%Y%m%d)"
  warn "no TAG given; using placeholder '${TAG}' (pass TAG=<tag> for a real release)"
fi

# Kernel source commit (informational; best-effort).
kcommit="unknown"
if [[ -d "${KDIR}/linux/.git" ]]; then
  kcommit="$(git -C "${KDIR}/linux" rev-parse HEAD 2>/dev/null || echo unknown)"
fi

# --- Stage and tar -----------------------------------------------------
mkdir -p "${OUT_DIR}"
stage="$(mktemp -d)"
push_cleanup "rm -rf '${stage}'"

log "staging kernel artifacts (kver=${kver}, tag=${TAG})"
cp -a "${KERNEL_OUT}"     "${stage}/out"
cp -a "${KERNEL_MODULES}" "${stage}/modules"
mkdir -p "${stage}/boot-config"
install -m 0644 "${BOOT_CONFIG_DIR}/config.txt"  "${stage}/boot-config/config.txt"
install -m 0644 "${BOOT_CONFIG_DIR}/cmdline.txt" "${stage}/boot-config/cmdline.txt"

cat > "${stage}/VERSION" <<EOF
tag=${TAG}
kver=${kver}
kernel_commit=${kcommit}
packaged=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "creating ${ASSET}"
tar -czf "${ASSET}" -C "${stage}" .

# Sidecar marker: the exact string update.sh compares against the device's
# /boot/uconsole-kernel.release.
printf '%s %s\n' "${TAG}" "${kver}" > "${SIDECAR}"

ok "packaged: ${ASSET}"
ok "sidecar:  ${SIDECAR} ($(cat "${SIDECAR}"))"
log "publish with: gh release create '${TAG}' '${ASSET}' '${SIDECAR}'"
