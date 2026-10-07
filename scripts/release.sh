#!/bin/zsh
# Builds a Developer ID signed, notarized GitIt.app and zips it into dist/.
#
# One-time setup:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id Y26PAS9QN8
#      (use an app-specific password from account.apple.com)
#
# Usage: scripts/release.sh [--skip-notarize]
set -euo pipefail

TEAM_ID="${TEAM_ID:-Y26PAS9QN8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
ZIP="$DIST/GitIt-$VERSION.zip"

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

echo "==> Generating project"
xcodegen generate --quiet

echo "==> Archiving GitIt $VERSION"
xcodebuild archive \
  -project GitIt.xcodeproj -scheme GitIt -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$BUILD/GitIt.xcarchive" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  -quiet

APP="$BUILD/GitIt.app"
ditto "$BUILD/GitIt.xcarchive/Products/Applications/GitIt.app" "$APP"
codesign --verify --deep --strict "$APP"

if (( ! SKIP_NOTARIZE )); then
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" "$BUILD/GitIt-notarize.zip"
  xcrun notarytool submit "$BUILD/GitIt-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"
