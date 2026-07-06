# uconsole-archlinux

ClockworkPi **uConsole (CM4)** 向けの Arch Linux ARM (aarch64) SD カードイメージを
ビルドするためのスクリプト群です。

Arch Linux ARM 公式の Raspberry Pi 用 tarball (`rpi-aarch64`) をベースに、
uConsole 固有のブート設定（DSI ディスプレイ・オーディオ等）を適用したイメージを生成します。

> [!IMPORTANT]
> uConsole の 5 インチ DSI パネルはメインラインの `linux-rpi` カーネル単体では
> そのまま点灯しません。ClockworkPi が配布する device tree overlay (`.dtbo`) か、
> パッチ済みカーネルが必要です。詳細は [Display overlay](#display-overlay-について) を参照。

## 必要なもの

- ビルドは **Linux ホスト上で root 権限** で実行します（loop device を使用）。
- 依存コマンド:
  - `wget` または `curl`
  - `bsdtar`（`libarchive`）
  - `mkfs.vfat`（`dosfstools`）, `mkfs.ext4`（`e2fsprogs`）
  - `sfdisk`, `losetup`（`util-linux`）
  - （chroot カスタマイズを使う場合）`qemu-aarch64-static` + `binfmt`（`qemu-user-static`）

Arch ホストでの一括インストール例:

```sh
sudo pacman -S --needed wget libarchive dosfstools e2fsprogs util-linux \
  qemu-user-static qemu-user-static-binfmt
```

## 使い方

```sh
sudo ./build.sh
```

生成物: `out/uconsole-archlinux-YYYYMMDD.img`

SD カードへの書き込み（デバイス名は要確認、**間違えると別ドライブを破壊します**）:

```sh
sudo dd if=out/uconsole-archlinux-*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### 主な設定（環境変数で上書き可能）

| 変数           | 既定値                              | 説明                         |
| -------------- | ----------------------------------- | ---------------------------- |
| `IMG_SIZE`     | `6G`                                | イメージ全体サイズ           |
| `BOOT_SIZE`    | `256M`                              | ブート (FAT32) パーティション |
| `HOSTNAME`     | `uconsole`                          | ホスト名                     |
| `TIMEZONE`     | `Asia/Tokyo`                        | タイムゾーン                 |
| `LOCALE`       | `en_US.UTF-8`                       | ロケール                     |
| `TARBALL_URL`  | ArchLinuxARM 公式 rpi-aarch64       | ベース tarball の URL        |
| `OUT_DIR`      | `./out`                             | 出力先                       |
| `SKIP_CHROOT`  | (未設定)                            | `1` で chroot カスタマイズ省略 |

例:

```sh
sudo IMG_SIZE=8G HOSTNAME=myuconsole ./build.sh
```

## 構成

```
build.sh              メインのビルドスクリプト
lib/common.sh         共通ヘルパー（ログ・依存チェック・クリーンアップ）
config/
  boot/config.txt     uConsole CM4 用ブートコンフィグ
  boot/cmdline.txt    カーネルコマンドライン
  overlays/           uConsole 用 .dtbo を置く場所（README 参照）
scripts/
  customize.sh        chroot 内で実行されるカスタマイズ（ロケール/ユーザー等）
```

## Display overlay について

Arch Linux ARM の `linux-rpi` カーネルには uConsole の DSI パネル用 overlay が
含まれていません。次のいずれかで対応します。

1. **ClockworkPi 公式の dtbo を流用する**
   ClockworkPi の uConsole 向けカーネル/イメージから
   `clockworkpi-uconsole.dtbo`（名称はバージョンに依存）を取り出し、
   `config/overlays/` に置くと、ビルド時に `/boot/overlays/` へコピーされ、
   `config/boot/config.txt` の `dtoverlay` 行が有効になります。

2. **パッチ済みカーネルをビルドする**
   パネルドライバを含むカーネルを別途用意し、chroot 内でインストールする。

現状の `config.txt` では該当 overlay 行を**コメントアウト**しており、
overlay を配置したうえで有効化する運用です。

## ステータス

- [x] ベースイメージのビルドパイプライン
- [x] uConsole CM4 用ブート設定の雛形
- [ ] DSI パネル overlay の同梱（要 ClockworkPi ソース）
- [ ] 実機での動作確認
