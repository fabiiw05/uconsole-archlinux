#!/usr/bin/env bash
#
# uConsole (CM4) 用カーネルをビルドする（ak-rex/ClockworkPi-linux, rpi-6.12.y）。
#
# ak-rex のツリーには ClockworkPi の uConsole 対応が統合済みで、特に
# 新ロット LCD パネル対応（drivers/gpu/drm/panel/panel-cwu50.c の
# id_gpio 判定 + cwu50_init_sequence2()）が入っている。これが無い
# カーネル（OuinOuin74 6.16 等）では新パネルが「横線・グラデ・崩れ」で
# 正しく表示されない。詳細は memory/uconsole-new-batch-panel を参照。
#
# aarch64 (kernel8) をクロスコンパイルし、成果物を kernel/out と
# kernel/modules に出力する。build.sh はこれらを直接イメージへ取り込む。
# ビルドは docker(ubuntu:24.04) 内で行う。ネットワークと docker が必要。
# 30〜60分程度かかる。
#
#   ./scripts/build-kernel.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# --- 設定（環境変数で上書き可） ---------------------------------------
# ak-rex/ClockworkPi-linux のブランチ（Rex が公式イメージで使うツリー）
KSRC_REPO="${KSRC_REPO:-https://github.com/ak-rex/ClockworkPi-linux.git}"
KSRC_BRANCH="${KSRC_BRANCH:-rpi-6.12.y}"
# ベース defconfig（CM4 = bcm2711）
KDEFCONFIG="${KDEFCONFIG:-bcm2711_defconfig}"

KDIR="${KDIR:-${REPO_DIR}/kernel}"
JOBS="${JOBS:-$(nproc)}"
BUILD_IMAGE="${BUILD_IMAGE:-ubuntu:24.04}"

require_cmds docker
mkdir -p "${KDIR}"

# --- docker 内で実行するビルド手順 ------------------------------------
# 成果物: /work/out (kernel8.img, *.dtb, overlays/*.dtbo, kver.txt) と
#         /work/modules (lib/modules/<kver>)
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

if [ ! -d linux/.git ]; then
  rm -rf linux
  git clone --depth 1 --branch "${KSRC_BRANCH}" "${KSRC_REPO}" linux
fi
cd linux

export KERNEL=kernel8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make "${KDEFCONFIG}"

# uConsole 新パネル対応に必要なドライバを確実に有効化（モジュール可）。
# defconfig に含まれていても冪等。含まれていなければ有効化される。
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
# ビルドツリーへの巨大シンボリックリンクは不要なので削除
rm -f /work/modules/lib/modules/*/build /work/modules/lib/modules/*/source

# kernel + dtb + overlays
rm -rf /work/out && mkdir -p /work/out/overlays
cp arch/arm64/boot/Image /work/out/kernel8.img
cp arch/arm64/boot/dts/broadcom/*.dtb /work/out/
# overlays は版により arm64 側 / arm 側どちらかに出力される
OVL_DIR=""
for d in arch/arm64/boot/dts/overlays arch/arm/boot/dts/overlays; do
  if ls "\$d"/clockworkpi-uconsole-cm4.dtbo >/dev/null 2>&1; then OVL_DIR="\$d"; break; fi
done
[ -n "\$OVL_DIR" ] || { echo "ERROR: clockworkpi-uconsole-cm4.dtbo が見つからない"; exit 1; }
cp "\$OVL_DIR"/*.dtbo /work/out/overlays/
cp "\$OVL_DIR"/README /work/out/overlays/ || true
echo "\${KVER}" > /work/out/kver.txt

# ホストユーザーが後で扱えるよう所有権調整
chown -R ${HOST_UID:-0}:${HOST_GID:-0} /work/out /work/modules /work/out_kver
DOCKER

log "docker(${BUILD_IMAGE}) で ak-rex ${KSRC_BRANCH} をビルド（30〜60分, jobs=${JOBS}）"
docker run --rm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "${KDIR}:/work" \
  "${BUILD_IMAGE}" /bin/bash /work/_build-in-docker.sh

KVER="$(cat "${KDIR}/out/kver.txt" 2>/dev/null || echo '?')"
ok "カーネルビルド完了 (kver=${KVER})"
log "成果物:"
printf '    %s\n' \
  "${KDIR}/out/kernel8.img" \
  "${KDIR}/out/overlays/ (clockworkpi-uconsole-cm4.dtbo を含む)" \
  "${KDIR}/modules/lib/modules/${KVER}/"
log "続けて 'sudo ./build.sh' を実行するとイメージに取り込まれます。"
