#!/bin/bash
# Builds one thin binary per architecture, signs each, signs the updates for
# Sparkle, publishes a GitHub release and refreshes both appcast feeds.
#
#   scripts/release.sh 0.2.2
#
# Optional: NOTARY_PROFILE=<keychain profile> to notarize before packaging.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version>}
REQUESTED_BUILD=${2:-}

MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
PATCH=$(echo "$VERSION" | cut -d. -f3)
PATCH=${PATCH:-0}
# Sparkle compares CFBundleVersion, so the build must grow with the version.
BUILD=$((MAJOR * 10000 + MINOR * 100 + PATCH))
if [ -n "$REQUESTED_BUILD" ] && [ "$REQUESTED_BUILD" != "$BUILD" ]; then
  echo "Ignoring build $REQUESTED_BUILD; using $BUILD so updates always move forward." >&2
fi

TAG="v$VERSION"
REPO="Lexus2016/tacet"
SPARKLE_BIN=".tools/bin"
DIST="dist"
ARCHS_LIST=(arm64 x86_64)

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "Sparkle tools are missing. Expected $SPARKLE_BIN/generate_appcast" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit before releasing: the tag must match the build." >&2
  git status --short | head -10 >&2
  exit 1
fi

./scripts/bootstrap.sh >/dev/null
xcodegen generate --spec project.yml >/dev/null

rm -rf "$DIST" .release-*
mkdir -p "$DIST"

for ARCH in "${ARCHS_LIST[@]}"; do
  FEED="https://github.com/$REPO/releases/latest/download/appcast-$ARCH.xml"
  DERIVED=".release-$ARCH"
  APP="$DERIVED/Build/Products/Release/Tacet.app"

  echo "Building Tacet $VERSION ($BUILD) for ${ARCH}…"
  xcodebuild -project Tacet.xcodeproj -scheme Tacet -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    TACET_FEED_URL="$FEED" \
    build > "/tmp/tacet-release-$ARCH.log" 2>&1 || {
      echo "Build failed for $ARCH:" >&2
      grep -E "error:" "/tmp/tacet-release-$ARCH.log" | head -20 >&2
      exit 1
    }

  [ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

  echo "Signing check for ${ARCH}…"
  codesign --verify --deep --strict "$APP" || { echo "Signature is not valid" >&2; exit 1; }
  SIGNATURE_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1 || true)
  case "$SIGNATURE_INFO" in
    *"Authority=Developer ID Application"*) ;;
    *)
      echo "The app is not signed with a Developer ID; refusing to publish." >&2
      exit 1
      ;;
  esac
  ARCH_INFO=$(lipo -info "$APP/Contents/MacOS/Tacet")
  case "$ARCH_INFO" in
    *"$ARCH"*) ;;
    *) echo "Wrong architecture for ${ARCH}: $ARCH_INFO" >&2; exit 1 ;;
  esac

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing ${ARCH}…"
    ditto -c -k --keepParent "$APP" "$DIST/notarize-$ARCH.zip"
    xcrun notarytool submit "$DIST/notarize-$ARCH.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$DIST/notarize-$ARCH.zip"
  fi

  ZIP="$DIST/Tacet-$VERSION-$ARCH.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  hdiutil create -volname "Tacet" -srcfolder "$APP" -ov -format UDZO "$DIST/Tacet-$VERSION-$ARCH.dmg" >/dev/null

  mkdir -p "$DIST/appcast-$ARCH"
  cp "$ZIP" "$DIST/appcast-$ARCH/"
  "$SPARKLE_BIN/generate_appcast" "$DIST/appcast-$ARCH" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO"
  cp "$DIST/appcast-$ARCH/appcast.xml" "$DIST/appcast-$ARCH.xml"

  if ! grep -q "sparkle:edSignature=" "$DIST/appcast-$ARCH.xml"; then
    echo "The $ARCH appcast has no EdDSA signature; Sparkle would reject it." >&2
    exit 1
  fi
done

echo "Tagging ${TAG}…"
git tag -f -a "$TAG" -m "Tacet $VERSION"
git push -f origin "$TAG"

echo "Publishing ${TAG}…"
ASSETS=("$DIST/Tacet-$VERSION-arm64.zip" "$DIST/Tacet-$VERSION-arm64.dmg" \
        "$DIST/Tacet-$VERSION-x86_64.zip" "$DIST/Tacet-$VERSION-x86_64.dmg" \
        "$DIST/appcast-arm64.xml" "$DIST/appcast-x86_64.xml")

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "Tacet $VERSION" \
    --notes "Tacet $VERSION. Apple Silicon and Intel builds, each updating from its own feed."
else
  gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "Tacet $VERSION" --verify-tag \
    --notes "Tacet $VERSION. Apple Silicon and Intel builds, each updating from its own feed."
fi

echo
echo "Release:     https://github.com/$REPO/releases/tag/$TAG"
echo "arm64 feed:  https://github.com/$REPO/releases/latest/download/appcast-arm64.xml"
echo "x86_64 feed: https://github.com/$REPO/releases/latest/download/appcast-x86_64.xml"
