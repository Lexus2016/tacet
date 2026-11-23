#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bootstrap.sh
xcodegen generate --spec project.yml

xcodebuild \
  -project Tacet.xcodeproj \
  -scheme Tacet \
  -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath .build \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=YES \
  build

echo
echo "Built: $(pwd)/.build/Build/Products/${CONFIGURATION:-Debug}/Tacet.app"
