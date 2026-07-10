[English](README.md) | 日本語

# uconsole-archlinux

ClockworkPi **uConsole (CM4)** 向けの Arch Linux ARM (aarch64) SD カードイメージを
ビルドするためのスクリプト群です。

Arch Linux ARM 公式の Raspberry Pi 用 tarball (`rpi-aarch64`) をベースに、
uConsole 固有のブート設定（DSI ディスプレイ・オーディオ等）と、uConsole 対応の
**自前ビルドカーネル**を組み込んだイメージを生成します。

> [!IMPORTANT]
> uConsole の 5 インチ DSI パネル (cwu50)・PMU・バックライト等は Arch 標準の
> `linux-aarch64` では動作しません。さらに **2026 年以降の新ロットはパネルの
> メーカー/仕様が変わり**、対応パッチの無いカーネル（旧 ClockworkPi 5.10 系や
> OuinOuin74 6.16 など）では **バックライトは点くが横線・崩れ・真っ黒**になります。
> 本リポジトリは **ak-rex/ClockworkPi-linux (`rpi-6.12.y`)** を自前ビルドします。
> このツリーの `panel-cwu50` ドライバは **`id_gpio` で新旧パネルを自動判別**し
> (`is_new_panel` → `cwu50_init_sequence2()`)、新ロットでも正しく表示します。
> 詳細は [カーネルについて](#カーネルについて) を参照。

## 必要なもの

- ビルドは **Linux ホスト上で root 権限** で実行します（loop device を使用）。
- カーネルビルドに **docker**（`ubuntu:24.04` イメージ内でクロスコンパイル）。
- 依存コマンド:
  - `docker`（カーネルビルド）
  - `wget` または `curl`
  - `bsdtar`（`libarchive`）
  - `mkfs.vfat`（`dosfstools`）, `mkfs.ext4`（`e2fsprogs`）
  - `sfdisk`, `losetup`（`util-linux`）
  - （chroot カスタマイズを使う場合）`qemu-aarch64-static` + `binfmt`（`qemu-user-static`）

Arch ホストでの一括インストール例:

```sh
sudo pacman -S --needed docker wget libarchive dosfstools e2fsprogs util-linux \
  qemu-user-static qemu-user-static-binfmt
sudo systemctl start docker
```

## 使い方

```sh
# 1. カーネルをビルド（初回のみ。30〜60 分。docker 内でクロスコンパイル）
./scripts/build-kernel.sh

# 2. SD カードイメージをビルド（自前カーネルを取り込む）
sudo ./build.sh
```

`build-kernel.sh` は成果物を `kernel/out`（kernel8.img・dtb・overlays）と
`kernel/modules` に出力し、`build.sh` がそれらをイメージへ直接配置します。
ベース tarball（約 800MB）は初回のみ `cache/` に保存されます。

生成物: `out/uconsole-archlinux-YYYYMMDD.img`

SD カードへの書き込み（デバイス名は要確認、**間違えると別ドライブを破壊します**）:

```sh
sudo dd if=out/uconsole-archlinux-*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

イメージは固定サイズ（`IMG_SIZE`、既定 6G）ですが、手動で拡張する必要は
**ありません**。**初回起動時**にルートパーティションとファイルシステムが
SD カード全体まで自動拡張されます（一度だけ動いて自身を無効化する
systemd oneshot サービス）。

### 主な設定（環境変数で上書き可能）

| 変数           | 既定値                              | 説明                          |
| -------------- | ----------------------------------- | ----------------------------- |
| `IMG_SIZE`     | `6G`                                | イメージ全体サイズ            |
| `BOOT_SIZE`    | `256M`                              | ブート (FAT32) パーティション |
| `UC_HOSTNAME`  | `uconsole`                          | ホスト名                      |
| `TIMEZONE`     | `Asia/Tokyo`                        | タイムゾーン                  |
| `LOCALE`       | `en_US.UTF-8`                       | ロケール                      |
| `TARBALL_URL`  | ArchLinuxARM 公式 rpi-aarch64       | ベース tarball の URL         |
| `KSRC_BRANCH`  | `rpi-6.12.y`                        | ビルドするカーネルのブランチ  |
| `KDEFCONFIG`   | `bcm2711_defconfig`                 | カーネル defconfig（CM4）     |
| `JOBS`         | `nproc`                             | カーネルビルドの並列数        |
| `OUT_DIR`      | `./out`                             | 出力先                        |
| `SKIP_CHROOT`  | (未設定)                            | `1` で chroot カスタマイズ省略 |

例:

```sh
sudo IMG_SIZE=8G UC_HOSTNAME=myuconsole ./build.sh
```

## 稼働中デバイスの更新

新しいカーネルを取り込むのに**焼き直しは不要**です。ベースの Arch Linux ARM は
`sudo pacman -Syu`（ローリング）で自動更新され、自前ビルドの**カーネル + ブート設定**は
GitHub Releases 経由で別途配布し、その場で入れ替えます:

```sh
# uConsole 本体で実行
sudo ./scripts/update.sh            # 最新リリースのカーネルを導入
sudo ./scripts/update.sh --force    # 同一版でも強制的に再適用
sudo reboot                         # 再起動で反映
```

`update.sh` はリリース tarball を取得し、現在の
`/boot/kernel8-cm4.img`（＋ `config.txt` / `cmdline.txt`）を `*.bak` に退避してから、
新しいカーネル / modules / DTB / overlays とブート設定を配置し、版を
`/boot/uconsole-kernel.release` に記録します（既に最新なら再実行しても何もしません）。
導入されるのは**公開済み・実機検証済みのリリースのみ**で、ブランチ HEAD を直接引くことは
ありません。新カーネルで起動しない場合は、FAT32 ブートパーティションをマウントできる別の
マシンから `kernel8-cm4.img.bak` を書き戻してください。

> メンテナは `scripts/package-kernel.sh` でリリースを作成します（[MAINTAINING.ja.md](MAINTAINING.ja.md) 参照）。

## 構成

```
build.sh                メインのビルドスクリプト（自前カーネルを取り込む）
lib/common.sh           共通ヘルパー（ログ・依存チェック・クリーンアップ）
config/
  boot/config.txt       uConsole CM4 用ブートコンフィグ
  boot/cmdline.txt      カーネルコマンドライン
  overlays/             追加の .dtbo を置く場所（任意）
scripts/
  build-kernel.sh       ak-rex/ClockworkPi-linux (rpi-6.12.y) をクロスビルド
  customize.sh          chroot 内で実行されるカスタマイズ（ロケール・NM 等）
  collect-logs.sh       起動後の SD からブートログを回収するデバッグ補助
  package-kernel.sh     カーネル成果物をリリース tarball に梱包
  update.sh             実機用カーネル/ブート更新（焼き直し不要）
cache/                  ダウンロードした tarball（.gitignore）
kernel/                 カーネルビルド成果物 out/ modules/（.gitignore）
```

## カーネルについて

uConsole の DSI パネル（cwu50）・PMU・バックライト等は Arch 標準カーネルでは
動作しません。加えて **2026 年以降の新ロットはパネルの仕様が変更**され、
新パネル対応の入っていないカーネルでは横線・崩れ・真っ黒になります
（ClockworkPi フォーラムの既知問題。GPIO8 を新パネルの id_gpio に使う等）。

本リポジトリは **ak-rex/ClockworkPi-linux の `rpi-6.12.y`**（Rex が公式イメージで
使うツリー）を自前クロスビルドします。ポイントは `panel-cwu50` ドライバ:

```c
ctx->id_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_IN);
ctx->is_new_panel = gpiod_get_value_cansleep(ctx->id_gpio);
...
if (ctx->is_new_panel) cwu50_init_sequence2(ctx);  /* 新ロット */
else                   cwu50_init_sequence(ctx);   /* 旧ロット */
```

- `scripts/build-kernel.sh` が docker 内で `bcm2711_defconfig` をビルド
- `kernel8.img`・dtb・overlays（`clockworkpi-uconsole-cm4.dtbo` 含む）・modules を出力
- `build.sh` が `/boot/kernel8-cm4.img` 等として配置（RPi ファームウェアから直接起動）
- initramfs 不要（mmc/ext4 はビルトイン）

`KSRC_BRANCH` / `KDEFCONFIG` でブランチや defconfig を切り替えられます。

## ステータス

- [x] ベースイメージのビルドパイプライン
- [x] uConsole CM4 用ブート設定
- [x] 新ロットパネル対応カーネル（ak-rex 6.12.y）の自前ビルド＆取り込み
- [x] 実機での動作確認（新ロット DSI パネル表示）✅ 2026-07-10

## メンテナンス

上流（ak-rex カーネル / ArchLinuxARM）への追従方針、keyring 期限切れへの対処、
実機再検証チェックリスト、検証済みバージョンの記録は
[MAINTAINING.ja.md](MAINTAINING.ja.md) を参照してください。

## ライセンス / 謝辞

本リポジトリの**スクリプト**は [MIT License](LICENSE)（© 2026 fabiiw05）です。

ただし、ビルド／ダウンロードされる**成果物はそれぞれのライセンスに従います**:

- **カーネル**: [ak-rex/ClockworkPi-linux](https://github.com/ak-rex/ClockworkPi-linux)
  (`rpi-6.12.y`, GPL-2.0)。新ロットパネル対応の `panel-cwu50` を含みます。
- **rootfs**: [Arch Linux ARM](https://archlinuxarm.org/) の各パッケージのライセンス。

謝辞: [ClockworkPi](https://www.clockworkpi.com/) / [ak-rex](https://github.com/ak-rex)
（uConsole カーネルツリーの整備）/ [Arch Linux ARM](https://archlinuxarm.org/)。
