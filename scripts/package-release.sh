#!/usr/bin/env bash
# Packages TabCircle release artifacts for GitHub Releases
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$PROJECT_DIR/release"

echo "==> Packaging TabCircle Release..."

# 0. Sanity checks
if [ ! -f "$PROJECT_DIR/LICENSE" ] || [ ! -f "$PROJECT_DIR/README.md" ]; then
    echo "Error: LICENSE or README.md missing from $PROJECT_DIR" >&2
    exit 1
fi
if [ ! -f "$PROJECT_DIR/extension/manifest.json" ]; then
    echo "Error: extension/manifest.json missing from $PROJECT_DIR" >&2
    exit 1
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# 1. Package Chrome Extension
# Match macOS build naming and folder structure (TabCircle-Extension.zip with TabCircle-Extension/ root)
echo "--> Creating TabCircle-Extension.zip..."
TMP_STAGE="$(mktemp -d)"
mkdir -p "$TMP_STAGE/TabCircle-Extension"
cp -R "$PROJECT_DIR/extension/"* "$TMP_STAGE/TabCircle-Extension/"
rm -rf "$TMP_STAGE/TabCircle-Extension/tests"

(
    cd "$TMP_STAGE"
    zip -q -r "$RELEASE_DIR/TabCircle-Extension.zip" TabCircle-Extension/ \
        -x "*.DS_Store" "*/.*"
)
rm -rf "$TMP_STAGE"

# 2. Package Linux Helper Distribution
# Wrap in tabcircle-linux/ root folder matching README install instructions
echo "--> Creating tabcircle-linux.tar.gz..."
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 1.0.0)}"
echo "$VERSION" > "$PROJECT_DIR/linux-helper/VERSION"

TMP_LINUX_STAGE="$(mktemp -d)"
mkdir -p "$TMP_LINUX_STAGE/tabcircle-linux"
cp -R "$PROJECT_DIR/linux-helper" "$TMP_LINUX_STAGE/tabcircle-linux/"
mkdir -p "$TMP_LINUX_STAGE/tabcircle-linux/assets"
cp "$PROJECT_DIR/assets/icon-128.png" "$TMP_LINUX_STAGE/tabcircle-linux/assets/"
mkdir -p "$TMP_LINUX_STAGE/tabcircle-linux/scripts"
cp "$PROJECT_DIR/scripts/install-linux.sh" "$TMP_LINUX_STAGE/tabcircle-linux/scripts/"
cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/LICENSE" "$TMP_LINUX_STAGE/tabcircle-linux/"
find "$TMP_LINUX_STAGE/tabcircle-linux" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$TMP_LINUX_STAGE/tabcircle-linux" -name "*.pyc" -delete 2>/dev/null || true

(
    cd "$TMP_LINUX_STAGE"
    tar -czf "$RELEASE_DIR/tabcircle-linux.tar.gz" tabcircle-linux/
)
rm -rf "$TMP_LINUX_STAGE"

# 3. Generate SHA256 Checksums
echo "--> Generating checksums..."
(
    cd "$RELEASE_DIR"
    sha256sum TabCircle-Extension.zip tabcircle-linux.tar.gz > checksums.txt
)

echo ""
echo "========================================="
echo "  Release Artifacts Ready in release/    "
echo "========================================="
ls -lh "$RELEASE_DIR"
echo ""
cat "$RELEASE_DIR/checksums.txt"
