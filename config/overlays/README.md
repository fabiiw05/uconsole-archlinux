# overlays

ここに置いた `*.dtbo` はビルド時にイメージの `/boot/overlays/` へコピーされます。

uConsole の DSI パネル用 overlay（`devterm-panel-uc` 等）は
`scripts/build-kernel.sh` でビルドしたカーネル成果物から自動配置されるため、
**ここに置く必要はありません**。

このディレクトリは、独自に追加したい任意の overlay を入れる用途です。

> `.dtbo` は `.gitignore` されていません。ライセンス上再配布可能なもののみ
> コミットしてください。
