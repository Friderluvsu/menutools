#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/build/MenuTools.app"

killall MenuTools 2>/dev/null || true

render_preview() {
    local output_name="$1"
    shift
    local output_path="$PROJECT_DIR/build/$output_name"

    rm -f "$output_path"
    "$APP_PATH/Contents/MacOS/MenuTools" --render-preview "$output_path" "$@" || true

    for _ in {1..100}; do
        if [ -s "$output_path" ]; then
            echo "Rendered $output_path"
            return 0
        fi
        sleep 0.1
    done

    echo "Preview timed out: $output_path" >&2
    return 1
}

render_preview preview-dashboard.png
render_preview preview-settings.png --settings
render_preview preview-anti-sleep.png --anti-sleep-picker
