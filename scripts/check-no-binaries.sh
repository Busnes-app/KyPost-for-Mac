#!/usr/bin/env bash
# Fail if a tracked file is a compiled executable (OpenSSF Scorecard Binary-Artifacts).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

types='application/(x-(executable|pie-executable|sharedlib|object|archive|mach-binary|dosexec)|vnd\.microsoft\.portable-executable|java-archive|x-java-applet|wasm)$'
# libmagic reports most JVM and Android archives as plain application/zip, so match them by name.
archives=('*.jar' '*.war' '*.ear' '*.aar' '*.apk' '*.aab' '*.dex')
# The gomobile GopenPGP build ships as a zip of Mach-O frameworks; it belongs in a release asset.
archives+=('*.xcframework.zip')
# Add a pathspec exclusion such as ':!gradle/wrapper/gradle-wrapper.jar' only for a
# binary the repo must carry, with the reason beside it.
excludes=(
)
found=$(git ls-files -z -- . ${excludes[@]+"${excludes[@]}"} | xargs -0 -r file --mime-type | grep -E "$types" || true)
named=$(git ls-files -- "${archives[@]}" ${excludes[@]+"${excludes[@]}"})
if [ -n "$found$named" ]; then
  echo "Compiled binaries are tracked; build them from source instead:" >&2
  if [ -n "$found" ]; then echo "$found" >&2; fi
  if [ -n "$named" ]; then echo "$named" >&2; fi
  exit 1
fi
