#!/bin/bash
#
# Regenerates the certificate fixtures in `KyPost Tests/TransportKeyFloorTests.swift`.
# Prints one `name base64-DER` line per certificate. Every chain is for host
# relay.test, valid 2026-01-01 to 2026-12-31 (the tests pin the verify date).
#
#   rootRSA2048 -> leafRSA2048        accepted
#   rootRSA2048 -> leafRSA2047        refused: leaf below the floor
#   rootRSA2048 -> intRSA2047 -> leafUnderWeakIntermediate   refused: intermediate
#   rootRSA2047 -> leafUnderWeakRoot  refused: anchor below the floor
#   rootP256    -> leafP256           accepted
#   rootP256    -> leafP384           accepted
#   leafEd25519 (self-signed)         refused: key type outside the floor
#
# Needs OpenSSL 3.4 or later, for -not_before and -not_after.

set -euo pipefail

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cd "$dir"

from=20260101000000Z
until=20261231000000Z

key() { # name algorithm-options...
  local name=$1; shift
  openssl genpkey -quiet "$@" -out "$name.key"
}

ca() { # name [issuer]
  local name=$1 issuer=${2:-}
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > "$name.ext"
  openssl req -new -key "$name.key" -subj "/CN=$name" -out "$name.csr"
  if [ -z "$issuer" ]; then
    openssl x509 -req -in "$name.csr" -key "$name.key" -sha256 \
      -not_before "$from" -not_after "$until" -extfile "$name.ext" -out "$name.pem" 2>/dev/null
  else
    openssl x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" -sha256 \
      -not_before "$from" -not_after "$until" -extfile "$name.ext" -out "$name.pem" 2>/dev/null
  fi
}

leaf() { # name issuer
  local name=$1 issuer=$2
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:relay.test\n' > "$name.ext"
  openssl req -new -key "$name.key" -subj "/CN=relay.test" -out "$name.csr"
  openssl x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" -sha256 \
    -not_before "$from" -not_after "$until" -extfile "$name.ext" -out "$name.pem" 2>/dev/null
}

rsa() { key "$1" -algorithm RSA -pkeyopt "rsa_keygen_bits:$2"; }
ec() { key "$1" -algorithm EC -pkeyopt "ec_paramgen_curve:$2"; }

rsa rootRSA2048 2048; ca rootRSA2048
rsa rootRSA2047 2047; ca rootRSA2047
rsa intRSA2047 2047; ca intRSA2047 rootRSA2048
ec rootP256 P-256; ca rootP256

rsa leafRSA2048 2048; leaf leafRSA2048 rootRSA2048
rsa leafRSA2047 2047; leaf leafRSA2047 rootRSA2048
rsa leafUnderWeakIntermediate 2048; leaf leafUnderWeakIntermediate intRSA2047
rsa leafUnderWeakRoot 2048; leaf leafUnderWeakRoot rootRSA2047
ec leafP256 P-256; leaf leafP256 rootP256
ec leafP384 P-384; leaf leafP384 rootP256

key leafEd25519 -algorithm ED25519
openssl req -new -x509 -key leafEd25519.key -subj "/CN=relay.test" \
  -addext "subjectAltName=DNS:relay.test" -not_before "$from" -not_after "$until" -out leafEd25519.pem

for name in rootRSA2048 rootRSA2047 intRSA2047 rootP256 leafRSA2048 leafRSA2047 \
  leafUnderWeakIntermediate leafUnderWeakRoot leafP256 leafP384 leafEd25519; do
  printf '%s %s\n' "$name" "$(openssl x509 -in "$name.pem" -outform DER | openssl base64 -A)"
done
