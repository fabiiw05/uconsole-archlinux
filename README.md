# uconsole-archlinux

ClockworkPi **uConsole (CM4)** 向けの Arch Linux ARM (aarch64) SD カードイメージを
ビルドするためのスクリプト群です。

Arch Linux ARM 公式の Raspberry Pi 用 tarball (`rpi-aarch64`) をベースに、
uConsole 固有のブート設定（DSI ディスプレイ・オーディオ等）を適用したイメージを生成します。

> [!IMPORTANT]
> uConsole の 5 インチ DSI パネル（JD9365DA）・PMU 等は、Arch 標準の `linux-rpi`
> カーネル単体ではそのまま点灯しません。ClockworkPi が `raspberrypi/linux` に当てる
> **パッチ済みカーネル**（overlay `devterm-panel-uc` / `devterm-pmu` / `devterm-misc`
> を含む）が必要です。本リポジトリの `scripts/build-kernel.sh` でそれをビルドし、
> `build.sh` がイメージへ取り込みます。詳細は
> [パッチ済みカーネル](#パッチ済みカーネルについて) を参照。

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
# 1. uConsole 対応のパッチ済みカーネルをビルド（docker 使用・数十分）
#    ※ ディスプレイを使うなら必須。省略すると画面が出ません。
./scripts/build-kernel.sh

# 2. SD カードイメージをビルド（カーネル成果物があれば自動で取り込む）
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
build.sh                メインのビルドスクリプト
lib/common.sh           共通ヘルパー（ログ・依存チェック・クリーンアップ）
config/
  boot/config.txt       uConsole CM4 用ブートコンフィグ（ClockworkPi 公式準拠）
  boot/cmdline.txt      カーネルコマンドライン
  overlays/             追加の .dtbo を置く場所（任意）
scripts/
  build-kernel.sh       uConsole パッチ済みカーネルを docker でビルド
  customize.sh          chroot 内で実行されるカスタマイズ（ロケール等）
kernel/                 build-kernel.sh の出力（.gitignore、out/ と modules/）
```

## パッチ済みカーネルについて

uConsole の DSI パネルドライバや overlay（`devterm-panel-uc` /
`devterm-pmu` / `devterm-misc`）は、ClockworkPi が `raspberrypi/linux` に対して
配布するパッチに含まれます。`scripts/build-kernel.sh` は ClockworkPi 公式手順
（[clockworkpi/uConsole](https://github.com/clockworkpi/uConsole) の
`Code/patch/cm4`）を踏襲し、次を固定コミットで再現ビルドします。

- ベース: `raspberrypi/linux` @ `3a33f11`
- パッチ: `clockworkpi/uConsole` @ `0e8df2c` の `0001-patch-cm4.patch`

ビルドは docker (`ubuntu:22.04`) 内で aarch64 クロスコンパイルし、成果物を
`kernel/out`（`kernel8.img`, `*.dtb`, `overlays/*.dtbo`）と
`kernel/modules`（`lib/modules/<ver>`）に出力します。`build.sh` はこれらが
存在すれば Arch 標準カーネルを上書きしてイメージへ取り込みます。

> コミットを更新したい場合は `RPI_COMMIT` / `CPK_COMMIT` を環境変数で指定します。

## ステータス

- [x] ベースイメージのビルドパイプライン
- [x] uConsole CM4 用ブート設定（ClockworkPi 公式準拠）
- [x] パッチ済みカーネルのビルド＆取り込み（`scripts/build-kernel.sh`）
- [ ] カーネル実ビルドの疎通確認（docker 実行）
- [ ] 実機での動作確認
