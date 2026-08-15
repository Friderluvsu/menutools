#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/MenuTools.app"

if [ ! -x "$APP_DIR/Contents/MacOS/MenuTools" ]; then
    echo "Build the app first: make release"
    exit 1
fi

killall MenuTools 2>/dev/null || true
open "$APP_DIR"

