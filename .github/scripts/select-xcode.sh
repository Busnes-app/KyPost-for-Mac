#!/bin/bash
#
# Selects the newest Xcode 26 on the runner and checks its SDKs satisfy the
# project's deployment targets. Shared by every ci.yml job, which each start
# on a fresh runner.
#
# This project needs Xcode 26 — README pins the deployment target at
# macOS/iOS 26.0. The first cut selected `/Applications/Xcode_16.app`, which
# exists on the image and builds nothing here: xcodebuild exited 70 rather than
# saying the SDK was too old.
#
# Chosen by globbing rather than a literal path, because the images carry
# several 26.x and rename them as they update; pinning an exact one means CI
# breaks on an image refresh rather than on a code change.

set -euo pipefail

XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
if [ -z "$XCODE" ]; then
  echo "::error::No Xcode 26.x on this runner image; this project cannot build without one."
  ls -d /Applications/Xcode* || true
  exit 1
fi
sudo xcode-select -s "$XCODE"
xcodebuild -version

# Check the SDKs actually satisfy the deployment targets, and say so plainly if
# they do not. Without this the failure is `xcodebuild` exiting 70 with no
# indication that the toolchain is the problem — which is exactly how the first
# run read.
for pair in "macosx:MACOSX_DEPLOYMENT_TARGET" "iphoneos:IPHONEOS_DEPLOYMENT_TARGET"; do
  sdk_name=${pair%%:*}
  setting=${pair##*:}
  SDK=$(xcrun --sdk "$sdk_name" --show-sdk-version)
  TARGET=$(grep -m1 -oE "$setting = [0-9.]+" \
    KyPost.xcodeproj/project.pbxproj | grep -oE '[0-9.]+$')
  echo "$sdk_name SDK $SDK, deployment target $TARGET"
  if [ "$(printf '%s\n%s\n' "$TARGET" "$SDK" | sort -V | tail -1)" != "$SDK" ]; then
    echo "::error::$sdk_name SDK $SDK is older than this project's deployment target $TARGET. Use a runner image carrying a newer Xcode."
    exit 1
  fi
done
