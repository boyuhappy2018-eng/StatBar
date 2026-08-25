#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/StatBar.app"
CONTROLS_DIR="$APP_DIR/Contents/PlugIns/StatBarControls.appex"
DEFAULT_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
COMPAT_SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
SDK_PATH="${STATBAR_SDK_PATH:-$DEFAULT_SDK_PATH}"
if [[ -z "${STATBAR_SDK_PATH:-}" && -d "$COMPAT_SDK_PATH" ]]; then
  SDK_PATH="$COMPAT_SDK_PATH"
fi
CONTROLS_SDK_PATH="${STATBAR_CONTROLS_SDK_PATH:-$DEFAULT_SDK_PATH}"
CACHE_DIR="$BUILD_DIR/cache/clang"
CONTROLS_CACHE="$BUILD_DIR/cache/control-modules"
CONTROLS_OVERLAY="$BUILD_DIR/cache/control-sdk-overlay"
SWIFTPM_CACHE="$BUILD_DIR/cache/swiftpm"
SWIFTPM_CONFIG="$BUILD_DIR/cache/config"
SWIFTPM_SECURITY="$BUILD_DIR/cache/security"

cd "$PROJECT_DIR"
mkdir -p "$CACHE_DIR" "$CONTROLS_CACHE" "$SWIFTPM_CACHE" "$SWIFTPM_CONFIG" "$SWIFTPM_SECURITY"
touch "$BUILD_DIR/.metadata_never_index"
export SDKROOT="$SDK_PATH"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR"
SWIFT_ARGS=(--disable-sandbox --cache-path "$SWIFTPM_CACHE" --config-path "$SWIFTPM_CONFIG" --security-path "$SWIFTPM_SECURITY")
swift build "${SWIFT_ARGS[@]}" -c release --product StatBar
swift build "${SWIFT_ARGS[@]}" -c release --product StatBarSMCHelper

BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" -c release --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/StatBar" "$APP_DIR/Contents/MacOS/StatBar"
cp "$BIN_DIR/StatBarSMCHelper" "$APP_DIR/Contents/Helpers/StatBarSMCHelper"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/com.statbar.fan-watchdog.plist" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"

CONTROLS_BUILT=0
CONTROLS_SDK_VERSION="$(plutil -extract Version raw "$CONTROLS_SDK_PATH/SDKSettings.plist" 2>/dev/null || echo 0)"
CONTROLS_SDK_MAJOR="${CONTROLS_SDK_VERSION%%.*}"
if [[ "$CONTROLS_SDK_MAJOR" == <-> && "$CONTROLS_SDK_MAJOR" -ge 26 ]]; then
  CONTROLS_BUILT=1
  mkdir -p "$CONTROLS_DIR/Contents/MacOS"
  MACHINE_ARCH="$(uname -m)"
  rm -rf "$CONTROLS_OVERLAY"
  mkdir -p "$CONTROLS_OVERLAY"
  cp -R "$CONTROLS_SDK_PATH/usr/lib/swift/Swift.swiftmodule" "$CONTROLS_OVERLAY/"
  COMPILER_TAGS="$(xcrun swiftc --version | sed -n 's/.*(\(swiftlang-[^)]*\)).*/\1/p')"
  for INTERFACE in "$CONTROLS_OVERLAY"/Swift.swiftmodule/*.swiftinterface; do
    sed -i '' -E "/^\/\/ swift-compiler-version:/ s/\(swiftlang-[^)]*\)/($COMPILER_TAGS)/" "$INTERFACE"
  done
  xcrun swiftc -parse-as-library -O \
    -module-cache-path "$CONTROLS_CACHE" -I "$CONTROLS_OVERLAY" \
    -sdk "$CONTROLS_SDK_PATH" -target "$MACHINE_ARCH-apple-macos26.0" \
    "$PROJECT_DIR/Sources/StatBarControls/StatBarControls.swift" \
    -o "$CONTROLS_DIR/Contents/MacOS/StatBarControls"
  cp "$PROJECT_DIR/Resources/Controls-Info.plist" "$CONTROLS_DIR/Contents/Info.plist"
else
  echo "Skipping Control Center extension (macOS 26 SDK not available)."
fi

chmod 755 "$APP_DIR/Contents/MacOS/StatBar" "$APP_DIR/Contents/Helpers/StatBarSMCHelper"
if [[ "$CONTROLS_BUILT" -eq 1 ]]; then
  chmod 755 "$CONTROLS_DIR/Contents/MacOS/StatBarControls"
fi
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR/Contents/Helpers/StatBarSMCHelper"
if [[ "$CONTROLS_BUILT" -eq 1 ]]; then
  codesign --force --sign - "$CONTROLS_DIR"
fi
for attempt in 1 2 3; do
  xattr -cr "$APP_DIR"
  if codesign --force --sign - --identifier com.statbar.app "$APP_DIR"; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    exit 1
  fi
done

echo "$APP_DIR"
