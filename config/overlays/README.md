# overlays

Any `*.dtbo` placed here is copied into the image's `/boot/overlays/` at build time.

The uConsole DSI panel overlay (`clockworkpi-uconsole-cm4`, etc.) is deployed
automatically from the kernel artifacts built by `scripts/build-kernel.sh`, so
**you do not need to place it here**.

This directory is for any extra overlays you want to add yourself.

> `.dtbo` files are **not** gitignored. Only commit ones that are
> license-compatible for redistribution.
