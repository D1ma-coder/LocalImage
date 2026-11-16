#!/usr/bin/env bash
# Builds LocalImage.app (Release, Apple Silicon) and packs it into dist/LocalImage-v<version>-macos-arm64.dmg:
# a compressed disk image with the app and an Applications shortcut to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' LocalImage.xcodeproj/project.pbxproj | head -1)
# Bytecode caches inside the synchronized source folder would be copied into the app's Resources.
find LocalImage -name __pycache__ -type d -prune -exec rm -rf {} +

derived=build/ReleaseDerived
rm -rf "$derived" dist
mkdir -p dist

xcodebuild -project LocalImage.xcodeproj -scheme LocalImage -configuration Release \
  -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

app="$derived/Build/Products/Release/LocalImage.app"
# Xcode already signs ad hoc (no Developer ID); just make sure the bundle is intact.
codesign --verify --deep --strict "$app"

staging=$(mktemp -d)
ditto "$app" "$staging/LocalImage.app"
ln -s /Applications "$staging/Applications"
image="dist/LocalImage-v${version}-macos-arm64.dmg"
hdiutil create -volname "LocalImage ${version}" -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$image" >/dev/null
rm -rf "$staging"
hdiutil verify "$image" >/dev/null
echo "$image"
