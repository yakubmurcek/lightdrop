#!/usr/bin/env bash
# Build the LightDrop notch app (macOS, needs Xcode) into dist/LightDrop.app and
# dist/LightDrop-app.zip (universal, ad-hoc signed). install.sh fetches the zip.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64 --package-path mac
bin="$(swift build -c release --arch arm64 --arch x86_64 --package-path mac --show-bin-path)/LightDrop"
app=dist/LightDrop.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/LightDrop"
cp mac/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
rm -f dist/LightDrop-app.zip
ditto -c -k --keepParent "$app" dist/LightDrop-app.zip
ls -la dist/LightDrop-app.zip
