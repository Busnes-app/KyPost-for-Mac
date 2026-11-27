#!/bin/bash
set -euo pipefail

if ! command -v go >/dev/null; then
    brew install go
fi
export GOTOOLCHAIN=go1.27.4

exec "$CI_PRIMARY_REPOSITORY_PATH/.github/scripts/build-gopenpgp.sh"
