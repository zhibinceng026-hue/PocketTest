#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -version
plutil -lint PocketTest/Info.plist PocketTest.xcodeproj/project.pbxproj
mkdir -p build dist
xcodebuild build \
  -project PocketTest.xcodeproj \
  -scheme PocketTest \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  2>&1 | tee build/device-build.log

# Create an unsigned IPA for SideStore / AltStore to sign on the user's device.
# Use a fresh staging directory; reruns do not retain older application files.
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/pockettest.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/Payload"
ditto build/device/Build/Products/Release-iphoneos/PocketTest.app "$staging_dir/Payload/PocketTest.app"
ditto -c -k --norsrc --keepParent "$staging_dir/Payload" dist/PocketTest-unsigned.ipa
unzip -t dist/PocketTest-unsigned.ipa
shasum -a 256 dist/PocketTest-unsigned.ipa > dist/SHA256SUMS.txt
printf '%s\n' 'Unsigned IPA created. Signing and iPhone installation are still required.'
