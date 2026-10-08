#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"

case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]"; exit 2 ;;
esac

cd "$PROJECT_DIR"
mkdir -p "$MODULE_CACHE"

if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk" ] && [ -z "${SDKROOT:-}" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk"
fi

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

BUILD_ARGUMENTS=(--configuration "$CONFIGURATION" --disable-sandbox)

swift_version="$(swift --version 2>/dev/null | sed -n 's/.*(swiftlang-\([0-9.]*\).*/\1/p' | head -n 1)"
sdk_path="$(xcrun --show-sdk-path 2>/dev/null || true)"
sdk_swift_version=""

if [ -n "$sdk_path" ]; then
    swift_interface="$(find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print 2>/dev/null | head -n 1)"
    if [ -n "$swift_interface" ]; then
        sdk_swift_version="$(sed -n 's#.*(swiftlang-\([0-9.]*\).*#\1#p' "$swift_interface" | head -n 1)"
    fi
fi

if [ -n "$swift_version" ] && [ -n "$sdk_swift_version" ] && [ "$swift_version" != "$sdk_swift_version" ]; then
    echo "Using Swift compatibility mode ($swift_version compiler / $sdk_swift_version SDK)."
    BUILD_ARGUMENTS+=(-Xswiftc -Xfrontend -Xswiftc -experimental-allow-module-with-compiler-errors)
fi

swift build "${BUILD_ARGUMENTS[@]}"

APP_DIR="$PROJECT_DIR/build/MenuTools.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR_PATH="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR_PATH/MenuTools"
HELPER_PATH="$BIN_DIR_PATH/menutools-smc-helper"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/bin"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/MenuTools"
chmod +x "$MACOS_DIR/MenuTools"

if [ -f "$HELPER_PATH" ]; then
    cp "$HELPER_PATH" "$RESOURCES_DIR/bin/menutools-smc-helper"
    chmod 755 "$RESOURCES_DIR/bin/menutools-smc-helper"
fi

cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -d "$PROJECT_DIR/Resources" ]; then
    cp -R "$PROJECT_DIR/Resources/." "$RESOURCES_DIR/"
fi

"$PROJECT_DIR/scripts/bundle_runtime.sh" "$APP_DIR"

while IFS= read -r nested_code; do
    codesign --force --sign - "$nested_code"
done < <(find "$CONTENTS_DIR/Frameworks" "$RESOURCES_DIR/bin" -type f -print)

codesign \
    --force \
    --deep \
    --sign - \
    --identifier com.frider.MenuTools \
    --requirements '=designated => identifier "com.frider.MenuTools"' \
    "$APP_DIR"

codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR ($CONFIGURATION)"
