#!/bin/bash
# Build Claudewatch.app from the Swift package, then zip it for sharing.
# Coworkers need nothing installed — the compiled binary links only system frameworks.
set -e
cd "$(dirname "$0")"
APP="Claudewatch.app"
rm -rf "$APP" Claudewatch.zip
mkdir -p "$APP/Contents/MacOS"

swift build -c release
cp "$(swift build -c release --show-bin-path)/claudewatch" "$APP/Contents/MacOS/claudewatch"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claudewatch</string>
  <key>CFBundleIdentifier</key><string>com.claudewatch.hud</string>
  <key>CFBundleExecutable</key><string>claudewatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Ad-hoc sign so Gatekeeper doesn't flag it as "damaged" on the build machine.
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
ditto -c -k --keepParent "$APP" Claudewatch.zip
echo "Built $APP  ->  Claudewatch.zip ($(du -h Claudewatch.zip | cut -f1))"
