#!/bin/bash
# Builds one thin binary per architecture, signs each, signs the updates for
# Sparkle, publishes a GitHub release and refreshes both appcast feeds.
#
#   scripts/release.sh 0.2.2
#
# Set NOTARY_PROFILE to override the Keychain profile.
# NOTARY_PROFILE дає змогу вказати інший профіль Ключаря.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <major.minor.patch>}
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
  echo "Expected major.minor.patch, with minor and patch below 100." >&2
  exit 1
fi
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD=$((MAJOR * 10000 + MINOR * 100 + PATCH))

TAG="v$VERSION"
REPO="Lexus2016/tacet"
SPARKLE_BIN=".tools/bin"
ARCHS_LIST=(arm64 x86_64)
DMG_WIDTH=660
DMG_HEIGHT=400
NOTARY_PROFILE=${NOTARY_PROFILE:-murable}

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "Sparkle tools are missing. Expected $SPARKLE_BIN/generate_appcast" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit before releasing: the tag must match the build." >&2
  git status --short >&2
  exit 1
fi

HEAD_SHA=$(git rev-parse HEAD)
REMOTE_HEAD=$(git ls-remote --exit-code origin refs/heads/lite | cut -f1)
if [ "$HEAD_SHA" != "$REMOTE_HEAD" ]; then
  echo "Push the candidate to origin/lite before releasing." >&2
  exit 1
fi
REMOTE_TAG=$(git ls-remote origin "refs/tags/$TAG")
if git show-ref --verify --quiet "refs/tags/$TAG" || [ -n "$REMOTE_TAG" ]; then
  echo "$TAG already exists. Existing release tags and assets are immutable here." >&2
  exit 1
