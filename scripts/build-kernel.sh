#!/usr/bin/env bash
#
# Build the uConsole (CM4) kernel (ak-rex/ClockworkPi-linux, rpi-6.12.y).
#
# The ak-rex tree has ClockworkPi's uConsole support integrated, notably
# new-batch LCD panel support (drivers/gpu/drm/panel/panel-cwu50.c:
# id_gpio detection + cwu50_init_sequence2()). Kernels without it
# (e.g. OuinOuin74 6.16) render the new panel as "horizontal lines /
# gradient / garbled". See memory/uconsole-new-batch-panel for details.
#
# Cross-compiles aarch64 (kernel8) and emits artifacts into kernel/out and
# kernel/modules. build.sh then pulls those directly into the image.
# The build runs inside docker (ubuntu:24.04). Requires network and docker.
# Takes roughly 30-60 minutes.
#
#   ./scripts/build-kernel.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# --- Settings (overridable via environment) ----------------------------
# ak-rex/ClockworkPi-linux branch (the tree Rex uses for the official images).
KSRC_REPO="${KSRC_REPO:-https://github.com/ak-rex/ClockworkPi-linux.git}"
KSRC_BRANCH="${KSRC_BRANCH:-rpi-6.12.y}"
# Base defconfig (CM4 = bcm2711)
KDEFCONFIG="${KDEFCONFIG:-bcm2711_defconfig}"

KDIR="${KDIR:-${REPO_DIR}/kernel}"
JOBS="${JOBS:-$(nproc)}"
BUILD_IMAGE="${BUILD_IMAGE:-ubuntu:24.04}"

require_cmds docker
mkdir -p "${KDIR}"

# --- Build steps executed inside docker --------------------------------
# Artifacts: /work/out (kernel8.img, *.dtb, overlays/*.dtbo, kver.txt) and
#            /work/modules (lib/modules/<kver>)
cat > "${KDIR}/_build-in-docker.sh" <<DOCKER
#!/bin/bash
set -eox pipefail
cd /work

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \\
  build-essential gcc-aarch64-linux-gnu crossbuild-essential-arm64 \\
  git bc bison flex libssl-dev make libc6-dev libncurses-dev \\
  gawk openssl libelf-dev kmod ca-certificates cpio

# If an existing linux/ is a different repo (e.g. old raspberrypi/linux),
# recreate it. Otherwise we would reuse a stale tree (e.g. building 5.10.17).
NEED_CLONE=1
if [ -d linux/.git ] && \\
   [ "\$(git -C linux config --get remote.origin.url 2>/dev/null || true)" = "${KSRC_REPO}" ]; then
  NEED_CLONE=0
fi
if [ "\$NEED_CLONE" = 1 ]; then
  echo "== (re)clone ${KSRC_REPO} (${KSRC_BRANCH}) =="
  rm -rf linux
  git clone --depth 1 --branch "${KSRC_BRANCH}" "${KSRC_REPO}" linux
fi
cd linux
echo "== kernel source: \$(git config --get remote.origin.url) @ \$(git rev-parse --abbrev-ref HEAD) =="

export KERNEL=kernel8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make "${KDEFCONFIG}"

# Ensure the drivers needed for new-panel support are enabled (as modules).
# Idempotent even if already in the defconfig; enabled otherwise.
./scripts/config --module CONFIG_DRM_PANEL_CWU50 || true
./scripts/config --module CONFIG_BACKLIGHT_OCP8178 || true
./scripts/config --module CONFIG_DRM_PANEL_CWD686 || true
make olddefconfig

make -j${JOBS} Image modules dtbs

KVER="\$(make -s kernelrelease)"
echo "\${KVER}" > /work/out_kver

# modules
rm -rf /work/modules && mkdir -p /work/modules
INSTALL_MOD_PATH=/work/modules make modules_install
# Drop the huge symlinks into the build tree; not needed.
rm -f /work/modules/lib/modules/*/build /work/modules/lib/modules/*/source

# kernel + dtb + overlays
rm -rf /work/out && mkdir -p /work/out/overlays
cp arch/arm64/boot/Image /work/out/kernel8.img
cp arch/arm64/boot/dts/broadcom/*.dtb /work/out/
# Depending on the version, overlays land under the arm64 or the arm tree.
OVL_DIR=""
for d in arch/arm64/boot/dts/overlays arch/arm/boot/dts/overlays; do
  if ls "\$d"/clockworkpi-uconsole-cm4.dtbo >/dev/null 2>&1; then OVL_DIR="\$d"; break; fi
done
[ -n "\$OVL_DIR" ] || { echo "ERROR: clockworkpi-uconsole-cm4.dtbo not found"; exit 1; }
cp "\$OVL_DIR"/*.dtbo /work/out/overlays/
cp "\$OVL_DIR"/README /work/out/overlays/ || true
echo "\${KVER}" > /work/out/kver.txt

# Fix ownership so the host user can handle the files afterwards.
chown -R ${HOST_UID:-0}:${HOST_GID:-0} /work/out /work/modules /work/out_kver
DOCKER

log "building ak-rex ${KSRC_BRANCH} in docker(${BUILD_IMAGE}) (30-60 min, jobs=${JOBS})"
docker run --rm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "${KDIR}:/work" \
  "${BUILD_IMAGE}" /bin/bash /work/_build-in-docker.sh

KVER="$(cat "${KDIR}/out/kver.txt" 2>/dev/null || echo '?')"
ok "kernel build complete (kver=${KVER})"
log "artifacts:"
printf '    %s\n' \
  "${KDIR}/out/kernel8.img" \
  "${KDIR}/out/overlays/ (includes clockworkpi-uconsole-cm4.dtbo)" \
  "${KDIR}/modules/lib/modules/${KVER}/"
log "next, run 'sudo ./build.sh' to pull these into the image."
