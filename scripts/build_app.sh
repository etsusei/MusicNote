#!/bin/zsh
# Builds dist/Musicnote.app from the Swift package (no Xcode needed).
# Usage: scripts/build_app.sh [debug|release]
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"
APP="$ROOT/dist/Musicnote.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Musicnote
swift build -c "$CONFIG" --product musicnote-separate
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Musicnote" "$APP/Contents/MacOS/Musicnote"
cp "$BIN/musicnote-separate" "$APP/Contents/MacOS/musicnote-separate"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.etsusei.musicnote</string>
  <key>CFBundleName</key><string>Musicnote</string>
  <key>CFBundleDisplayName</key><string>Musicnote</string>
  <key>CFBundleExecutable</key><string>Musicnote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>用于在终端中打开 Claude Code 官方登录。</string>
  <key>MusicnoteProjectRoot</key><string>$ROOT</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
