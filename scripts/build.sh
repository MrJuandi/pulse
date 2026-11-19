#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
sdk="${SDKROOT:-}"
if [[ -z "$sdk" ]]; then
    sdk="$(xcode-select -p)/SDKs/MacOSX.sdk"
    if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --sdk macosx --show-sdk-path)"; fi
fi

sdk="$(cd "$sdk" && pwd -P)"
mkdir -p dist
# Sign outside synced folders, which can attach Finder metadata to app bundles.
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pulse-build.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
app="$temp_dir/Pulse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$temp_dir/Pulse.iconset"
cp Resources/Info.plist "$app/Contents/Info.plist"

xcrun swift -sdk "$sdk" scripts/make-icon.swift "$temp_dir/Pulse.png"
for size in 16 32 128 256 512; do
    double_size=$((size * 2))
    sips -z "$size" "$size" "$temp_dir/Pulse.png" \
        --out "$temp_dir/Pulse.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double_size" "$double_size" "$temp_dir/Pulse.png" \
        --out "$temp_dir/Pulse.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$temp_dir/Pulse.iconset" -o "$app/Contents/Resources/Pulse.icns"

build_slice() {
    xcrun swiftc -sdk "$sdk" -O -target "$1-apple-macosx15.0" \
        Sources/*.swift -lsqlite3 -o "$2"
}

if [[ "${PULSE_UNIVERSAL:-0}" == 1 ]]; then
    build_slice arm64 "$temp_dir/Pulse-arm64"
    build_slice x86_64 "$temp_dir/Pulse-x86_64"
    xcrun lipo -create "$temp_dir/Pulse-arm64" "$temp_dir/Pulse-x86_64" \
        -output "$app/Contents/MacOS/Pulse"
else
    build_slice "$(uname -m)" "$app/Contents/MacOS/Pulse"
fi
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
if [[ -e dist/Pulse.app ]]; then mv dist/Pulse.app "$temp_dir/previous.app"; fi
mv "$app" dist/Pulse.app
printf 'Built %s/dist/Pulse.app\n' "$root"
