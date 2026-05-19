#!/usr/bin/env bash
set -euo pipefail

ROOT="/private/tmp/kwwk-activation-probe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/ActivationProbe/main.swift"
BUILD_DIR="$ROOT/build"
EXECUTABLE="$BUILD_DIR/ActivationProbe"

rm -rf "$ROOT"
mkdir -p "$BUILD_DIR"

xcrun swiftc "$SOURCE" -o "$EXECUTABLE" -framework AppKit -framework ApplicationServices -framework Carbon

for key in A B C; do
  name="Probe${key}"
  bundle_id="com.kwwk.activationprobe.$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  app_dir="$ROOT/${name}.app"
  contents="$app_dir/Contents"
  macos="$contents/MacOS"

  mkdir -p "$macos"
  cp "$EXECUTABLE" "$macos/$name"
  chmod +x "$macos/$name"

  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$name</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleName</key>
  <string>$name</string>
  <key>CFBundleDisplayName</key>
  <string>$name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
done

echo "Built Probe apps in $ROOT"
