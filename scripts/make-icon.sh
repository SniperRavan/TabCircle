#!/bin/bash
# Generate macOS .icns from icon-128.png or PNG assets.
set -euo pipefail

cd "$(dirname "$0")/.."

PNG="assets/icon-128.png"
ICONSET="$(mktemp -d)/TabCircle.iconset"
OUT="assets/TabCircle.icns"

mkdir -p "$ICONSET"

# Render icon sizes
render() {
    if command -v sips >/dev/null 2>&1; then
        sips -z "$1" "$1" "$PNG" --out "$ICONSET/$2" >/dev/null
    elif command -v convert >/dev/null 2>&1; then
        convert "$PNG" -resize "${1}x${1}" "$ICONSET/$2"
    else
        cp "$PNG" "$ICONSET/$2"
    fi
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

if command -v iconutil >/dev/null 2>&1; then
    iconutil --convert icns "$ICONSET" --output "$OUT"
    echo "✅ Generated $OUT"
fi
rm -rf "$(dirname "$ICONSET")"
