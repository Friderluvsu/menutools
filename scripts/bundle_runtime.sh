#!/bin/bash
set -euo pipefail

APP_DIR="${1:?Usage: bundle_runtime.sh /path/to/MenuTools.app}"
CONTENTS_DIR="$APP_DIR/Contents"
BIN_DIR="$CONTENTS_DIR/Resources/bin"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
LICENSES_DIR="$CONTENTS_DIR/Resources/Licenses"
VERSIONS_FILE="$CONTENTS_DIR/Resources/runtime-versions.txt"

mkdir -p "$BIN_DIR" "$FRAMEWORKS_DIR" "$LICENSES_DIR"
: > "$VERSIONS_FILE"

copy_tool() {
    local tool="$1"
    local source_path
    source_path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -z "$source_path" ] || [ ! -x "$source_path" ]; then
        echo "Missing runtime tool: $tool" >&2
        exit 1
    fi
    cp -L "$source_path" "$BIN_DIR/$tool"
    chmod 755 "$BIN_DIR/$tool"
}

copy_tool ffmpeg
copy_tool spoofdpi

"$BIN_DIR/ffmpeg" -version 2>/dev/null | head -n 1 >> "$VERSIONS_FILE" || true
"$BIN_DIR/spoofdpi" --version 2>/dev/null | head -n 1 >> "$VERSIONS_FILE" || true
codesign --remove-signature "$BIN_DIR/ffmpeg" 2>/dev/null || true

ffmpeg_prefix="$(cd "$(dirname "$(command -v ffmpeg)")/../Cellar/ffmpeg" 2>/dev/null && pwd -P || true)"
spoofdpi_prefix="$(cd "$(dirname "$(command -v spoofdpi)")/../Cellar/spoofdpi" 2>/dev/null && pwd -P || true)"

if [ -n "$ffmpeg_prefix" ]; then
    find "$ffmpeg_prefix" -maxdepth 2 -type f \( -name 'COPYING*' -o -name 'LICENSE*' \) \
        -exec cp {} "$LICENSES_DIR/" \;
fi
if [ -n "$spoofdpi_prefix" ]; then
    spoof_license="$(find "$spoofdpi_prefix" -maxdepth 2 -type f -name 'LICENSE*' | head -n 1)"
    if [ -n "$spoof_license" ]; then
        cp "$spoof_license" "$LICENSES_DIR/SpoofDPI-LICENSE"
    fi
fi

queue=("$BIN_DIR/ffmpeg")
queue_index=0
deps_file="$(mktemp "${TMPDIR:-/tmp}/menutools-deps.XXXXXX")"
trap 'rm -f "$deps_file"' EXIT

while [ "$queue_index" -lt "${#queue[@]}" ]; do
    target="${queue[$queue_index]}"
    queue_index=$((queue_index + 1))

    otool -L "$target" | sed '1d' | awk '{print $1}' > "$deps_file"
    while IFS= read -r dependency; do
        case "$dependency" in
            /opt/homebrew/*|/usr/local/*)
                dependency_name="$(basename "$dependency")"
                bundled_dependency="$FRAMEWORKS_DIR/$dependency_name"
                if [ ! -f "$bundled_dependency" ]; then
                    cp -L "$dependency" "$bundled_dependency"
                    chmod u+w "$bundled_dependency"
                    codesign --remove-signature "$bundled_dependency" 2>/dev/null || true
                    queue+=("$bundled_dependency")
                fi
                ;;
        esac
    done < "$deps_file"
done

for target in "${queue[@]}"; do
    otool -L "$target" | sed '1d' | awk '{print $1}' > "$deps_file"
    while IFS= read -r dependency; do
        case "$dependency" in
            /opt/homebrew/*|/usr/local/*)
                dependency_name="$(basename "$dependency")"
                if [ "$target" = "$BIN_DIR/ffmpeg" ]; then
                    replacement="@loader_path/../../Frameworks/$dependency_name"
                else
                    replacement="@loader_path/$dependency_name"
                fi
                install_name_tool -change "$dependency" "$replacement" "$target"
                ;;
        esac
    done < "$deps_file"

    case "$target" in
        "$FRAMEWORKS_DIR"/*.dylib)
            install_name_tool -id "@loader_path/$(basename "$target")" "$target"
            ;;
    esac
done

echo "Bundled ffmpeg, SpoofDPI and ${#queue[@]} FFmpeg runtime files."
