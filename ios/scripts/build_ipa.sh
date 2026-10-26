#!/usr/bin/env bash
# Build AetherMix Pocket for a real iPhone and package an unsigned IPA that
# Sideloadly can sign. Runs on macOS (Xcode 15+) or a GitHub macOS runner.
#
#   ./scripts/build_ipa.sh
#
# Output: ios/dist/AetherMix-unsigned.ipa
# No Apple account, certificate or provisioning profile is needed here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== toolchain =="
xcodebuild -version
xcode-select -p

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "== installing xcodegen =="
    brew install xcodegen
  else
    echo "error: xcodegen is missing and Homebrew is not available" >&2
    exit 1
  fi
fi

echo "== project =="
xcodegen generate
xcodebuild -list -project AetherMix.xcodeproj

echo "== build =="
rm -rf build dist
xcodebuild \
  -project AetherMix.xcodeproj \
  -scheme AetherMix \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ROOT/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$ROOT/build/Build/Products/Release-iphoneos/AetherMix.app"
if [ ! -d "$APP" ]; then
  echo "error: build produced no app bundle at $APP" >&2
  exit 1
fi

echo "== verify bundle =="
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")
echo "bundle id: $BUNDLE_ID"
echo "executable: $EXE"
ARCHS=$(lipo -archs "$APP/$EXE")
echo "architectures: $ARCHS"
case "$ARCHS" in
  *arm64*) ;;
  *) echo "error: no arm64 slice; Sideloadly cannot install this" >&2; exit 1 ;;
esac
/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$APP/Info.plist" | grep -q audio \
  || { echo "error: UIBackgroundModes audio missing" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$APP/Info.plist" >/dev/null \
  || { echo "error: local network usage description missing" >&2; exit 1; }
test -f "$APP/AppIcon60x60@2x.png" || echo "warning: no rendered app icon in the bundle"

echo "== package =="
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload" "$ROOT/dist"
ditto "$APP" "$STAGE/Payload/AetherMix.app"
(cd "$STAGE" && /usr/bin/zip -qry "$ROOT/dist/AetherMix-unsigned.ipa" Payload)
rm -rf "$STAGE"
unzip -t "$ROOT/dist/AetherMix-unsigned.ipa" >/dev/null
echo "ipa: $ROOT/dist/AetherMix-unsigned.ipa"
ls -lh "$ROOT/dist/AetherMix-unsigned.ipa"
shasum -a 256 "$ROOT/dist/AetherMix-unsigned.ipa"
