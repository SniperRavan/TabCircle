#!/bin/bash
# 开发时代替裸的 `swift run`：带上让链接器写对 SDK 版本的参数。
# 不带的话调试版二进制的 LC_BUILD_VERSION sdk 是 14.0，整个 app 长的是旧外观，
# 和打包版对不上（原因见 scripts/build-app.sh 里 SWIFT_SDK_FLAGS 那段）。
set -euo pipefail
cd "$(dirname "$0")/../helper"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
exec swift run -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH" "$@"
