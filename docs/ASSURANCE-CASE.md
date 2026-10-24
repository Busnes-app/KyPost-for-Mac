# Assurance case

[Product overview](../README.md) · [Security](../SECURITY.md) · [Verifying releases](VERIFYING-RELEASES.md)

This is the argument that KyPost for iOS and macOS meets its security requirements: what it
protects, from whom, where the trust boundaries are, and why the design and the code hold at
each one. The detailed behaviour and its limits live in
[SECURITY.md](../SECURITY.md#what-the-app-protects-and-what-it-does-not); the contracts live in
[AGENTS.md](../AGENTS.md). Paths are relative to the `KyPost/` source folder unless they start
with a top-level folder.

## What KyPost must protect

KyPost is a mail client for a self-hosted KyPost relay. It holds a pairing credential, cached
mail and contacts and, after deliberate enrollment, the account's OpenPGP private key. Its
security requirements:

1. **Only the paired relay receives the device credential.** It goes nowhere else, even on
   a redirect, a changed certificate or a hostile network.
2. **The OpenPGP private key does not rest in the clear** and is usable only after a
   presence check on this device. (A key enrolled by a build from before the seal stays in
   the clear until its first presence-checked open seals it.)
3. **Client-encrypted mail stays encrypted** outside this device: the plaintext body never
   reaches the relay on the client-custody path, and a decrypted body is never written to
   disk.
4. **A signature verdict says what this device knows,** not what the relay claims.
5. **Opening a message leaks nothing** until the user asks for remote content.
6. **A locked or seized device gives up as little as possible:** the app lock, the PIN
   lockout and wipe, and Hostile Location Protection.
7. **The app never acts on mail by itself.** It does not archive, delete or move mail
   without an explicit user action ([CONTRIBUTING.md](../CONTRIBUTING.md#the-user-contract)).

## Threat model

| Attacker | Can | Wants |
|---|---|---|
| Network attacker, including one holding a publicly trusted certificate for the relay's name | Intercept and redirect TLS | Steal the device secret, read mail |
| Mail sender | Put any HTML, links and OpenPGP data in a message | Track opens, run script, forge a trusted signature |
| Compromised or curious relay | Return any response, claim any key is verified | Read client-encrypted mail, upgrade a signature verdict |
| APNs and the push relay | See push traffic | Read mail content |
| Someone holding the unlocked device, or seizing it | Open the app, guess PINs, image the disk | Read mail, the key, contacts |
| A swapped GopenPGP binary | Run inside the app's crypto path | Leak keys or plaintext |

Out of scope, as [SECURITY.md](../SECURITY.md#what-is-out-of-scope) lists: an attacker at
the keyboard of an unlocked device with the app open, other apps capturing the screen beyond
the app's own window protection, the mail server itself, and attachments after they leave the
app.

## Trust boundaries

1. **Device → relay.** HTTPS, a per-host SPKI SHA-256 pin on top of normal system trust,
   and redirects allowed only to the same host and port over HTTPS
   (`Data/Networking/PinnedSessionDelegate.swift`). Pairing runs on its own pinned connection
   (`Data/Networking/RelayPairingConnection.swift`).
2. **Relay → device data.** Signature verdicts are decided on this device. The relay supplies
   candidate keys, so a key it offers can reach *signer not confirmed* and, through first-seen
   history, *same key as last time*. Only a key pinned by QR on this device gives *you confirmed
   this key*. The relay's `verified` flag is not read, and its `conflict` flag can only lower a
   verdict ([SECURITY.md](../SECURITY.md#mail-content-and-pgp),
   `Domain/Models/PgpSignatureState.swift`).
3. **Message content → reader.** WebKit with JavaScript off and non-persistent website data
   (`Presentation/Screens/EmailDetailView.swift`, `makeConfiguration`), and a rule list that
   blocks every load except `data:` and `about:` (`Presentation/Components/RemoteContentBlocker.swift`).
4. **App → its storage.** Keychain items are this-device-only. The private key is sealed to a
   Secure Enclave key before it reaches the Keychain (`Domain/Security/EnrollmentVault.swift`).
5. **Build → app.** The only third-party code, GopenPGP, is a binary pinned by SHA-256
   (`Dependencies/GopenPGP/Package.swift`) and imported by one app file,
   `Domain/Security/GopenPGPCrypto.swift` (and by its tests).

## Secure design principles applied

- **Least privilege.** The device secret is not the account password and cannot sign in to
  webmail. With "Require unlock for notifications & MFA" it sits behind a user-presence
  Keychain item (`Data/Storage/GatedCredentialStore.swift`).
- **Fail-safe defaults.** A pin that cannot be read refuses the connection instead of falling
  back to system trust. An unhashable key on a pinned host refuses. A Secure Enclave that will
  not create the PIN pepper key makes setting a PIN fail instead of using a weaker pepper.
  An incomplete wipe keeps the app locked.
- **Complete mediation.** The PIN lockout delay is enforced in `AppLockManager`, not by a
  disabled button, so no second entry point is an unthrottled oracle.
- **Economy of mechanism.** One third-party dependency. Everything else is Apple's
  frameworks: CryptoKit, Security, WebKit, SwiftData.
- **Separation of privilege.** Decrypting needs both the enrollment envelope from the
  server and the Secure Enclave key on this device, behind a presence check.
- **Open design.** OpenPGP through GopenPGP, plus AES-GCM, P-256 ECDH and ECIES, HKDF-SHA-256,
  and SHA-256 SPKI pins. All published.
- **Psychological acceptability.** Each trade-off is written where the user reads it, for
  example trust-on-first-use pinning without `pin=`, and file removal that does not
  overwrite under Hostile Location Protection ([SECURITY.md](../SECURITY.md)).

## Common weaknesses and how they are countered

| Weakness | Counter | Where |
|---|---|---|
| TLS interception with a mis-issued certificate | Per-host SPKI SHA-256 pin; mismatch, unhashable key or unreadable pin all refuse | `Data/Networking/PinnedSessionDelegate.swift` (`decision`, `failure`) |
| Credential leak through a redirect | Redirects only to the same host and effective port over HTTPS, judged from the original request | `PinnedSessionDelegate.allowsRedirect` |
| Response caching and cookies | Ephemeral relay sessions, no URL cache, no cookie store | `PinnedSessionDelegate.relaySessionConfiguration` |
| Tracking pixels and remote loads | Block-all WebKit rule list until the user loads remote content | `Presentation/Components/RemoteContentBlocker.swift` |
| Script in mail (XSS) | `allowsContentJavaScript = false`; non-persistent website data | `Presentation/Screens/EmailDetailView.swift` (`makeConfiguration`) |
| Private key at rest | Sealed with `eciesEncryptionCofactorVariableIVX963SHA256AESGCM` to a Secure Enclave P-256 key made with `.privateKeyUsage`, `.userPresence` and `WhenUnlockedThisDeviceOnly`; the sealed record is an `AfterFirstUnlockThisDeviceOnly` Keychain item | `Domain/Security/EnrollmentVault.swift`, `Data/Storage/KeychainStorage.swift` |
| Envelope tampering | Envelope opened with Secure Enclave ECDH, HKDF-SHA-256 and AES-GCM with associated data | `Domain/Security/VaultSealer.swift` |
| PIN brute force | 8 to 12 digits, common PINs refused, a peppered verifier, delays of 30 s, 60 s, 5, 15 and 30 min from the third failure, wipe after 10 by default | `Domain/Security/PinPolicy.swift`, `LockoutPolicy.swift`, `PinPepper.swift` |
| Forged signature trust | *Confirmed* only from a QR pin on this device; relay-offered keys reach at most *same key as last time*; the relay's `verified` flag is ignored and its `conflict` flag only lowers a verdict | `Domain/Models/PgpSignatureState.swift` |
| Screen capture | `NSWindow.sharingType = .none` on macOS, a capture cover on iOS | `Presentation/Components/CaptureProtection.swift` |
| Secrets in logs | `os.Logger` (`Utilities/Log.swift`), which redacts interpolated strings unless they are marked public (numbers are public by default); the 8 values marked public, at 6 call sites, are wipe step and marker names, layout values and an error type name | `Log` call sites |
| Tampered dependency binary | SHA-256 pin enforced by SwiftPM; built in public CI from a pinned upstream tag | `Dependencies/GopenPGP/Package.swift`, `.github/workflows/gopenpgp-xcframework.yml` |
| Vulnerable or unpinned actions | Every action pinned by commit; Dependabot for GitHub Actions; OpenSSF Scorecard | `.github/workflows/`, `.github/dependabot.yml` |

SHA-1 appears once, to compute version 4 OpenPGP key fingerprints
(`Domain/Security/PgpFingerprint.swift`), because RFC 4880 defines them that way. It is not
used for signatures or integrity.

## Residual risk

- **The GopenPGP binary is trusted, not reproduced.** It cannot be rebuilt to the same
  bytes, and its only provenance record is a workflow log kept for 90 days. No attestation
  exists ([VERIFYING-RELEASES.md](VERIFYING-RELEASES.md#the-gopenpgp-binary)).
- **Pairing without `pin=` is trust on first use.** It cannot detect an attacker already in
  position at pairing.
- **Hostile Location Protection removes files; it does not overwrite them.**
- **Pre-rename Keychain items** on developer machines are out of reach of the wipe.
- **A key enrolled before the seal** stays in the clear in the Keychain until its first
  presence-checked open. In the Simulator, the device key is an ordinary Keychain key, not a
  Secure Enclave one.
- No static analysis covers the Swift code: CodeQL's default setup here analyses only the
  GitHub Actions workflows. No independent security audit has taken place.

Each item is in [SECURITY.md](../SECURITY.md) with what to do about it.

## Evidence

- **Tests:** `KyPost Tests` covers pinning and redirects (`PinnedSessionTests`,
  `SpkiPinLinkTests`), the PIN and lockout (`AppLockPinTests`, `AppLockPinAttemptTests`), the
  wipe (`SecurityWipeTests`, `SecurityWipeStepsTests`), key custody (`VaultCustodyTests`,
  `DeviceEnrollmentTests`), the reader's remote-content blocking (`RemoteContentBlockingTests`)
  and OpenPGP (`GopenPGPCryptoTests`, `PgpMimeReaderTests`). CI runs the unit target on the
  iOS Simulator and compiles for macOS on every pull request.
- **Supply chain:** the GopenPGP pin was checked against the published asset
  ([VERIFYING-RELEASES.md](VERIFYING-RELEASES.md)). OpenSSF Scorecard runs on `main`.
- **Review:** every pull request needs green CI and an adversarial review
  ([CONTRIBUTING.md](../CONTRIBUTING.md#every-pr-must-pass-hostile-ai-code-review)).

This case is updated when a trust boundary or a security requirement changes. A pull request
that moves one must update this page in the same change.
