# overlays

ここに置いた `*.dtbo` はビルド時にイメージの `/boot/overlays/` へコピーされます。

uConsole の DSI パネルを点灯させるには、ClockworkPi が配布する overlay
（例: `clockworkpi-uconsole.dtbo`。名称はカーネル/イメージのバージョンに依存）を
このディレクトリに配置し、`config/boot/config.txt` の該当 `dtoverlay=` 行を
有効化してください。

overlay の入手元の例:
- ClockworkPi 公式の uConsole 向けイメージ / カーネルパッケージの `/boot/overlays/`
- ClockworkPi の GitHub（デバイスツリーソースから `dtc` でビルド）

> このディレクトリの `.dtbo` は `.gitignore` されていません。ライセンス上
> 再配布可能なもののみコミットしてください。
