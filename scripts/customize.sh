#!/usr/bin/env bash
#
# chroot 内で実行される初期カスタマイズ。
# build.sh から qemu-aarch64-static 経由で呼ばれる。
# 環境変数 UC_HOSTNAME / TIMEZONE / LOCALE を参照する。
#
# 単体で失敗してもイメージ自体は使えるよう、致命的でない処理は続行する。
set -uo pipefail

UC_HOSTNAME="${UC_HOSTNAME:-uconsole}"
TIMEZONE="${TIMEZONE:-Asia/Tokyo}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# qemu-user エミュレーション下では pacman のサンドボックス(Landlock)が使えず
# "Landlock is not supported by the kernel" で失敗するため無効化する。
PAC="pacman --disable-sandbox"

echo "==> [chroot] pacman キーリングを初期化"
pacman-key --init          || echo "!! pacman-key --init 失敗（続行）"
pacman-key --populate archlinuxarm || echo "!! populate 失敗（続行）"

# --- ストックカーネル / U-Boot の除去 --------------------------------
# 自前ビルドのカーネル (kernel8-cm4.img / overlays / modules) は build.sh の
# install_kernel() が既にファイルとして配置済み。ここでは不要なストックの
# linux-aarch64 (未使用の kernel8.img とモジュール) と uboot-raspberrypi
# (kernel8.img=U-Boot) を除去するだけ。
# -Rdd: 依存カスケードを止め、raspberrypi-bootloader 等ファームウェアを守る。
echo "==> [chroot] ストックカーネル / U-Boot を除去（自前カーネルを使用）"
for pkg in linux-aarch64 uboot-raspberrypi; do
  if pacman -Qq "${pkg}" &>/dev/null; then
    echo "   - remove ${pkg}"
    ${PAC} -Rdd --noconfirm "${pkg}" || echo "!! ${pkg} 除去に失敗（続行）"
  fi
done

# 起動しない/画面が出ない等の初回デバッグ用に journal を永続化しておく。
# 一度起動すればSDを抜いて /var/log/journal からブートログを回収できる。
echo "==> [chroot] journald を永続化"
mkdir -p /var/log/journal

echo "==> [chroot] タイムゾーン: ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

echo "==> [chroot] ロケール: ${LOCALE}"
sed -i "s/^#\s*\(${LOCALE//./\\.} \)/\1/" /etc/locale.gen
grep -q "^${LOCALE}" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "==> [chroot] ホスト名: ${UC_HOSTNAME}"
echo "${UC_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${UC_HOSTNAME}.localdomain ${UC_HOSTNAME}
EOF

# ネットワーク管理（NetworkManager）を導入して有効化。
# ネットワーク不通などで失敗してもイメージは使えるよう best-effort。
echo "==> [chroot] NetworkManager を導入"
if ${PAC} -Sy --noconfirm --needed networkmanager sudo; then
  systemctl enable NetworkManager || true
else
  echo "!! パッケージ導入に失敗（続行）"
fi

echo "==> [chroot] カスタマイズ完了"
