[English](MAINTAINING.md) | 日本語

# uconsole-archlinux の保守

保守ランブックです。何を維持し続ける必要があるか、Arch 特有の繰り返し起きる運用上の
落とし穴、そして実機で検証済みのバージョン記録をまとめます。

## 検証済みバージョン

以下の組み合わせをクロスビルドし、実機（新ロット DSI パネル）で起動を確認しました。
何かを更新したら、下記チェックリストに従って**実機で再検証**したうえでこの表を
更新してください。

| 項目             | 値                                                           |
| ---------------- | ------------------------------------------------------------ |
| カーネルリポジトリ | `ak-rex/ClockworkPi-linux`                                  |
| カーネルブランチ | `rpi-6.12.y`                                                 |
| カーネル commit  | `0234e320bec7748fc6f1fb6904a055de10f0a727` (2026-07-05)      |
| カーネルリリース | `6.12.94-v8+`                                                |
| ベース tarball   | `ArchLinuxARM-rpi-aarch64-latest.tar.gz` (取得 2026-06-06)   |
| tarball md5      | `fd593833765dd6a09f8835010cc1e114`                          |
| ビルドイメージ   | `ubuntu:24.04` (digest 未固定)                              |
| 実機検証         | 2026-07-10（新ロットパネル）                                 |

> ビルドは何も強制 pin していません。`build-kernel.sh` はブランチの **HEAD** を
> clone、`build.sh` は**ローリング**の `-latest` tarball を取得、docker も
> ローリングの `ubuntu:24.04` を引きます。この表は「実際に動いた組み合わせ」の
> 記録であり、新しいビルドがおかしいときの再現・切り分けに使います。

## 今後必要になる保守

### 1. 上流カーネル追従（最大コスト）

`build-kernel.sh` は `git clone --depth 1 --branch rpi-6.12.y`、すなわちブランチの
**HEAD** を取得します。上流の変更（特に
`drivers/gpu/drm/panel/panel-cwu50.c` の新旧パネル判定）は即座に反映されます。

リスク: 上流の force-push / ブランチ削除、`rpi-6.12.y` の EOL・新ブランチ移行、
panel ドライバの回帰。カーネルを更新するたび**実機での再検証が必須**（下記）。
動作した commit は上表に記録してください。

`.github/workflows/upstream-watch.yml` が週次でブランチ HEAD を確認し、記録済み
commit と差分が出たら issue を起票します。

### 2. Arch Linux ARM ベース追従（ローリング）

**keyring 期限切れが最頻出の運用トラブルです。** `customize.sh` の `pacman -Sy`
（NetworkManager/sudo）が、ベース tarball に焼き込まれた keyring が古すぎると署名
エラーで失敗します。`customize.sh` はパッケージ導入前に
`archlinuxarm-keyring archlinux-keyring` を更新済みですが、それでも失敗する場合は
下の keyring 節を参照。

その他: リポジトリ移動 / 部分更新の破綻、ALARM プロジェクト自体の停滞リスク。
ミラーや `-latest` URL 自体が使えなくなったら `TARBALL_URL` を代替ソースに差し替え。

### 3. 実機再検証（自動化不可・本質コスト）

CI では代替できません。カーネルやベースを更新したら実機にフラッシュして確認します。
これが保守の本質コストです。**リリースを切る条件＝このチェックリストを通すこと。**

再検証チェックリスト:

- [ ] userspace まで起動する（ログイン前の黒画面・ハングが無い）。
- [ ] DSI パネルが正しく表示される — 理想は**旧・新ロット両方**のパネルで
      （ak-rex カーネルを使う目的そのもの）。
- [ ] NetworkManager が動く（`nmcli` / Wi-Fi 接続可）。
- [ ] 音が出る。
- [ ] `scripts/collect-logs.sh /dev/sdX` で新しい journal が取れ（下記の注意参照）、
      `dmesg.txt` / `journal-warn.txt` に致命的なエラーが無い。

> 注意: ALARM のベース tarball は**そのビルドホストの journal**を焼き込んでいるため、
> `collect-logs.sh` が「空 / 新規ブート無し」を返すのは、ロギングが壊れたのではなく、
> デバイスが userspace に到達しなかったことを意味します。

### 4. ツールチェイン / 環境ドリフト

`ubuntu:24.04`(docker) / `qemu-user-static`+binfmt / ホストの
`util-linux`(losetup,sfdisk) / `bsdtar`。互換性が壊れることは稀ですが、更新で起きえます。
非 Arch ホストでのビルド要望も来うる（依存コマンド名が distro で異なる）。

## Arch 特有の運用

### keyring

症状: `signature is unknown trust` / `invalid or corrupted package`。
対処（遅い `pacman-key --refresh-keys` より優先）:

```sh
pacman -Sy archlinuxarm-keyring archlinux-keyring
# それでも失敗するなら:
pacman-key --init && pacman-key --populate archlinuxarm
```

