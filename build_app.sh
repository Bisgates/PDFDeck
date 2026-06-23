#!/bin/bash
# Build a proper macOS .app bundle (release) so PDFDeck runs foregrounded with a Dock icon.
set -euo pipefail
cd "$(dirname "$0")"

# The Command Line Tools toolchain on this machine is in a broken state
# (duplicate SwiftBridging modulemap). Prefer Xcode's self-consistent toolchain.
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SWIFT=(swift)
[ -n "${DEVELOPER_DIR:-}" ] && SWIFT=(xcrun swift)

APP="PDFDeck.app"
BIN_NAME="PDFDeck"

echo "Building release…"
"${SWIFT[@]}" build -c release

BIN_PATH="$("${SWIFT[@]}" build -c release --show-bin-path)/$BIN_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

ICON_LINE=""
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_LINE='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>PDFDeck</string>
  <key>CFBundleDisplayName</key>     <string>PDFDeck</string>
  <key>CFBundleIdentifier</key>      <string>local.pdfdeck</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>PDFDeck</string>
$ICON_LINE
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>     <string>PDF Document</string>
      <key>CFBundleTypeRole</key>     <string>Viewer</string>
      <key>LSHandlerRank</key>        <string>Default</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Launch with: open $APP"
