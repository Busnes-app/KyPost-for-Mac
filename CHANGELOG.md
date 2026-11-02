# Changelog

## Unreleased

### Fixed

- **Reply All leaves out your account address even when your IMAP login is
  not one.** The app now reads your own addresses from the relay's bootstrap
  `accountAddresses` (KyPost-Server 0.4.3 and later), falling back to
  `suggestedUserIDs` on older relays. Before, an account whose login was not
  an email address put its own address back in Cc.

### Changed

- **Themes are the suite's six light/dark pairs**: Busnes (the default),
  Matter, Ocean, Forest, Ky and Nord, matching the web apps (ky-ui 0.11.0).
  Each pair follows the device's light or dark setting unless Settings →
  Theme (macOS: Settings → Appearance) forces Light or Dark. A saved Busnes
  Light or Dark keeps Busnes with that half forced, a palette that lives on
  in a pair keeps it, and a removed palette (Tropics, Tropic Night, Coffee,
  Cyber Punk, Neon Purple, Space, Sky, Sun) resets to Busnes following the
  device.
- **Errors, warnings and success have their own colours**, never the accent:
  a cool crimson for errors, and a teal success on Forest. Every status
  shows an icon beside its words, including the "Unable to connect" toast.
- **iPad and the unfolded iPhone Duo use a navigation rail on the right**
  instead of the tab bar.

### Security

- **New devices wait for approval on the web** (KyPost-Server 0.6.0, #516).
  A pairing code from Settings → Security → Devices now registers the device
  pending: the app shows a six-digit code and waits until you approve it on
  the web page that showed the same code. Denied or timed out, it says
  "Not approved: denied or timed out. Scan a new code." and keeps nothing.
  KyIdentity sign-on still pairs at once. Before, the app treated the
  server's pending answer as a finished pairing.

- **TLS certificates need strong keys on the whole chain.** Every app connection
  now runs the system's trust evaluation itself, then requires RSA of at least
  2048 actual bits or EC of at least P-256 on every certificate of the evaluated
  chain, root included, and TLS 1.2 or later. A relay whose chain carries a
  shorter key, P-224 or Ed25519 is refused before any request, with its own
  error. Before, a 2047-bit RSA certificate passed system trust and connected.
  See `docs/STRONG-CRYPTO.md`.
- **OpenPGP keys under RSA-2048 are refused.** GopenPGP accepted 2047-bit RSA.
  Encrypting to such a recipient now refuses the message rather than dropping
  the recipient; its signatures no longer verify; a device key that short
  cannot sign. Mail already sent to a short key still decrypts.

- **Device enrollment accepts only RFC 9180 HPKE envelopes (v4/v5).** The app
  publishes `envelopeVersions: [4, 5]` and opens only mode_base, KEM 0x0010
  DHKEM(P-256, HKDF-SHA256), KDF 0x0001 HKDF-SHA256, AEAD 0x0002 AES-256-GCM. The
  HPKE `info` binds `kypost-device-envelope/vN`, this device's id and the account
  fingerprint, each length-prefixed; the HPKE AAD is empty. The custom v2/v3
  formats are retired for new enrollment and their decrypt code is removed. Keys
  already enrolled are unaffected: the vault stores opened material, not
  envelopes.
- **A server that does not record its delivery can no longer enrol this
  device.** The old-server path (an envelope with no `version`, opened as v2) is
  gone. KyPost-Server main already delivers v4/v5 to a device that advertises
  them; an older server must be updated first.
