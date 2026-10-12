#!/usr/bin/env bash
#
# App Store screenshots, captured from the DEBUG demo build.
#
# The app under test runs with `-KyPostDemo` (KyPost/App/DemoContent.swift),
# which swaps in an in-memory database and a stand-in relay serving a
# fabricated mailbox. Nothing here touches a real account: no pairing, no
# network, and on macOS the developer's own mail is never opened.
#
# The images come out of the test result bundle rather than `screencapture`
# or `simctl io screenshot`, because those need TCC grants a CI machine will
# not have, and because the run has to navigate the app anyway.
#
# Usage: capture-screenshots.sh [ios|macos|all] [output-dir]
#   output-dir defaults to ./Distribution/Screenshots
#
# macOS additionally needs UI automation enabled, once per machine:
#   sudo DevToolsSecurity -enable

set -euo pipefail

cd "$(dirname "$0")/.."

platform="${1:-all}"
outdir="${2:-Distribution/Screenshots}"
derived="${TMPDIR:-/tmp}/kypost-screenshots"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# xcodebuild forwards TEST_RUNNER_-prefixed variables into the test runner's
# environment with the prefix stripped. Passing `KYPOST_SCREENSHOTS=1` as an
# argument instead sets a *build setting*, which ScreenshotTests cannot read —
# it skipped itself and the run still reported success.
export TEST_RUNNER_KYPOST_SCREENSHOTS=1

# Prefer a 6.9" iPhone: App Store Connect accepts those screenshots for every
# iPhone size. Simulator list order is not device-size order.
ios_device() {
    xcrun simctl list devices available --json \
        | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
names = ("iPhone 17 Pro Max", "iPhone Air", "iPhone 16 Pro Max",
         "iPhone 16 Plus", "iPhone 15 Pro Max", "iPhone 15 Plus",
         "iPhone 14 Pro Max")
iphones = [entry for runtime, entries in reversed(devices.items())
           if "iOS" in runtime for entry in entries]
print(next((entry["udid"] for name in names for entry in iphones
            if entry["name"] == name), ""))
'
}

# Screenshot names are the attachment names set in ScreenshotTests; the
# result bundle appends an index and a UUID that nothing downstream wants.
export_attachments() {
    local bundle="$1" dest="$2" staging
    staging="$(mktemp -d)"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$staging" >/dev/null
    mkdir -p "$dest"
    /usr/bin/python3 - "$staging" "$dest" <<'PY'
import json, os, re, shutil, sys

staging, dest = sys.argv[1], sys.argv[2]

def walk(node):
    if isinstance(node, dict):
        if "exportedFileName" in node and "suggestedHumanReadableName" in node:
            yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)

count = 0
for attachment in walk(json.load(open(os.path.join(staging, "manifest.json")))):
    name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", ".png",
                  attachment["suggestedHumanReadableName"])
    if not name.endswith(".png"):
        continue
    shutil.copy(os.path.join(staging, attachment["exportedFileName"]),
                os.path.join(dest, name))
    print(name)
    count += 1
if count == 0:
    sys.exit("no screenshots in the result bundle")
PY
    rm -rf "$staging"
}

run() {
    local label="$1" destination="$2" dest="$3"
    # Separate statement: bash expands every word of a `local` before it
    # assigns any of them, so $label is not readable on the line that sets it.
    local bundle="$derived/$label.xcresult"
    rm -rf "$bundle"
    echo "==> capturing $label"
    xcodebuild test \
        -scheme KyPost \
        -project KyPost.xcodeproj \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived/dd-$label" \
        -only-testing:"KyPost UITests/ScreenshotTests" \
        -resultBundlePath "$bundle" \
        >"$derived/$label.log" 2>&1 \
        || { tail -40 "$derived/$label.log"; exit 1; }
    export_attachments "$bundle" "$dest"
}

mkdir -p "$derived"

if [[ "$platform" == "ios" || "$platform" == "all" ]]; then
    device="$(ios_device)"
    [[ -n "$device" ]] || { echo "no 6.9-inch iPhone simulator available" >&2; exit 1; }
    xcrun simctl boot "$device" 2>/dev/null || true
    # Apple's own listings are shot at 9:41 with a full battery.
    xcrun simctl status_bar "$device" override \
        --time "9:41" --batteryState discharging --batteryLevel 100 \
        --cellularBars 4 --wifiBars 3 2>/dev/null || true
    run ios "platform=iOS Simulator,id=$device" "$outdir/iOS"
fi

if [[ "$platform" == "macos" || "$platform" == "all" ]]; then
    if [[ "$(DevToolsSecurity -status)" != *enabled* ]]; then
        echo "macOS UI testing needs: sudo DevToolsSecurity -enable" >&2
        exit 1
    fi
    run macos "platform=macOS" "$outdir/macOS"
fi

echo "==> written to $outdir"
