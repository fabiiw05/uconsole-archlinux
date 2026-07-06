#!/usr/bin/env bash
#
# chroot 内で実行される初期カスタマイズ。
# build.sh から qemu-aarch64-static 経由で呼ばれる。
# 環境変数 HOSTNAME / TIMEZONE / LOCALE を参照する。
#
# 単体で失敗してもイメージ自体は使えるよう、致命的でない処理は続行する。
set -uo pipefail

HOSTNAME="${HOSTNAME:-uconsole}"
TIMEZONE="${TIMEZONE:-Asia/Tokyo}"
LOCALE="${LOCALE:-en_US.UTF-8}"

echo "==> [chroot] pacman キーリングを初期化"
pacman-key --init          || echo "!! pacman-key --init 失敗（続行）"
pacman-key --populate archlinuxarm || echo "!! populate 失敗（続行）"

echo "==> [chroot] タイムゾーン: ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

echo "==> [chroot] ロケール: ${LOCALE}"
sed -i "s/^#\s*\(${LOCALE//./\\.} \)/\1/" /etc/locale.gen
grep -q "^${LOCALE}" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "==> [chroot] ホスト名: ${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# ネットワーク管理（NetworkManager）を導入して有効化。
# ネットワーク不通などで失敗してもイメージは使えるよう best-effort。
echo "==> [chroot] NetworkManager を導入"
if pacman -Sy --noconfirm --needed networkmanager sudo; then
  systemctl enable NetworkManager || true
else
  echo "!! パッケージ導入に失敗（続行）"
fi

echo "==> [chroot] カスタマイズ完了"
