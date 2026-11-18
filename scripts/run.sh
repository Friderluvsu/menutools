#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/MenuTools.app"

if [ ! -x "$APP_DIR/Contents/MacOS/MenuTools" ]; then
    echo "Build the app first: make release"
    exit 1
fi

# killall only signals. The app quits on the main thread, and `open` during that
# window targets the dying process (Launch Services error -600, procNotFound).
killall MenuTools 2>/dev/null || true
for _ in {1..25}; do
    pgrep -x MenuTools >/dev/null 2>&1 || break
    sleep 0.2
done
if pgrep -x MenuTools >/dev/null 2>&1; then
    echo "MenuTools did not quit. Quit it from the menu bar, then run make run again." >&2
    exit 1
fi
open "$APP_DIR"

