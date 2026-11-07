#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo 'ERROR: macOS with Xcode and iOS SDK >= 26 is required. No IPA was created.' >&2
  exit 2
fi
task_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${task_sdk_version%%.*}" -lt 26 ]]; then
  echo 'ERROR: iOS SDK 26+ required for native Liquid Glass.' >&2
  exit 2
fi
mkdir -p Build
bash Scripts/test_core.sh 2>&1 | tee Build/core-tests.log
xcodebuild -project ASTRA.xcodeproj -scheme ASTRA -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$PWD/Build/ASTRA.xcarchive" \
  CODE_SIGNING_ALLOWED=NO archive 2>&1 | tee Build/device-build.log
task_app_path="$PWD/Build/ASTRA.xcarchive/Products/Applications/ASTRA.app"
test -d "$task_app_path"
file "$task_app_path/ASTRA" | grep -q 'Mach-O'
task_package_dir="$(mktemp -d)"
trap 'rm -rf "$task_package_dir"' EXIT
mkdir -p "$task_package_dir/Payload"
ditto "$task_app_path" "$task_package_dir/Payload/ASTRA.app"
ditto -c -k --keepParent "$task_package_dir/Payload" "$PWD/Build/ASTRA-unsigned.ipa"
shasum -a 256 Build/ASTRA-unsigned.ipa > Build/ASTRA-unsigned.ipa.sha256
echo 'Created Build/ASTRA-unsigned.ipa. It requires valid device-compatible re-signing before installation.'
