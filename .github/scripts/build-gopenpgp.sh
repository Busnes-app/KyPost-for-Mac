#!/bin/bash
# Build upstream's six mobile packages plus KyPost's boundary in ONE Go runtime.
# No release/tag is created. The source pin and Go checksum database verify inputs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SOURCE="$ROOT/Dependencies/KyPostCrypto"
OUTPUT="$ROOT/Dependencies/GopenPGP/gopenpgp.xcframework"
WORK="$ROOT/Dependencies/.build/gopenpgp"
source "$ROOT/Dependencies/gopenpgp.env"
cd "$SOURCE"
PIN=$(go list -m -f '{{.Version}}' github.com/ProtonMail/gopenpgp/v3)
[ "$PIN" = "$GOPENPGP_VERSION" ] || { echo 'Go module and gopenpgp.env pins differ' >&2; exit 1; }
KEY=$({ cat "$ROOT/.github/scripts/build-gopenpgp.sh" "$ROOT/Dependencies/gopenpgp.env" go.mod go.sum pqc.go; go version; xcodebuild -version; } | shasum -a 256 | cut -d' ' -f1)
if [ -f "$OUTPUT/.source-key" ] && [ "$(cat "$OUTPUT/.source-key")" = "$KEY" ]; then exit 0; fi
UPSTREAM=$(go mod download -json "github.com/ProtonMail/gopenpgp/v3@$PIN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')
rm -rf "$WORK"
mkdir -p "$WORK"
cp -R "$UPSTREAM/." "$WORK/"
chmod -R u+w "$WORK"
mkdir "$WORK/pqc"
cp pqc.go "$WORK/pqc/"
cd "$WORK"
go mod edit -go=1.26.6 -require=github.com/Busnes-app/ky-primitives@v0.11.0
go mod tidy
# Retain upstream's package list, tags and gomobile invocation. Fail on drift.
GOMOBILE_VERSION="$GOMOBILE_VERSION" python3 - <<'PY'
from pathlib import Path
import os
p = Path('build.sh')
s = p.read_text()
old = '-ldflags="-s -w "'
assert s.count(old) == 1, 'upstream linker flags changed'
s = s.replace(old, '-ldflags="-s -w -X=runtime.godebugDefault=asyncpreemptoff=1"')
anchor = 'import github.com/ProtonMail/gopenpgp/v3/profile'
assert s.count(anchor) == 1, 'upstream package list changed'
s = s.replace(anchor, anchor + '\nimport github.com/ProtonMail/gopenpgp/v3/pqc')
assert s.count('@latest') == 2, 'upstream gomobile installs changed'
s = s.replace('@latest', '@' + os.environ['GOMOBILE_VERSION'])
p.write_text(s)
PY
bash build.sh apple
SLICES=0
while IFS= read -r BIN; do
 ARCHS=$(lipo -archs "$BIN" | wc -w | tr -d ' ')
 HITS=$(strings -a "$BIN" | grep -c '^asyncpreemptoff=1$' || true)
 [ "$HITS" = "$ARCHS" ] || { echo "Missing runtime default: $BIN" >&2; exit 1; }
 SLICES=$((SLICES + 1))
done < <(find dist/apple/gopenpgp.xcframework -type f -name Gopenpgp)
[ "$SLICES" = 3 ]
rm -rf "$OUTPUT"
cp -R dist/apple/gopenpgp.xcframework "$OUTPUT"
printf '%s\n' "$KEY" > "$OUTPUT/.source-key"
