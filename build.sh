#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/build}"
APP_DIR="$OUTPUT_DIR/Codex Meter.app"
MODULE_CACHE="$SCRIPT_DIR/.module-cache"
DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMPATIBLE_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
SDK_PATH="${SDKROOT:-$DEFAULT_SDK}"
ARCH="$(uname -m)"

# Some macOS beta Command Line Tools installations expose a newer default SDK
# than their bundled Swift compiler can read. Prefer the known-compatible SDK
# when it is present; SDKROOT can always be used to override this choice.
if [[ -z "${SDKROOT:-}" && -d "$COMPATIBLE_SDK" ]]; then
  SDK_PATH="$COMPATIBLE_SDK"
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target "$ARCH-apple-macos13.0" \
  -framework SwiftUI \
  -framework AppKit \
  "$SCRIPT_DIR/CodexMeter.swift" \
  -o "$APP_DIR/Contents/MacOS/CodexMeter"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/PkgInfo" "$APP_DIR/Contents/PkgInfo"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
