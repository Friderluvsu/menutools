#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$BUILD_DIR/MenuTools.app"
DMG_PATH="$BUILD_DIR/MenuTools.dmg"

echo "=== MenuTools DMG Packager ==="

# Check if MenuTools.app is built
if [ ! -d "$APP_PATH" ]; then
    echo "MenuTools.app not found. Building release bundle first..."
    "$PROJECT_DIR/scripts/build.sh" release
fi

STAGING_DIR="$(mktemp -d /tmp/menutools_dmg.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "Preparing DMG contents..."
cp -R "$APP_PATH" "$STAGING_DIR/MenuTools.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Include README or icon if available
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns" 2>/dev/null || true
fi

# Remove old DMG if exists
rm -f "$DMG_PATH"

echo "Creating compressed DMG image..."
hdiutil create \
    -volname "MenuTools" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Sign the DMG (ad-hoc)
if command -v codesign &>/dev/null; then
    codesign --force --sign - "$DMG_PATH" 2>/dev/null || true
fi

DMG_SIZE="$(du -sh "$DMG_PATH" | cut -f1)"
echo "✅ DMG created successfully: $DMG_PATH ($DMG_SIZE)"
