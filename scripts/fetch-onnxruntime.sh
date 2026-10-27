#!/bin/zsh
set -euo pipefail
VERSION=1.31.1
DEST="${0:A:h:h}/Vendor/onnxruntime"
[[ -f "$DEST/VERSION_NUMBER" && "$(cat "$DEST/VERSION_NUMBER")" == "$VERSION" ]] && exit 0
TMP=$(mktemp -d)
curl -sfL "https://github.com/microsoft/onnxruntime/releases/download/v$VERSION/onnxruntime-osx-arm64-$VERSION.tgz" | tar -xz -C "$TMP"
rm -rf "$DEST" && mkdir -p "${DEST:h}" && mv "$TMP/onnxruntime-osx-arm64-$VERSION" "$DEST"
rm -rf "$TMP"
cd "$DEST/lib" && rm libonnxruntime.1.dylib libonnxruntime.dylib && mv "libonnxruntime.$VERSION.dylib" libonnxruntime.1.dylib && rm -rf *.dSYM