fi
LATEST_TAG=$(gh release view --repo "$REPO" --json tagName --jq .tagName)
if [[ ! "$LATEST_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
  echo "Cannot verify the version of the latest release: $LATEST_TAG" >&2
  exit 1
fi
IFS=. read -r LATEST_MAJOR LATEST_MINOR LATEST_PATCH <<< "${LATEST_TAG#v}"
if (( BUILD <= LATEST_MAJOR * 10000 + LATEST_MINOR * 100 + LATEST_PATCH )); then
  echo "Version $VERSION must be newer than $LATEST_TAG." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
  echo "Could not contact Apple using the '$NOTARY_PROFILE' notary profile." >&2
  exit 1
fi

EXPECTED_ED_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' Sources/Tacet/Resources/Info.plist)
if [ "$("$SPARKLE_BIN/generate_keys" -p)" != "$EXPECTED_ED_KEY" ]; then
  echo "The Sparkle key in Keychain does not match the key shipped with Tacet." >&2
  exit 1
fi

./scripts/bootstrap.sh >/dev/null
xcodegen generate --spec project.yml >/dev/null

mkdir -p dist
DIST=$(mktemp -d "$PWD/dist/tacet-$TAG.XXXXXXXX")
echo "Artifacts: $DIST"

for ARCH in "${ARCHS_LIST[@]}"; do
  BG="Assets/dmg-background-$ARCH.png"
  [ -f "$BG" ] || BG="Assets/dmg-background-arm64.png"
  BG_WIDTH=$(sips -g pixelWidth "$BG" | awk '/pixelWidth:/ {print $2}')
  BG_HEIGHT=$(sips -g pixelHeight "$BG" | awk '/pixelHeight:/ {print $2}')
  if [ "$BG_WIDTH" != "$DMG_WIDTH" ] || [ "$BG_HEIGHT" != "$DMG_HEIGHT" ]; then
    echo "Installer background $BG must be ${DMG_WIDTH}x${DMG_HEIGHT} pixels. Regenerate it with scripts/make-dmg-background.swift." >&2
    exit 1
  fi

  FEED="https://github.com/$REPO/releases/latest/download/appcast-$ARCH.xml"
  DERIVED=".release-$ARCH"
  APP="$DERIVED/Build/Products/Release/Tacet.app"

  echo "Building Tacet $VERSION ($BUILD) for ${ARCH}…"
  xcodebuild -project Tacet.xcodeproj -scheme Tacet -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    TACET_FEED_URL="$FEED" \
    build > "$DIST/build-$ARCH.log" 2>&1 || {
      echo "Build failed for $ARCH:" >&2
      tail -80 "$DIST/build-$ARCH.log" >&2
      exit 1
    }

  [ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

  echo "Re-signing embedded code for ${ARCH}…"
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [ -n "$IDENTITY" ] || { echo "No Developer ID Application identity" >&2; exit 1; }

  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SPARKLE" ]; then
    for item in \
      "$SPARKLE/Versions/B/Autoupdate" \
      "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
      "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
      "$SPARKLE/Versions/B/Updater.app" \
      "$SPARKLE"; do
      [ -e "$item" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$item"
    done
  fi
  codesign --force --timestamp --options runtime --sign "$IDENTITY" \
    --entitlements Sources/Tacet/Resources/Tacet.entitlements "$APP"

  echo "Signing check for ${ARCH}…"
  codesign --verify --deep --strict "$APP" || { echo "Signature is not valid" >&2; exit 1; }
  AUDIO_ENTITLEMENT=$(codesign -d --xml --entitlements - "$APP" 2>/dev/null | \
    plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - -)
  [ "$AUDIO_ENTITLEMENT" = "true" ] || { echo "Microphone entitlement is missing." >&2; exit 1; }
  SIGNATURE_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1 || true)
  case "$SIGNATURE_INFO" in
    *"Authority=Developer ID Application"*) ;;
    *)
      echo "The app is not signed with a Developer ID; refusing to publish." >&2
      exit 1
      ;;
  esac
  ARCH_INFO=$(lipo -archs "$APP/Contents/MacOS/Tacet")
  [ "$ARCH_INFO" = "$ARCH" ] || { echo "Wrong architecture: $ARCH_INFO" >&2; exit 1; }

  INFO="$APP/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")" = "$BUILD" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO")" = "$VERSION" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$INFO")" = "$FEED" ]

  echo "Notarizing ${ARCH}…"
  ditto -c -k --keepParent "$APP" "$DIST/notarize-$ARCH.zip"
  xcrun notarytool submit "$DIST/notarize-$ARCH.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$DIST/notarize-$ARCH.zip"

  ZIP="$DIST/Tacet-$VERSION-$ARCH.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"

  DMG="$DIST/Tacet-$VERSION-$ARCH.dmg"
  DMG_STAGE="$DIST/dmg-stage-$ARCH"
  mkdir -p "$DMG_STAGE"
  ditto "$APP" "$DMG_STAGE/Tacet.app"

  if command -v create-dmg >/dev/null 2>&1; then
    timeout 120 create-dmg \
      --volname "Tacet $VERSION" \
      --background "$BG" \
      --window-pos 200 120 \
      --window-size "$DMG_WIDTH" "$DMG_HEIGHT" \
      --icon-size 128 \
      --icon "Tacet.app" 180 200 \
      --hide-extension "Tacet.app" \
      --app-drop-link 480 200 \
      --no-internet-enable \
      "$DMG" "$DMG_STAGE" > "$DIST/dmg-$ARCH.log" 2>&1 || true
  fi

  if [ ! -f "$DMG" ]; then
    echo "create-dmg failed for ${ARCH}; using a plain image" >&2
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create -volname "Tacet $VERSION" -srcfolder "$DMG_STAGE" -format UDZO "$DMG" >/dev/null
  fi

  MOUNT="$DIST/mount-$ARCH"
  mkdir -p "$MOUNT"
  hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null
  trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
  [ -f "$MOUNT/Tacet.app/Contents/MacOS/Tacet" ]
  [ "$(readlink "$MOUNT/Applications")" = /Applications ]
  codesign --verify --deep --strict "$MOUNT/Tacet.app"
  hdiutil detach "$MOUNT" >/dev/null
  trap - EXIT

  echo "Signing and notarizing the ${ARCH} disk image…"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"

  mkdir -p "$DIST/appcast-$ARCH"
  cp "$ZIP" "$DIST/appcast-$ARCH/"
  "$SPARKLE_BIN/generate_appcast" "$DIST/appcast-$ARCH" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO"
  GENERATED=$(find "$DIST/appcast-$ARCH" -maxdepth 1 -name "*.xml" | head -1)
  [ -n "$GENERATED" ] || { echo "generate_appcast produced nothing for $ARCH" >&2; exit 1; }
  cp "$GENERATED" "$DIST/appcast-$ARCH.xml"

  APPCAST="$DIST/appcast-$ARCH.xml"
  ENCLOSURE="//*[local-name()='enclosure']"
  EXPECTED_URL="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")"
  [ "$(xmllint --xpath "count($ENCLOSURE)" "$APPCAST")" = "1" ]
  [ "$(xmllint --xpath "string($ENCLOSURE/@url)" "$APPCAST")" = "$EXPECTED_URL" ]
  [ "$(xmllint --xpath "string($ENCLOSURE/@length)" "$APPCAST")" = "$(stat -f%z "$ZIP")" ]
  ED_SIGNATURE=$(xmllint --xpath "string($ENCLOSURE/@*[local-name()='edSignature'])" "$APPCAST")
  [ -n "$ED_SIGNATURE" ]
  "$SPARKLE_BIN/sign_update" --verify "$ZIP" "$ED_SIGNATURE"
