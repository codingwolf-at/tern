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
# Signing: re-signs the built app with your Developer ID Application cert
# (hardened runtime + secure timestamp), then notarizes and staples the DMG so
# Gatekeeper opens it on other Macs. One-time setup:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials tern-notary --apple-id <id> --team-id <team>
# Override with SIGN_IDENTITY / NOTARY_PROFILE env vars.
set -euo pipefail

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tern-notary}"

SCHEME="Tern"
CONFIG="Release"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build/release"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGING="$BUILD_DIR/dmg-staging"
DIST="$ROOT/dist"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "error: no \"$SIGN_IDENTITY\" certificate in keychain (see setup at top of $0)" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: notarytool keychain profile \"$NOTARY_PROFILE\" missing or invalid (see setup at top of $0)" >&2
  exit 1
fi

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

echo "Signing with $SIGN_IDENTITY..."
# Inside-out: nested helper first, then the app bundle.
for BIN in "$APP"/Contents/Helpers/*; do
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BIN"
done
codesign --force --options runtime --timestamp --entitlements "$ROOT/Config/Tern.entitlements" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "Creating DMG..."
ditto "$APP" "$STAGING/Tern.app"
ln -s /Applications "$STAGING/Applications"
/usr/bin/hdiutil create -volname "Tern $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
/usr/bin/hdiutil verify "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "Notarizing (usually a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "Release created:"
echo "$DMG"
