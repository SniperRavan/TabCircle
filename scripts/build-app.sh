#!/bin/bash
# Build TabCircle.app and create DMGs (arm64 / x86_64).
#
#   ./scripts/build-app.sh            # Version inferred from latest git tag
#   ./scripts/build-app.sh 0.2.0      # Explicit version
#
# Output: build/<arch>/TabCircle.app and build/TabCircle-<version>-<arch>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 1.0.0)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD_DIR="$ROOT/build"
ARCHS=(arm64 x86_64)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

DEV_CERT="TabCircle Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT"; then
    SIGN_ID="$DEV_CERT"
    echo "▸ Using development certificate for signing (${DEV_CERT})"
else
    SIGN_ID="-"
    echo "▸ Using ad-hoc signing (run scripts/setup-dev-cert.sh to stabilize permissions)"
fi

[ -f assets/TabCircle.icns ] || ./scripts/make-icon.sh

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_SDK_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH")

build_one() {
    local arch="$1"
    local app="$BUILD_DIR/$arch/TabCircle.app"
    local dmg="$BUILD_DIR/TabCircle-$VERSION-$arch.dmg"
    local stage="$BUILD_DIR/dmg-$arch"

    echo "▸ [$arch] Compiling..."
    (cd helper && swift build -c release --arch "$arch" "${SWIFT_SDK_FLAGS[@]}")

    local bin_dir
    bin_dir="$(cd helper && swift build -c release --arch "$arch" "${SWIFT_SDK_FLAGS[@]}" --show-bin-path)"
    [ -f "$bin_dir/tabcircle" ] || { echo "✗ [$arch] Binary not found: $bin_dir/tabcircle"; exit 1; }

    local linked_sdk
    linked_sdk=$(otool -l "$bin_dir/tabcircle" | awk '/LC_BUILD_VERSION/{f=1} f&&/sdk/{print $2; exit}')
    if [ -z "$linked_sdk" ] || [ "${linked_sdk%%.*}" -lt 14 ] 2>/dev/null; then
        echo "✗ [$arch] Linked SDK is ${linked_sdk:-unknown}, minimum supported SDK is 14.0"
        exit 1
    fi

    local stale_src
    stale_src=$(find helper/Sources -name '*.swift' -newer "$bin_dir/tabcircle" -print -quit)
    if [ -n "$stale_src" ]; then
        echo "✗ [$arch] Source is newer than binary ($stale_src); build did not take effect"
        exit 1
    fi

    echo "▸ [$arch] Assembling bundle..."
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_dir/tabcircle" "$app/Contents/MacOS/TabCircle"
    sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
        packaging/Info.plist > "$app/Contents/Info.plist"
    cp assets/TabCircle.icns "$app/Contents/Resources/TabCircle.icns"

    shopt -s nullglob
    for bundle in "$bin_dir"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
    done
    shopt -u nullglob

    codesign --force --deep --sign "$SIGN_ID" "$app"
    codesign --verify --strict "$app" && echo "  [$arch] Signature verified"

    echo "▸ [$arch] Packaging DMG..."
    mkdir -p "$stage"
    cp -R "$app" "$stage/TabCircle.app"
    ln -s /Applications "$stage/Applications"
    cp packaging/DMG-README.txt "$stage/Read Me First.txt"
    hdiutil create -volname "TabCircle $VERSION" \
        -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
    rm -rf "$stage"
}

for arch in "${ARCHS[@]}"; do
    build_one "$arch"
done

echo "▸ Packaging extension zip..."
EXT_STAGE="$BUILD_DIR/ext-stage"
rm -rf "$EXT_STAGE"
mkdir -p "$EXT_STAGE"
cp -R extension "$EXT_STAGE/TabCircle-Extension"
rm -rf "$EXT_STAGE/TabCircle-Extension/tests"
(cd "$EXT_STAGE" && zip -qr "$BUILD_DIR/TabCircle-Extension.zip" TabCircle-Extension -x "*.DS_Store")
rm -rf "$EXT_STAGE"

missing=$(unzip -l "$BUILD_DIR/TabCircle-Extension.zip" | grep -c "manifest.json")
[ "$missing" -eq 1 ] || { echo "❌ Extension zip missing manifest.json"; exit 1; }
if unzip -l "$BUILD_DIR/TabCircle-Extension.zip" | grep -qE "/(tests|checks|node_modules)/"; then
    echo "❌ Extension zip contains development files"; exit 1
fi

if [[ " $* " == *" --install "* ]]; then
    NATIVE_ARCH="$(uname -m)"
    APP="$BUILD_DIR/$NATIVE_ARCH/TabCircle.app"
    echo "▸ Installing to /Applications (${NATIVE_ARCH})..."
    if pgrep -f "/Applications/TabCircle.app/Contents/MacOS/TabCircle" >/dev/null; then
        osascript -e 'tell application "TabCircle" to quit' 2>/dev/null || true
        for _ in $(seq 1 20); do
            pgrep -f "/Applications/TabCircle.app/Contents/MacOS/TabCircle" >/dev/null || break
            sleep 0.25
        done
        pkill -f "/Applications/TabCircle.app/Contents/MacOS/TabCircle" 2>/dev/null || true
        sleep 0.5
    fi
    rm -rf /Applications/TabCircle.app
    cp -R "$APP" /Applications/TabCircle.app
    xattr -dr com.apple.quarantine /Applications/TabCircle.app 2>/dev/null || true
    echo "  Installed: /Applications/TabCircle.app"
    open -a /Applications/TabCircle.app
    echo "  Launched"
fi

echo
echo "✅ Complete"
for arch in "${ARCHS[@]}"; do
    dmg="$BUILD_DIR/TabCircle-$VERSION-$arch.dmg"
    echo "   $arch : $dmg ($(du -h "$dmg" | cut -f1))"
done
