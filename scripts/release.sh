#!/bin/bash
# Builds a signed release, signs the update for Sparkle, publishes a GitHub
# release and refreshes the appcast the app reads on launch.
#
#   scripts/release.sh 0.2.0 2
#
# Optional: NOTARY_PROFILE=<keychain profile> to notarize before packaging.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> <build>}
BUILD=${2:?usage: scripts/release.sh <version> <build>}
TAG="v$VERSION"
REPO="Lexus2016/tacet"
SPARKLE_BIN=".tools/bin"
DIST="dist"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "Sparkle tools are missing. Expected $SPARKLE_BIN/generate_appcast" >&2
  echo "Download Sparkle-2.10.1.tar.xz and unpack it into .tools/" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit before releasing: the tag must match the build." >&2
  git status --short | head -10 >&2
  exit 1
fi

./scripts/bootstrap.sh >/dev/null
xcodegen generate --spec project.yml >/dev/null

rm -rf "$DIST" .release
mkdir -p "$DIST/appcast"

echo "Building Tacet $VERSION ($BUILD)…"
xcodebuild -project Tacet.xcodeproj -scheme Tacet -configuration Release \
  -derivedDataPath .release -destination 'platform=macOS,arch=arm64' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  build > /tmp/tacet-release-build.log 2>&1 || {
    echo "Build failed:" >&2
    grep -E "error:" /tmp/tacet-release-build.log | head -20 >&2
    exit 1
  }

APP=".release/Build/Products/Release/Tacet.app"
if [ ! -d "$APP" ]; then
  echo "No app at $APP" >&2
  exit 1
fi

echo "Signing check…"
codesign --verify --deep --strict "$APP" || { echo "Signature is not valid" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Notarizing…"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$DIST/notarize.zip"
fi

echo "Packaging…"
ZIP="$DIST/Tacet-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" "$DIST/appcast/"
hdiutil create -volname "Tacet" -srcfolder "$APP" -ov -format UDZO "$DIST/Tacet-$VERSION.dmg" >/dev/null

echo "Generating appcast…"
"$SPARKLE_BIN/generate_appcast" "$DIST/appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO"
cp "$DIST/appcast/appcast.xml" "$DIST/appcast.xml"

echo "Publishing ${TAG}…"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" "$DIST/Tacet-$VERSION.dmg" "$DIST/appcast.xml" \
    --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "Tacet $VERSION" \
    --notes "Tacet $VERSION. Download the DMG, or update from the app."
else
  gh release create "$TAG" "$ZIP" "$DIST/Tacet-$VERSION.dmg" "$DIST/appcast.xml" \
    --repo "$REPO" --title "Tacet $VERSION" \
    --notes "Tacet $VERSION. Download the DMG, or update from the app."
fi

git tag -f -a "$TAG" -m "Tacet $VERSION"
git push -f origin "$TAG"

echo
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "Feed:    https://github.com/$REPO/releases/latest/download/appcast.xml"