`customize.sh` はパッケージ導入前に最初の手順を自動で行います。

### ローリング更新 × 自前カーネル

`linux-aarch64` と `uboot-raspberrypi` は chroot 内で除去済みなので、後から
on-device で `pacman -Syu` しても通常は復活しません。念のため `customize.sh` が
`/etc/pacman.conf` に `IgnorePkg = linux-aarch64 uboot-raspberrypi` を書き込み、
依存やファームウェア更新でこれらが引き戻されて `/boot` を壊すのを防ぎます。
ただしファームウェア（`raspberrypi-bootloader`）更新で `/boot` が変わる可能性は
残るため、大きな更新の後は再確認してください。

### 実機のカーネル更新（`scripts/update.sh`）

カーネルはファイル注入方式（pacman パッケージではない）のため、既存インストールは
`pacman -Syu` では新しいカーネルを取得できません（この方法で更新されるのはベース OS だけ）。
`scripts/update.sh` はこのギャップを焼き直し無しで埋めます。実機上でリリース tarball
（`scripts/package-kernel.sh` が生成）を取得し、カーネル/modules/DTB/overlays＋ブート設定を
その場で配置します。`build.sh` と同じ `install_kernel_artifacts`（`lib/common.sh`）を使うため、
イメージ側と実機側の設置経路がズレません。

要点:

- 導入するのは**公開済みリリースのみ**（`latest`/`--tag` の GitHub Release アセット）で、
  ブランチ HEAD は引きません。下記の実機検証関門を保つためです。
- リリースアセット名は**固定**（`uconsole-kernel.tar.gz`）で、
  `.../releases/latest/download/...` の URL が安定します。サイドカー
  `uconsole-kernel.version` により、既に最新ならダウンロードを省けます
  （版は `/boot/uconsole-kernel.release` に記録）。
- `kernel8-cm4.img`/`config.txt`/`cmdline.txt` を `*.bak` に退避し、旧カーネルの
  `/usr/lib/modules/<kver>` は残すため、起動不良時は別マシンから `.bak` を戻して
  ロールバックできます。

### AIO 拡張ボードと実機更新

任意の HackerGadgets AIO ボード（`AIO_BOARD=v1|v2`、README 参照）は**ビルド時**の
オプトインです。`build.sh` がボードのオーバーレイを `/boot/config.txt` に追記し
（`apply_aio_config`）、`build-kernel.sh` が `rtc-pcf85063`/`spidev` モジュールを
常時有効化し、`customize.sh`（v2）が GPIO 電源保持サービス `uconsole-aio-gpio.service`
と DVB ブラックリストを導入します。リリース tarball は AIO *無し*で作成するため、
tarball から `config.txt` を再配置する `scripts/update.sh` は、カーネル更新時に**追記した
AIO オーバーレイ行を上書き**します（RTC/SPI オーバーレイが失われるので再追記が必要。
旧ファイルは `config.txt.bak` に退避）。GPIO サービスと modprobe ブラックリストは
`/boot` ではなく `/etc` 配下なので更新後も**残ります**。ボード非搭載の実機で GPIO
ラインを有効化しないよう、AIO は意図的に公開リリースへ含めません。

> ⚠️ **v2 の GPIO 電源保持は config.txt の `gpio=` ではなく userspace サービス**です。
> firmware の `gpio=` はカーネルの GPIO サブシステム初期化時に解除され、起動 ~8 秒後に
> ライン（特に RTL-SDR）がオフになります。`uconsole-aio-gpio.service` が `gpioset`
> (libgpiod v2) で BCM 7/16/23/27 を再アサート・保持します。実機で判明した挙動です。

### pacman サンドボックス / Landlock

実機での症状: `pacman -Syu` が `restricting filesystem access failed because
Landlock is not supported by the kernel!` で停止する。自前カーネル
（`bcm2711_defconfig`）には `CONFIG_SECURITY_LANDLOCK` が無く、pacman 7 の
ダウンロード用サンドボックスを起動できないためです。`customize.sh` が
`/etc/pacman.conf` の `[options]` セクションに `DisableSandbox` を書き込むので、
配布イメージでは問題は起きません。

無効化で失われるのはネットワーク側ダウンローダの隔離だけです。GPG 署名検証
（`SigLevel`）は従来どおり効くため、パッケージの整合性は変わりません。サンド
ボックスを復活させたい場合は `CONFIG_SECURITY_LANDLOCK=y` を有効にしたカーネル
再ビルドが必要です（defconfig では無効）。この変更より前に焼いた実機では、
`[options]` に手動で `DisableSandbox` を追記してください。

### ALARM 情報の追い方

