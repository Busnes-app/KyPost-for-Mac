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
# Usage: capture-screenshots.sh [ios|ipad|macos|all|duo-outer|duo-inner] [output-dir]
#   output-dir defaults to ./Distribution/Screenshots
#   ios writes <output-dir>/iOS (6.9" iPhone), ipad <output-dir>/iPad
#   (13" iPad), macos <output-dir>/macOS; all does those three.
#   duo-outer / duo-inner write <output-dir>/iPhone Duo outer|inner; fold or
#   unfold the iPhone Duo simulator by hand first (see duo_device).
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

# App Store Connect requires 13" iPad screenshots for an app that runs on
# iPad, and scales them down for the smaller iPads.
ipad_device() {
    xcrun simctl list devices available --json \
        | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
names = ("iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M4)",
         "iPad Air 13-inch (M4)", "iPad Air 13-inch (M3)",
         "iPad Air 13-inch (M2)", "iPad Pro (12.9-inch) (6th generation)")
ipads = [entry for runtime, entries in reversed(devices.items())
         if "iOS" in runtime for entry in entries]
print(next((entry["udid"] for name in names for entry in ipads
            if entry["name"] == name), ""))
'
}

# iPhone Duo (iOS 27.1 runtime, Xcode 27.1 or later). The listing wants the
# outer display (1398 x 2034) and the inner one (2007 x 2853). The fold pose
# cannot be scripted: fold or unfold the device in Xcode's device window
# first, then run `duo-outer` or `duo-inner` to match. A booted Duo is
# preferred: that is the one whose pose was just set.
duo_device() {
    xcrun simctl list devices available --json \
        | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
duos = [entry for runtime, entries in reversed(devices.items())
        if "iOS" in runtime for entry in entries
        if entry["name"] == "iPhone Duo"]
duos.sort(key=lambda entry: entry["state"] != "Booted")
print(duos[0]["udid"] if duos else "")
'
}

# Apple's own listings are shot at 9:41 with a full battery.
prepare_simulator() {
    local device="$1"
    xcrun simctl boot "$device" 2>/dev/null || true
    xcrun simctl bootstatus "$device" >/dev/null 2>&1 || true
    xcrun simctl status_bar "$device" override \
        --time "9:41" --batteryState discharging --batteryLevel 100 \
        --cellularBars 4 --wifiBars 3 2>/dev/null || true
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
    # build: the derived-data name. iPhone and iPad share one (both are the
    # iphonesimulator SDK), so the second capture does not rebuild the app.
    local label="$1" destination="$2" dest="$3" build="${4:-$1}"
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
        -derivedDataPath "$derived/dd-$build" \
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
    prepare_simulator "$device"
    run ios "platform=iOS Simulator,id=$device" "$outdir/iOS"
fi

if [[ "$platform" == "ipad" || "$platform" == "all" ]]; then
    device="$(ipad_device)"
    [[ -n "$device" ]] || { echo "no 13-inch iPad simulator available" >&2; exit 1; }
    prepare_simulator "$device"
    run ipad "platform=iOS Simulator,id=$device" "$outdir/iPad" ios
fi

if [[ "$platform" == "duo-outer" || "$platform" == "duo-inner" ]]; then
    device="$(duo_device)"
    [[ -n "$device" ]] || { echo "no iPhone Duo simulator (needs the iOS 27.1 runtime)" >&2; exit 1; }
    prepare_simulator "$device"
    if [[ "$platform" == "duo-outer" ]]; then
        run duo-outer "platform=iOS Simulator,id=$device" "$outdir/iPhone Duo outer" ios
    else
        run duo-inner "platform=iOS Simulator,id=$device" "$outdir/iPhone Duo inner" ios
    fi
fi

if [[ "$platform" == "macos" || "$platform" == "all" ]]; then
    if [[ "$(DevToolsSecurity -status)" != *enabled* ]]; then
        echo "macOS UI testing needs: sudo DevToolsSecurity -enable" >&2
        exit 1
    fi
    run macos "platform=macOS" "$outdir/macOS"
fi

echo "==> written to $outdir"
