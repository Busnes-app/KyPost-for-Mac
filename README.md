# KyPost for macOS and iOS

[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15930/badge)](https://www.bestpractices.dev/projects/15930)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Busnes-app/KyPost-for-Mac/badge)](https://scorecard.dev/viewer/?uri=github.com/Busnes-app/KyPost-for-Mac)

A native SwiftUI mail client for macOS and iOS. It connects to a KyPost mail relay.

The app talks only to the relay backend. There is no direct IMAP or SMTP. You pair a device one time with a QR code or a deep link. The relay then handles mail access, server-side keyword tabs, push notifications, and contact sync.

## What it can do

- Read mail with folders, keyword tabs and an HTML reader.
- Compose, manage contacts and pair per-device credentials through KyPost.
- Use native macOS windows and shortcuts or the iOS interface.
- Review security controls, platform differences and known gaps in the [feature guide](docs/FEATURES.md).

## Requirements

- macOS 26.0+ or iOS/iPadOS 26.0+.
- Your own reachable [KyPost server](https://github.com/Busnes-app/KyPost-Server) over HTTPS, with an everyday mailbox account.
- For push: APNs configured on that server.
- **Source builds only:** Xcode 26 or newer with the matching platform SDKs.

The app uses SwiftData for persistence, URLSession for networking, and WebKit for rendering.

The crypto dependency is built from source: GopenPGP 3.5.2 plus the KyPost Go bridge, using ky-primitives 0.11.0 for X-Wing. Install **Go 1.27.x**, then run `.github/scripts/build-gopenpgp.sh` before opening `KyPost.xcodeproj`. The shared xcodebuild wrapper runs this step automatically. One XCFramework contains upstream's six packages and the bridge in one Go runtime; Go module checksums verify downloaded sources. The build preserves `asyncpreemptoff=1` to avoid the embedded runtime's preemption-signal crash. No binary is committed or fetched from the old dependency release. Only `GopenPGPCrypto.swift` imports the library.

## Install and pair

As of 2026-10-20, GitHub Releases contains a GopenPGP dependency artifact, **not a KyPost
application DMG**. The application release workflow exists, but its signed/notarized Mac
DMG and App Store distribution have not been qualified here. Do not mistake the dependency
release for an installable client or assume App Store availability.

For a source installation on a Mac:

1. Clone this repository, open `KyPost.xcodeproj` in Xcode, and select the **KyPost** scheme.
2. Choose My Mac, or an iPhone/iPad simulator. For a physical iOS device, configure your own Apple signing team/provisioning and the required capabilities; push and shared-group sign-on also need matching server/client configuration.
3. Build and run. A simulator can exercise UI but does not qualify Secure Enclave custody, biometric behavior or real APNs delivery.
4. In your server’s web frontend, open **Settings → Security → Devices → Pair a new device**. On a Mac choose **Pair this device**, or paste the displayed `kypost://native-pair?...` link in **Settings → Connection → Paste Pairing Link…**. On iOS scan the QR. Confirm the server; registration stores per-device credentials and the certificate pin in Keychain.
5. Check inbox access and a controlled send/reply through the configured mail service. Configure APNs separately and observe actual delivery before calling push verified.

When application releases are published, install the verified Mac DMG by dragging KyPost to
Applications, or use the actual iOS distribution listing. Updates must retain the same
signing identity and Keychain access groups to preserve access to existing pairing keys.

Until you pair, the inbox says how: on a Mac it gives the web steps above, and on iOS it points to Settings → Connection.

## Documentation

- [User manual](https://busnes.app/manuals/kypost-for-mac/) ([Markdown sources](docs/src/introduction.md)) — build and check locally with `mdbook build docs` and `python3 docs/check-links.py`, then open `docs/book/index.html`. The documentation workflow also uploads a `documentation-book` artifact.
- [Development](docs/DEVELOPMENT.md) — Identifiers, Architecture, Testing. <a id="architecture"></a><a id="wire-contracts"></a><a id="testing"></a>
- [Features](docs/FEATURES.md) — Features, Known gaps. <a id="features"></a><a id="security-settings--security"></a><a id="known-gaps"></a>
- [Calendar RSVP](docs/KYCALENDAR-RSVP.md) — Wire contract for answering invitations through KyCalendar and the mail fallback.
- [Verifying releases](docs/VERIFYING-RELEASES.md) — Check the GopenPGP binary against its pin and its build, and what can be checked of the app.
- [Assurance case](docs/ASSURANCE-CASE.md) — Threat model, trust boundaries, and why the security requirements are met.
- [Strong cryptography](docs/STRONG-CRYPTO.md) — Key-size floors for TLS and OpenPGP, the key inventory, and what is out of scope.
- [Contributing](CONTRIBUTING.md) — Contribution guidelines, review process, and tests.
- [Security policy](SECURITY.md) — Threat model and how to report a vulnerability privately.
- [Release notes](CHANGELOG.md) — Changes by version and upgrade notes.

## License

MIT, developed by Busnes.app — see [LICENSE.txt](LICENSE.txt).

[![OctoCounts](https://api.octocounts.com/badge/Busnes-app/KyPost-for-Mac/branch/main)](https://octocounts.com/github/Busnes-app/KyPost-for-Mac/tree/main)
