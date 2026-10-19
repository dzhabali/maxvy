#!/bin/bash
# Иконка-заглушка 1024×1024 без альфы из веб-иконки ../icon-512.png (sips: через JPEG альфа уходит).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Vajra/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
TMP=$(mktemp -d)
sips -z 1024 1024 ../icon-512.png --out "$TMP/big.png" >/dev/null
sips -s format jpeg -s formatOptions best "$TMP/big.png" --out "$TMP/big.jpg" >/dev/null
sips -s format png "$TMP/big.jpg" --out "$OUT" >/dev/null
rm -rf "$TMP"
sips -g hasAlpha -g pixelWidth "$OUT"
