#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/dist/ClipVault.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/ClipVault "$app/Contents/MacOS/ClipVault"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.clipvault.app</string>
    <key>CFBundleName</key><string>ClipVault</string>
    <key>CFBundleDisplayName</key><string>ClipVault</string>
    <key>CFBundleExecutable</key><string>ClipVault</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.clipvault.app "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
