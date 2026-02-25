#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AP Switcher"
BUNDLE_ID="io.github.infinityanalytics.APSwitcher"

CONFIGURATION="${1:-debug}" # debug | release
if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
STAGING_APP="$BUILD_DIR/$APP_NAME.app"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICNS_FILE="$BUILD_DIR/AppIcon.icns"
BUILD_TS="$(date +%Y%m%d%H%M%S)"

echo "Building ($CONFIGURATION)…"
swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --show-bin-path)"
BIN="$BIN_DIR/APSwitcher"
ENTITLEMENTS="$BIN_DIR/APSwitcher-entitlement.plist"

if [[ ! -f "$BIN" ]]; then
  echo "Expected binary not found: $BIN" >&2
  exit 1
fi

rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS"

cp -f "$BIN" "$STAGING_APP/Contents/MacOS/APSwitcher"

echo "Generating app icon…"
rm -rf "$ICONSET_DIR" "$ICNS_FILE"
swift "$ROOT_DIR/scripts/generate-icon.swift" "$ICONSET_DIR"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"
mkdir -p "$STAGING_APP/Contents/Resources"
cp -f "$ICNS_FILE" "$STAGING_APP/Contents/Resources/AppIcon.icns"

cat > "$STAGING_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>APSwitcher</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_TS}</string>
  <key>BuildTimestamp</key>
  <string>${BUILD_TS}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>AP Switcher needs location access to read WiFi network names and identify access points.</string>
  <key>NSLocationUsageDescription</key>
  <string>AP Switcher needs location access to read WiFi network names and identify access points.</string>
</dict>
</plist>
EOF

echo "Signing (ad-hoc)…"
if [[ -f "$ENTITLEMENTS" ]]; then
  /usr/bin/codesign --force --deep --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$STAGING_APP"
else
  /usr/bin/codesign --force --deep --sign - --timestamp=none "$STAGING_APP"
fi

DEST_APP="/Applications/$APP_NAME.app"
echo "Installing to ${DEST_APP}..."
if [[ -w "/Applications" ]]; then
  rm -rf "$DEST_APP"
  /usr/bin/ditto "$STAGING_APP" "$DEST_APP"
  rm -rf "$DEST_APP/.cursor" 2>/dev/null || true
  /usr/bin/xattr -cr "$DEST_APP" 2>/dev/null || true
elif [[ -t 0 ]]; then
  echo "Admin permission required."
  /usr/bin/sudo /bin/rm -rf "$DEST_APP"
  /usr/bin/sudo /usr/bin/ditto "$STAGING_APP" "$DEST_APP"
  /usr/bin/sudo /bin/rm -rf "$DEST_APP/.cursor" 2>/dev/null || true
  /usr/bin/sudo /usr/bin/xattr -cr "$DEST_APP" 2>/dev/null || true
else
  echo "Admin permission required, but sudo can't prompt here." >&2
  echo "Run this from a normal Terminal so sudo can ask for a password:" >&2
  echo "  $0 $CONFIGURATION" >&2
  exit 1
fi

touch "$DEST_APP"
echo "Done. Quit/relaunch '$APP_NAME' if it was running."
