#!/bin/zsh
# Releases Grove: tags MARKETING_VERSION from project.yml, builds a Developer ID signed and
# notarized Grove.app from a clean checkout of that tag, publishes it as a GitHub release and
# bumps the cask in the Homebrew tap.
#
# To release: bump MARKETING_VERSION in project.yml, commit and push to main, then run this.
# An existing tag is never overwritten; the script stops if v<version> already exists.
#
# One-time setup:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id Y26PAS9QN8
#      (use an app-specific password from account.apple.com)
#   3. git clone https://github.com/mburisch/homebrew-tap.git ~/src/homebrew-tap
#   4. brew install xcodegen yq gh
#
# Usage: scripts/release.sh [--dry-run] [--skip-notarize]
#   --dry-run        build, sign and notarize HEAD; don't tag, push or publish anything
#   --skip-notarize  skip notarization (implies nothing is published)
set -euo pipefail

TEAM_ID="${TEAM_ID:-Y26PAS9QN8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
TAP_DIR="${TAP_DIR:-$HOME/src/homebrew-tap}"
CASK="$TAP_DIR/Casks/grove.rb"
DRY_RUN=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
# An unnotarized build must never be published.
(( SKIP_NOTARIZE )) && DRY_RUN=1

fail() { echo "error: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build/release"
SRC="$BUILD/src"
DIST="$ROOT/dist"

echo "==> Preflight"
for tool in xcodegen yq gh; do
  command -v $tool >/dev/null || fail "$tool is not installed (brew install $tool)"
done
[[ "$(git branch --show-current)" == main ]] || fail "not on main"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in sync with origin/main"

VERSION=$(yq -r '.targets.Grove.settings.base.MARKETING_VERSION' project.yml)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "bad MARKETING_VERSION in project.yml: $VERSION"
TAG="v$VERSION"
ZIP="$DIST/Grove-$VERSION.zip"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists — bump MARKETING_VERSION in project.yml"
fi
if (( ! SKIP_NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notary profile '$NOTARY_PROFILE' is missing (see setup at the top of this script)"
fi
if (( ! DRY_RUN )); then
  [[ -f "$CASK" ]] || fail "no cask at $CASK (set TAP_DIR)"
  [[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || fail "tap checkout $TAP_DIR is not clean"
fi

TAGGED=0
PUSHED=0
cleanup() {
  git -C "$ROOT" worktree remove --force "$SRC" 2>/dev/null || true
  # A tag that never left this machine belongs to a failed release; remove it so it can be retried.
  if (( TAGGED && ! PUSHED )); then
    git -C "$ROOT" tag -d "$TAG" >/dev/null && echo "==> Removed unpublished local tag $TAG"
  fi
}
trap cleanup EXIT

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"
git worktree prune

if (( DRY_RUN )); then
  REF=HEAD
  echo "==> Dry run of Grove $VERSION at $(git rev-parse --short HEAD)"
else
  git tag -a "$TAG" -m "Grove $VERSION"
  TAGGED=1
  REF="$TAG"
  echo "==> Tagged $TAG"
fi

echo "==> Checking out $REF into a clean worktree"
git worktree add --quiet --detach "$SRC" "$REF"
git worktree list | grep -q "^$SRC " || fail "worktree $SRC was not created"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$(git rev-parse "$REF^{commit}")" ]] \
  || fail "worktree is not at $REF"
BUILD_NUMBER=$(git -C "$SRC" rev-list --count HEAD)

echo "==> Archiving Grove $VERSION ($BUILD_NUMBER)"
(cd "$SRC" && xcodegen generate --quiet)
xcodebuild archive \
  -project "$SRC/Grove.xcodeproj" -scheme Grove -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$BUILD/Grove.xcarchive" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

APP="$BUILD/Grove.app"
ditto "$BUILD/Grove.xcarchive/Products/Applications/Grove.app" "$APP"
codesign --verify --deep --strict "$APP"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$BUILT_VERSION" == "$VERSION" ]] || fail "app reports version $BUILT_VERSION, expected $VERSION"

if (( ! SKIP_NOTARIZE )); then
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" "$BUILD/Grove-notarize.zip"
  xcrun notarytool submit "$BUILD/Grove-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "==> $ZIP"
echo "    sha256 $SHA"

if (( DRY_RUN )); then
  echo "==> Dry run: nothing tagged or published"
  exit 0
fi

echo "==> Publishing $TAG"
git push origin "refs/tags/$TAG"
PUSHED=1
gh release create "$TAG" "$ZIP" --title "Grove $VERSION" --generate-notes --verify-tag

echo "==> Updating cask"
sed -i '' -E \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$CASK"
git -C "$TAP_DIR" commit --quiet -am "grove $VERSION"
git -C "$TAP_DIR" push --quiet
echo "==> Released Grove $VERSION"
