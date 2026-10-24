# Verifying releases

[Product overview](../README.md) · [Security](../SECURITY.md) · [Assurance case](ASSURANCE-CASE.md)

KyPost for iOS and macOS has three things a user or reviewer might want to check:

| What | Where it comes from | State on 2026-10-23 |
|---|---|---|
| The **GopenPGP XCFramework**, the one binary dependency and the app's OpenPGP code | GitHub release `gopenpgp-v3.5.2`, pinned by SHA-256 in `Dependencies/GopenPGP/Package.swift` | Published. **Every command below was run against it.** |
| The **iOS app** | App Store | **Untested.** Not found in Apple's public App Store lookup on 2026-10-23. |
| The **Mac app** (`KyPost-<version>.dmg`, Developer ID) | GitHub release for a `v*` tag, made by `release.yml` | **Untested.** None has been published. The `v0.5.0` release run failed at "Export Mac app (Developer ID)". |

## The GopenPGP binary

`.github/workflows/gopenpgp-xcframework.yml` builds the framework on a GitHub runner, from
the ProtonMail/gopenpgp tag in `Dependencies/gopenpgp.env`, with upstream's own `build.sh`
and one added linker flag. SwiftPM refuses the download if its SHA-256 differs from the
`checksum` in `Package.swift` when it fetches the binary; these commands repeat the check
by hand, from a clone of this repository.

**1. The asset is the pinned one.**

```bash
url=$(sed -n 's/.*url: "\(.*\)",/\1/p' Dependencies/GopenPGP/Package.swift)
pin=$(sed -n 's/.*checksum: "\([0-9a-f]*\)".*/\1/p' Dependencies/GopenPGP/Package.swift)
curl -sSfL -o gopenpgp.xcframework.zip "$url"
echo "$pin  gopenpgp.xcframework.zip" | sha256sum -c -        # macOS: shasum -a 256 -c -
```

For v3.5.2 this prints `gopenpgp.xcframework.zip: OK`, and the pin is
`ed2ad1463b4dc54149c45dc13a9800c15f9eb1ea0c83609b543476c03663c852`. GitHub's own record
of the upload must agree (it prints the same hash with a `sha256:` prefix):

```bash
gh release view gopenpgp-v3.5.2 -R Busnes-app/KyPost-for-Mac --json assets --jq '.assets[].digest'
```

Check the pin against the asset or this `digest`, never against the release notes alone:
the first release's notes once quoted a hash the asset did not have.

**2. Which source it was built from.** The release notes name the workflow run
(`38497139997` for v3.5.2). Its log records the upstream commit it checked out, the Go
version and the hash it published:

```bash
gh run view 38497139997 -R Busnes-app/KyPost-for-Mac --log \
  | grep -E 'HEAD is now at|go version go|SHA256: '
git ls-remote https://github.com/ProtonMail/gopenpgp.git refs/tags/v3.5.2
```

For v3.5.2 the log shows `HEAD is now at dcc4859 chore: Bump version to v3.5.2 (#374)`,
`go version go1.27.2 darwin/arm64` and `SHA256: ed2ad146…c852`. `ls-remote` gives
`dcc4859aba4cd912c7562a534912fc8fc688e04b` for the upstream tag, so the two match. The run
built commit `3f429f9` of this repository, from branch `chore/gopenpgp-v3.5.2`; that commit
is on `main`.

**What this does not give you:**

- **The log will expire.** This repository keeps Actions logs for 90 days, so the v3.5.2
  log goes around 2027-01-12. After that only the release notes link the binary to its
  build. There is no build-provenance attestation that would outlive the log
  (`gh attestation verify gopenpgp.xcframework.zip --repo Busnes-app/KyPost-for-Mac`
  answers 404).
- **The log needs a GitHub sign-in.** Anonymous log downloads are refused (HTTP 403).
  The commands were run only as the repository's admin.
- **You cannot rebuild it to the same bytes.** Two builds of the same tag produced
  different hashes: gomobile embeds build IDs and paths, and the job does not pin Xcode
  or Go (`go-version: stable`). The checksum identifies one build; it does not prove that
  build matches the source.

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

Expect `TeamIdentifier=TATYN4X57D` and a `Developer ID Application` authority. The `.sha256`
file sits beside the disk image on the same release page, so it catches a damaged download,
not a swapped one. The Developer ID signature and notarisation are what tie the app to
the team.
