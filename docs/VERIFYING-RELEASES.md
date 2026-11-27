# Verifying releases

[Product overview](../README.md) · [Security](../SECURITY.md) · [Assurance case](ASSURANCE-CASE.md)

KyPost for iOS and macOS has three things a user or reviewer might want to check:

| What | Where it comes from | State on 2026-10-23 |
|---|---|---|
| The **GopenPGP XCFramework** and KyPost bridge | Local source build using pinned Go modules | Native compilation runs in macOS CI; Linux tests the Go bridge. |
| The **iOS app** | App Store | **Untested.** Not found in Apple's public App Store lookup on 2026-10-23. |
| The **Mac app** (`KyPost-<version>.dmg`, Developer ID) | GitHub release for a `v*` tag, made by `release.yml` | **Untested.** None has been published. The `v0.5.0` release run failed at "Export Mac app (Developer ID)". |

## The GopenPGP binary

The app now builds its local framework from the Go module sources pinned in
`Dependencies/KyPostCrypto/go.mod` and `go.sum`; `gopenpgp.env` must agree.
The old `gopenpgp-v3.5.2` release is historical and omits the X-Wing bridge.
It is no longer consumed by SwiftPM.

On a Mac with Go 1.27.x and Xcode 26:

```sh
.github/scripts/build-gopenpgp.sh
cd Dependencies/KyPostCrypto
go mod verify
go test -race ./...
```

The build calls upstream `build.sh apple`, adds KyPost's bridge to the same
runtime, pins gomobile, and checks the baked `asyncpreemptoff=1` in every slice.
`Package.swift` consumes the generated local path. Native CI repeats this build;
`gopenpgp-xcframework.yml` retains a workflow artifact for inspection and does
not publish dependency releases. Module checksums authenticate source downloads;
they do not prove the compiler or local build host is trustworthy. The output
is not bit-reproducible and no dependency binary attestation is claimed.

**Not checked on Linux:** Apple framework compilation and runtime behavior.
The platform CI checks cover compilation and Simulator tests; physical-device
Keychain, enclave migration and presence-policy testing remain separate.

## The iOS app (untested)

Apple signs every App Store build, and iOS checks that signature at install and at every
launch. That check is the verification, and the project has no key of its own to offer.
Install KyPost only from its App Store listing. The bundle ID is `org.kysecurity.mail` and
the developer team is `TATYN4X57D`.

Apple encrypts and re-signs App Store binaries, so no store build compares byte for byte
with a build from source.

## The Mac app (untested: no disk image has been published)

`release.yml` exports the Mac app with a Developer ID certificate of team `TATYN4X57D`,
notarises and staples the disk image, and attaches `KyPost-<version>.dmg` with its
`.sha256` to the tag's GitHub release. When one exists, these are the checks to run on a
Mac. They have never been run against a real release:

```bash
v=<version>
gh release download v$v -R Busnes-app/KyPost-for-Mac -p "KyPost-$v.dmg" -p "KyPost-$v.dmg.sha256"
shasum -a 256 -c "KyPost-$v.dmg.sha256"
xcrun stapler validate "KyPost-$v.dmg"
spctl -a -t open --context context:primary-signature -vv "KyPost-$v.dmg"
hdiutil attach -nobrowse -readonly "KyPost-$v.dmg"     # then, on the mounted KyPost.app:
codesign --verify --deep --strict -vv /Volumes/KyPost*/KyPost.app
codesign -dvv /Volumes/KyPost*/KyPost.app 2>&1 | grep -E '^(Authority|TeamIdentifier)='
```

Expect `TeamIdentifier=TATYN4X57D` and a `Developer ID Application` authority.
The release also carries `KyPost-v$v.intoto.jsonl`, build provenance for the disk image
and its `.sha256`:

```bash
gh release download v$v -R Busnes-app/KyPost-for-Mac -p "KyPost-v$v.intoto.jsonl"
gh attestation verify "KyPost-$v.dmg" --repo Busnes-app/KyPost-for-Mac \
  --bundle "KyPost-v$v.intoto.jsonl"
```
 The `.sha256`
file sits beside the disk image on the same release page, so it catches a damaged download,
not a swapped one. The Developer ID signature and notarisation are what tie the app to
the team.