done

if [ "$(git rev-parse HEAD)" != "$HEAD_SHA" ] || [ -n "$(git status --porcelain)" ]; then
  echo "Source changed during packaging. The candidate cannot be published." >&2
  exit 1
fi

echo "Tagging ${TAG}…"
git tag -a "$TAG" "$HEAD_SHA" -m "Tacet $VERSION"
git push origin "refs/tags/$TAG"

echo "Uploading draft ${TAG}…"
ASSETS=("$DIST/Tacet-$VERSION-arm64.zip" "$DIST/Tacet-$VERSION-arm64.dmg" \
        "$DIST/Tacet-$VERSION-x86_64.zip" "$DIST/Tacet-$VERSION-x86_64.dmg" \
        "$DIST/appcast-arm64.xml" "$DIST/appcast-x86_64.xml")
gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "Tacet $VERSION" --verify-tag --draft \
  --notes "Tacet $VERSION. Apple Silicon and Intel builds with separate update feeds."

for ASSET in "${ASSETS[@]}"; do
  NAME=$(basename "$ASSET")
  DIGEST=$(shasum -a 256 "$ASSET" | cut -d' ' -f1)
  UPLOADED=$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"$NAME\") | .digest")
  if [ "$UPLOADED" != "sha256:$DIGEST" ]; then
    echo "The draft asset $NAME differs from the local file. Draft left unpublished." >&2
    exit 1
  fi
done

gh release edit "$TAG" --repo "$REPO" --draft=false --latest
[ "$(gh release view --repo "$REPO" --json tagName --jq .tagName)" = "$TAG" ]
for ARCH in "${ARCHS_LIST[@]}"; do
  LOCAL_FEED="$DIST/appcast-$ARCH.xml"
  LIVE_FEED="$DIST/live-appcast-$ARCH.xml"
  curl --fail --silent --show-error --location --retry 4 --retry-all-errors --max-time 20 \
    "https://github.com/$REPO/releases/latest/download/appcast-$ARCH.xml" --output "$LIVE_FEED"
  cmp "$LOCAL_FEED" "$LIVE_FEED"
done

echo
echo "Release:     https://github.com/$REPO/releases/tag/$TAG"
echo "arm64 feed:  https://github.com/$REPO/releases/latest/download/appcast-arm64.xml"
echo "x86_64 feed: https://github.com/$REPO/releases/latest/download/appcast-x86_64.xml"
