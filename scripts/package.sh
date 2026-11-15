#!/usr/bin/env bash
# Builds LocalImage.app (Release, Apple Silicon) and packs it into dist/LocalImage-v<version>-macos-arm64.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' LocalImage.xcodeproj/project.pbxproj | head -1)
derived=build/ReleaseDerived
rm -rf "$derived" dist
mkdir -p dist

xcodebuild -project LocalImage.xcodeproj -scheme LocalImage -configuration Release \
  -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

app="$derived/Build/Products/Release/LocalImage.app"
# Xcode already signs ad hoc (no Developer ID); just make sure the bundle is intact.
codesign --verify --deep --strict "$app"

archive="dist/LocalImage-v${version}-macos-arm64.zip"
ditto -c -k --keepParent "$app" "$archive"
echo "$archive"