[archlinuxarm.org](https://archlinuxarm.org/) のフロントページ告知・forum、GitHub の
[archlinuxarm/PKGBUILDs](https://github.com/archlinuxarm/PKGBUILDs) を監視。

### 時刻同期 (systemd-timesyncd) と networkd / NetworkManager の競合

**症状**: 実機で `timedatectl` が `System clock synchronized: no` のまま、時刻が
大きくずれる。`systemd-timesyncd` は `active` なのに `timedatectl show-timesync` の
`PacketCount=0` / `ServerName` 空で、**NTP パケットを 1 つも送っていない**
（`ping` や手動の UDP 123 クエリは通るのに、である）。

**原因（2 段構え）**:

1. **uConsole にはバッテリバックアップ RTC が無い**（`timedatectl` で `RTC time: n/a`）。
   起動ごとに時刻がずれるため、ネットワーク同期が事実上必須。
2. ベースの Arch Linux ARM (rpi) tarball は **`systemd-networkd` が有効**な状態で
   焼かれている。一方 `scripts/customize.sh` は **NetworkManager を追加で有効化**する
   （L148 付近）。結果 **両者が二重起動**する。実接続 (`wlan0`) は NetworkManager
   管理だが、networkd は未接続の有線 (`end0`) を掴んで `configuring` のまま留まり、
   `/run/systemd/netif/state` に `ONLINE_STATE=offline` を書き込む。
   `systemd-timesyncd` はこの networkd 由来の online 状態を見て「オフライン」と判断し、
   **同期を開始しない**。

**恒久対処（実機）**:

```sh
# NetworkManager を採用しているので networkd 系は無効化して競合を解消
sudo systemctl disable --now systemd-networkd.socket systemd-networkd \
  systemd-networkd-wait-online
sudo systemctl mask systemd-networkd
sudo rm -rf /run/systemd/netif        # stale な offline 状態を除去
# 日本の NTP サーバを明示（任意だが確実）
sudo install -Dm644 /dev/stdin /etc/systemd/timesyncd.conf.d/10-japan.conf <<'CONF'
[Time]
NTP=ntp.nict.jp 0.jp.pool.ntp.org 1.jp.pool.ntp.org
FallbackNTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
CONF
sudo systemctl restart systemd-timesyncd
timedatectl timesync-status   # ServerName=ntp.nict.jp / synced になれば OK
```

**TODO（イメージ側で根治）**: `scripts/customize.sh` の NetworkManager 有効化と
同じ箇所で `systemctl disable systemd-networkd systemd-networkd.socket
systemd-networkd-wait-online` を実行し、上記 `timesyncd.conf.d` を配置しておけば、
以降のイメージはこの問題を最初から回避できる。

## 今後の方向性

- **カーネルの PKGBUILD 化**（ファイル注入をやめる）。pacman 管理下に入れば、
  on-device のカーネル更新・巻き戻り防止が綺麗になります。本命の「Arch 流」ですが
  作業量は大きく、今回はスコープ外。当面は下記の `scripts/update.sh`
  （ファイル注入方式に沿った更新手段）で対応します。
- **Release 配布。** 既存インストール向けのカーネル＋ブート設定の更新は
  GitHub Releases 経由で既に配布済み（`scripts/package-kernel.sh` +
  `scripts/update.sh`）。加えて、初回ユーザに 30〜60 分のビルドをさせないため、
  再検証を通したフルイメージ（xz 圧縮）を検証済みバージョン表付きで公開することも可能。
  ~6G のサイズに注意。
- **CI によるリリース成果物ビルド。** カーネル成果物を Docker でビルドしてリリースに
  自動添付するワークフローも可能。ただし実機検証の関門は自動化できない（人が焼いて
  確認してから公開する必要がある）ため、今回は見送り。
- **バージョン固定。** 再現性が重要なら `build-kernel.sh` に `KSRC_COMMIT`、
  `build.sh` に版付き `TARBALL_URL` を通し、上表の値で pin します。

## リリース手順

1. 更新すべきもの（カーネル commit、ベース tarball 等）を上げる。
2. `bash -n build.sh scripts/*.sh lib/*.sh` と `shellcheck` がグリーン
   （CI が push/PR 毎に実行）。
3. フルビルド: `./scripts/build-kernel.sh` → `sudo ./build.sh`。
4. フラッシュして上記の実機再検証チェックリストを通す。
   **これが関門です。** 通していないリリースは公開しないこと。
5. 検証済みバージョン表を更新（本ファイルと `MAINTAINING.md` の両方）。
6. 実機用カーネル更新を梱包・公開し、既存インストールが `update.sh` で取得できる
   ようにする:

   ```sh
   TAG=v$(date +%Y%m%d) ./scripts/package-kernel.sh
   gh release create "$TAG" out/uconsole-kernel.tar.gz out/uconsole-kernel.version
   ```

   アセット名（`uconsole-kernel.tar.gz` / `.version`）は変えないこと。`update.sh` の
   latest-release URL がリリース間で安定していることに依存します。
7. （任意）同じリリースに xz 圧縮したフルイメージもアップロード。
