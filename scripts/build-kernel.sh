#!/usr/bin/env bash
#
# uConsole (CM4) 用パッチ済みカーネルをビルドする。
#
# raspberrypi/linux に ClockworkPi の uConsole パッチを当てて
# aarch64 (kernel8) をクロスコンパイルし、成果物を kernel/out と
# kernel/modules に出力する。build.sh はこれらが存在すればイメージへ取り込む。
#
# ビルドは ClockworkPi 公式手順に合わせ docker(ubuntu:22.04) 内で行う。
# 実行にはネットワークと docker が必要。数十分かかる。
#
#   ./scripts/build-kernel.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# --- ピン留め（再現性のため固定） ------------------------------------
# raspberrypi/linux のベースコミット（ClockworkPi パッチが対象とするもの）
RPI_COMMIT="${RPI_COMMIT:-3a33f11c48572b9dd0fecac164b3990fc9234da8}"
# ClockworkPi/uConsole リポジトリのコミット（パッチ取得元）
CPK_COMMIT="${CPK_COMMIT:-0e8df2cf7d0ac207ac13709483cb0ffb58d40dc4}"
PATCH_PATH="Code/patch/cm4/20230630/0001-patch-cm4.patch"
PATCH_URL="https://raw.githubusercontent.com/clockworkpi/uConsole/${CPK_COMMIT}/${PATCH_PATH}"

KDIR="${KDIR:-${REPO_DIR}/kernel}"
JOBS="${JOBS:-$(nproc)}"

require_cmds docker
if command -v wget >/dev/null 2>&1; then DL=wget; \
elif command -v curl >/dev/null 2>&1; then DL=curl; \
else die "wget か curl が必要です"; fi

mkdir -p "${KDIR}"

# --- パッチ取得 --------------------------------------------------------
PATCH_FILE="${KDIR}/0001-patch-cm4.patch"
if [[ ! -f "${PATCH_FILE}" ]]; then
  log "uConsole パッチを取得: ${PATCH_URL}"
  if [[ "${DL}" == wget ]]; then
    wget -O "${PATCH_FILE}" "${PATCH_URL}"
  else
    curl -fL -o "${PATCH_FILE}" "${PATCH_URL}"
  fi
else
  ok "パッチはキャッシュ済み: ${PATCH_FILE}"
fi

# --- docker 内で実行するビルド手順 ------------------------------------
# ClockworkPi の build-kernel.sh を踏襲。成果物は out/ と modules/ へ。
cat > "${KDIR}/_build-in-docker.sh" <<DOCKER
#!/bin/bash
set -eox pipefail
cd /work

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential gcc-aarch64-linux-gnu git bc bison flex \\
  libssl-dev make libc6-dev libncurses-dev crossbuild-essential-arm64 \\
  gawk openssl dkms libelf-dev

if [ ! -d linux ]; then
  git clone --depth 1 https://github.com/raspberrypi/linux.git linux
fi
cd linux
git fetch --depth 1 origin ${RPI_COMMIT}
git reset --hard ${RPI_COMMIT}
git clean -fd
git apply /work/0001-patch-cm4.patch

export KERNEL=kernel8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make bcm2711_defconfig
make -j${JOBS}

# modules
rm -rf /work/modules && mkdir -p /work/modules
INSTALL_MOD_PATH=/work/modules make modules_install
rm -f /work/modules/lib/modules/*/build /work/modules/lib/modules/*/source

# kernel + dtb + overlays
rm -rf /work/out && mkdir -p /work/out/overlays
cp arch/arm64/boot/Image /work/out/kernel8.img
cp arch/arm64/boot/dts/broadcom/*.dtb /work/out/
cp arch/arm64/boot/dts/overlays/*.dtb* /work/out/overlays/
cp arch/arm64/boot/dts/overlays/README /work/out/overlays/ || true

# コンテナ実行ユーザーが後で扱えるよう所有権を調整
chown -R ${HOST_UID:-0}:${HOST_GID:-0} /work/out /work/modules
DOCKER

log "docker(ubuntu:22.04) でカーネルをビルド（数十分かかります, jobs=${JOBS}）"
docker run --rm --privileged \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "${KDIR}:/work" \
  ubuntu:22.04 /bin/bash /work/_build-in-docker.sh

ok "カーネルビルド完了"
log "成果物:"
printf '    %s\n' "${KDIR}/out/kernel8.img" "${KDIR}/out/overlays/" "${KDIR}/modules/lib/modules/"
log "続けて 'sudo ./build.sh' を実行するとイメージに取り込まれます。"
