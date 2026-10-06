#!/usr/bin/env bash
# Builds Minote.app from the Swift package (no Xcode needed).
#
#   scripts/build-app.sh               release build into build/Minote.app (sandboxed, like the App Store build)
#   scripts/build-app.sh --debug       debug build
#   scripts/build-app.sh --universal   Apple silicon + Intel binary
#   scripts/build-app.sh --run         build, quit the running copy gracefully, launch
#
# Identity and version come from Support/Minote.xcconfig, shared with Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
RUN=false
UNIVERSAL=false
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --run) RUN=true ;;
    --universal) UNIVERSAL=true ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

# Read "KEY = value" lines from the xcconfig.
setting() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" Support/Minote.xcconfig | head -1; }
PRODUCT_NAME=$(setting PRODUCT_NAME)
BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)

APP="build/$PRODUCT_NAME.app"

if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift
fi

ARCHS=()
$UNIVERSAL && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product Minote ${ARCHS[@]+"${ARCHS[@]}"}
BINARY="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Minote"

# Never replace the bundle under a running copy: quit it first, through AppKit
# (not kill) so pending saves are flushed. Matched by path: an iOS simulator
# runs its own "Minote" process.
RUNNING="$PWD/$APP/Contents/MacOS/$PRODUCT_NAME"
if pgrep -qf "^$RUNNING"; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..100}; do pgrep -qf "^$RUNNING" || break; sleep 0.1; done
  if pgrep -qf "^$RUNNING"; then
    echo "Minote is still running (unsaved changes?). Quit it, then build again." >&2
    exit 1
  fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BINARY" "$APP/Contents/MacOS/$PRODUCT_NAME"
if [[ "$CONFIG" == release ]]; then
  strip -x "$APP/Contents/MacOS/$PRODUCT_NAME"
fi

# Info.plist with $(VARIABLES) filled in from the xcconfig.
INFO="$APP/Contents/Info.plist"
cp Support/Info.plist "$INFO"
for KEY in PRODUCT_NAME PRODUCT_BUNDLE_IDENTIFIER MARKETING_VERSION CURRENT_PROJECT_VERSION MACOSX_DEPLOYMENT_TARGET; do
  VALUE=$(setting "$KEY")
  sed -i '' "s|\$($KEY)|$VALUE|g" "$INFO"
done
plutil -lint "$INFO" >/dev/null

cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
cp Resources/AppIcon.icns Resources/Credits.rtf Support/PrivacyInfo.xcprivacy Support/container-migration.plist "$APP/Contents/Resources/"

# Ad-hoc signature with the App Store entitlements, so local builds run in the
# same sandbox as the shipping app.
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements Support/Minote.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($CONFIG$($UNIVERSAL && echo ", universal"))"

if $RUN; then
  open "$APP" 2>/dev/null || { sleep 1; open "$APP"; }
fi
