#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
OUTPUT_DIR="${PROJECT_DIR:h:h}/outputs"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/HejsPets.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"

mkdir -p "$OUTPUT_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

"$SWIFTC" \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -O \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -framework AppKit \
  -framework CoreImage \
  -framework Vision \
  -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/Sources/HejPets.swift" \
  -o "$APP_DIR/Contents/MacOS/HejsPets"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
