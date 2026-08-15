#!/bin/bash
set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

failures=0

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        printf "[ok]   %-18s %s\n" "$1" "$(command -v "$1")"
    else
        printf "[miss] %-18s required\n" "$1"
        failures=$((failures + 1))
    fi
}

echo "MenuTools development environment"
check_command swift
check_command xcrun
check_command codesign
check_command ffmpeg

swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
sdk_path="$(xcrun --show-sdk-path 2>/dev/null || true)"
sdk_version="$(xcrun --show-sdk-version 2>/dev/null || true)"
sdk_swift_version=""

if [ -n "$sdk_path" ]; then
    swift_interface="$(find "$sdk_path/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print 2>/dev/null | head -n 1)"
    if [ -n "$swift_interface" ]; then
        sdk_swift_version="$(sed -n 's#// swift-compiler-version: Apple Swift version \([0-9][0-9.]*\).*#\1#p' "$swift_interface" | head -n 1)"
    fi
fi

printf "[info] %-18s %s\n" "Swift" "${swift_version:-unknown}"
printf "[info] %-18s %s (%s)\n" "macOS SDK" "${sdk_version:-unknown}" "${sdk_swift_version:-unknown Swift}"

if [ -n "$swift_version" ] && [ -n "$sdk_swift_version" ] && [ "$swift_version" != "$sdk_swift_version" ]; then
    echo "[warn] Swift compiler and SDK were built by different Swift versions."
    echo "       The build script will use compiler compatibility mode. Full Xcode remains recommended."
fi

if [ -x "build/MenuTools.app/Contents/MacOS/MenuTools" ]; then
    requirement="$(codesign -d -r- build/MenuTools.app 2>&1 | tail -n 1)"
    printf "[info] %-18s %s\n" "Code requirement" "$requirement"
fi

if [ "$failures" -gt 0 ]; then
    echo "Doctor found $failures blocking issue(s)."
    exit 1
fi

echo "Environment is ready."
