# uconsole-archlinux

ClockworkPi **uConsole (CM4)** 向けの Arch Linux ARM (aarch64) SD カードイメージを
ビルドするためのスクリプト群です。

Arch Linux ARM 公式の Raspberry Pi 用 tarball (`rpi-aarch64`) をベースに、
uConsole 固有のブート設定（DSI ディスプレイ・オーディオ等）を適用したイメージを生成します。

> [!IMPORTANT]
> uConsole の 5 インチ DSI パネル・PMU 等は Arch 標準の `linux-aarch64` カーネルでは
> 点灯しません（バックライトは点くが画面は真っ黒＝DSI 初期化順序のバグ）。
> uConsole 対応の **カスタムカーネル (kernel 6.16)** が必要です。本リポジトリは
> [OuinOuin74/linux-clockwork-arch](https://github.com/OuinOuin74/linux-clockwork-arch)
> のプリビルド pacman パッケージ（`linux-rpi-clockwork-cm4`）を自動取得し、chroot 内で
> `pacman -U` 導入します。ストックの `linux-aarch64` / `uboot-raspberrypi` は除去し、
> RPi ファームウェアから `kernel8-cm4.img` を直接起動する構成です。詳細は
> [カーネルについて](#カーネルについて) を参照。

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
# SD カードイメージをビルド（カーネル pkg は自動でダウンロード＆導入される）
sudo ./build.sh
```

初回のみベース tarball（約 800MB）と カーネル pkg（約 30MB）をダウンロードして
`cache/` に保存します（2 回目以降はキャッシュを再利用）。

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
| `UC_HOSTNAME`  | `uconsole`                          | ホスト名                     |
| `TIMEZONE`     | `Asia/Tokyo`                        | タイムゾーン                 |
| `LOCALE`       | `en_US.UTF-8`                       | ロケール                     |
| `TARBALL_URL`  | ArchLinuxARM 公式 rpi-aarch64       | ベース tarball の URL        |
| `KPKG_MODULE`  | `cm4`                               | カーネル pkg のモジュール種別（`cm4`/`cm5`）|
| `KPKG_VER`     | `7.0.9-1`                           | カーネル pkg のバージョン    |
| `KPKG_URL`     | GitHub Releases から自動生成        | カーネル pkg の URL（直接指定も可）|
| `OUT_DIR`      | `./out`                             | 出力先                       |
| `SKIP_CHROOT`  | (未設定)                            | `1` で chroot カスタマイズ省略（カーネルも未導入）|

例:

```sh
sudo IMG_SIZE=8G UC_HOSTNAME=myuconsole ./build.sh
```

## 構成

```
build.sh                メインのビルドスクリプト
lib/common.sh           共通ヘルパー（ログ・依存チェック・クリーンアップ）
config/
  boot/config.txt       uConsole CM4 用ブートコンフィグ（kernel 6.16 pkg 準拠）
  boot/cmdline.txt      カーネルコマンドライン
  overlays/             追加の .dtbo を置く場所（任意）
scripts/
  customize.sh          chroot 内で実行されるカスタマイズ（カーネル導入・ロケール等）
  collect-logs.sh       起動後の SD からブートログを回収するデバッグ補助
  build-kernel.sh       （旧）自前カーネルビルド。現行フローでは未使用
cache/                  ダウンロードした tarball / カーネル pkg（.gitignore）
```

## カーネルについて

uConsole の DSI パネル（cwu50）・PMU・バックライト等は Arch 標準カーネルでは
動作しません。かつては ClockworkPi の 5.10 系パッチカーネルを自前ビルドしていましたが、
その古いカーネルは DSI 初期化順序のバグで **バックライトは点くが画面が真っ黒** になる
問題がありました。

現行フローでは、Arch Linux ARM 向けにメンテされている
[OuinOuin74/linux-clockwork-arch](https://github.com/OuinOuin74/linux-clockwork-arch)
の **kernel 6.16** プリビルドパッケージを採用します。

- `build.sh` が GitHub Releases から `linux-rpi-clockwork-cm4-<ver>.pkg.tar.xz` を取得
- chroot 内で `pacman -Rdd linux-aarch64 uboot-raspberrypi`（ファームは温存）→ `pacman -U`
- overlay は統合版 `clockworkpi-uconsole-cm4`（旧 `devterm-*` 3 種を置き換え）
- RPi ファームウェア（`raspberrypi-bootloader`）から `kernel8-cm4.img` を直接起動

バージョンや CM5 対応は `KPKG_VER` / `KPKG_MODULE` で切り替えられます。

## ステータス

- [x] ベースイメージのビルドパイプライン
- [x] uConsole CM4 用ブート設定（kernel 6.16 pkg 準拠）
- [x] カスタムカーネル (6.16) の自動取得＆導入
- [ ] 実機での動作確認（DSI パネル点灯）
