#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/build/MenuTools.app"
TARGET_APP="/Applications/MenuTools.app"

if [ ! -d "$SOURCE_APP" ]; then
    echo "Build the app first: make release"
    exit 1
fi

killall MenuTools 2>/dev/null || true
ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

