# Crypto dependencies

## Purpose

Own the Go bridge and the XCFramework consumed by the Swift app.

## Ownership

- `KyPostCrypto/` owns the gomobile-compatible `pqc` boundary and shared public fixtures.
- `GopenPGP/Package.swift` points to the generated local framework.
- `.github/scripts/build-gopenpgp.sh` builds it; `run-xcodebuild.sh` invokes the build.

## Local Contracts

- Pin GopenPGP identically in `gopenpgp.env` and `KyPostCrypto/go.mod`.
- Keep ky-primitives X-Wing at v0.11.0 or a deliberately reviewed successor.
- Bind upstream's six packages and `pqc` into ONE framework/runtime using upstream
  `build.sh apple`. Preserve mobile/ios tags and all Apple slices.
- Preserve `-X=runtime.godebugDefault=asyncpreemptoff=1` and the per-slice check.
- Pin gomobile in `gopenpgp.env`; source downloads use Go checksums. Builds are
  not bit-reproducible. No prebuilt-release fallback: it would omit the bridge.
- Generated upstream staging and framework stay ignored. Source builds require
  Go 1.27.x and Xcode 26; run the build script before opening the Xcode project.
- Byte slices may alias mutable Objective-C data. Wipe only owned Go copies;
  Swift owns and wipes its seed/plaintext buffers. Go key objects cannot be erased.
- JSON inspection results cross as nullable bytes, not nonnull strings with errors.
- Shared fixture bytes and source SHA-256 provenance live in `testdata/SOURCE.md`.
  Keep XCTest's embedded `PqcFixtures.swift` subset byte-identical.

## Work Guidance

Use the existing GopenPGP API for decrypt/verify; the bridge supplies only missing
X-Wing and packet-inspection operations. v4 sending remains unchanged in P3.

## Verification

- `cd Dependencies/KyPostCrypto && go test -race ./...`
- On macOS: `.github/scripts/build-gopenpgp.sh`, then the root product checks.
- `crypto-bridge.yml` runs race tests on Linux; native CI compiles both platforms
  and runs XCTest/Swift Testing on the iOS Simulator.

## Child DOX Index

None.
