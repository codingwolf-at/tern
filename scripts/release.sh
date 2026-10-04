#!/bin/bash
# Builds Tern (Release) from the terminal and packages it as a distributable DMG.
# No Xcode UI required, no third-party tools — xcodebuild + hdiutil only.
#
#   scripts/release.sh
#
# Output:
#   dist/Tern-<marketing-version>.dmg   (e.g. dist/Tern-0.1.0.dmg)
#
# The version is read from the Xcode project (MARKETING_VERSION), never hardcoded.
#
# Signing: uses the project's existing Release signing configuration as-is
# (currently ad-hoc). Developer ID signing + notarization is a later step
# and will extend this script, not replace it.
set -euo pipefail

SCHEME="Tern"
CONFIG="Release"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build/release"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGING="$BUILD_DIR/dmg-staging"
DIST="$ROOT/dist"

echo "Building Tern Release..."
rm -rf "$DERIVED_DATA" "$STAGING"
mkdir -p "$STAGING" "$DIST"

VERSION="$(xcodebuild -project "$ROOT/Tern.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null | awk -F' = ' '$1 ~ /MARKETING_VERSION/ {print $2; exit}' | tr -d '[:space:]')"
if [ -z "$VERSION" ]; then
  echo "error: could not read MARKETING_VERSION from Xcode project" >&2
  exit 1
fi

DMG="$DIST/Tern-$VERSION.dmg"
rm -f "$DMG"

xcodebuild -project "$ROOT/Tern.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" build

echo "Locating built app..."
APP="$DERIVED_DATA/Build/Products/$CONFIG/Tern.app"
if [ ! -d "$APP" ]; then
  echo "error: expected app not found at $APP" >&2
  exit 1
fi

echo "Creating DMG..."
ditto "$APP" "$STAGING/Tern.app"
ln -s /Applications "$STAGING/Applications"
/usr/bin/hdiutil create -volname "Tern $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
/usr/bin/hdiutil verify "$DMG" >/dev/null

echo "Release created:"
echo "$DMG"
