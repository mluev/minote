#!/usr/bin/env bash
# Compiles the iOS app for Mac Catalyst and packages it as build/Minote iOS Preview.app.
# This checks the iOS code with the real UIKit/SwiftUI and lets the iPad layout
# run on this Mac. Shipping builds for iPhone/iPad come from Xcode (project.yml).
#
#   scripts/build-ios-preview.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

RUN=false
[[ "${1:-}" == "--run" ]] && RUN=true

setting() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" Support/Minote.xcconfig | head -1; }
TARGET="arm64-apple-ios$(setting IPHONEOS_DEPLOYMENT_TARGET)-macabi"
SDK="$(xcrun --show-sdk-path)"
APP="build/Minote iOS Preview.app"

# Shared modules, built by SwiftPM for the Catalyst triple.
swift build -c release --triple "$TARGET" --target MinoteEditor
BIN=".build/out/Products/Release-maccatalyst"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
swiftc -target "$TARGET" -sdk "$SDK" -O -swift-version 6 -parse-as-library \
  -default-isolation MainActor \
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift" \
  -I "$BIN" \
  Apps/iOS/*.swift \
  "$BIN/MinoteKit.o" "$BIN/MinoteEditor.o" \
  -o "$APP/Contents/MacOS/Minote"

INFO="$APP/Contents/Info.plist"
cp Support/iOS-Info.plist "$INFO"
for KEY in PRODUCT_NAME MARKETING_VERSION CURRENT_PROJECT_VERSION; do
  sed -i '' "s|\$($KEY)|$(setting "$KEY")|g" "$INFO"
done
sed -i '' "s|\$(EXECUTABLE_NAME)|Minote|g; s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$(setting PRODUCT_BUNDLE_IDENTIFIER).ios-preview|g" "$INFO"
# Catalyst wants macOS bundle keys instead of the iOS-only ones.
plutil -remove LSRequiresIPhoneOS "$INFO"
plutil -replace LSMinimumSystemVersion -string "$(setting MACOSX_DEPLOYMENT_TARGET)" "$INFO"
plutil -replace UIDeviceFamily -json '[2, 6]' "$INFO"
plutil -replace CFBundleIconFile -string AppIcon "$INFO"
plutil -lint "$INFO" >/dev/null

cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
cp Resources/AppIcon.icns Support/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none --entitlements Support/Minote.entitlements "$APP"
echo "Built $APP"

if $RUN; then
  osascript -e 'tell application id "com.mlutfullaev.minote.ios-preview" to quit' >/dev/null 2>&1 || true
  sleep 0.5
  open "$APP"
fi
