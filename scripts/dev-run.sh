#!/bin/bash
# Replacement for bare `swift run` in dev: includes linker args to set SDK version correctly.
# Without this, the debug binary's LC_BUILD_VERSION sdk defaults to 14.0 and renders outdated UI.
set -euo pipefail
cd "$(dirname "$0")/../helper"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
exec swift run -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH" "$@"
