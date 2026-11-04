#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/build/MenuTools.app"
TARGET_APP="/Applications/MenuTools.app"

if [ ! -d "$SOURCE_APP" ]; then
    echo "Build the app first: make release"
    exit 1
fi

# Same wait as run.sh: `open` while the old instance is still quitting returns -600.
killall MenuTools 2>/dev/null || true
for _ in {1..25}; do
    pgrep -x MenuTools >/dev/null 2>&1 || break
    sleep 0.2
done
if pgrep -x MenuTools >/dev/null 2>&1; then
    echo "MenuTools did not quit. Quit it from the menu bar, then run make install again." >&2
    exit 1
fi
ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

