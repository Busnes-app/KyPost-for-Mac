# Changelog

## Unreleased

### Security

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
