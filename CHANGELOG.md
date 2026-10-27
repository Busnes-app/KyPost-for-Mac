# Changelog

## Unreleased

### Security

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
