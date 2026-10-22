#!/bin/sh
# Builds AgentGlance.app (menu bar only, no Dock icon) into ./build/.
#   UNIVERSAL=1  build for arm64 + x86_64 (needs Xcode; used by the release workflow)
set -e
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/AgentGlanceCore/Version.swift)
if [ "$UNIVERSAL" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64 --product AgentGlanceApp
  BIN=.build/apple/Products/Release/AgentGlanceApp
else
  swift build -c release --product AgentGlanceApp
  BIN=.build/release/AgentGlanceApp
fi
APP=build/AgentGlance.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AgentGlance"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AgentGlance</string>
  <key>CFBundleIdentifier</key><string>dev.agentglance.app</string>
  <key>CFBundleExecutable</key><string>AgentGlance</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION). Run: open $APP"
