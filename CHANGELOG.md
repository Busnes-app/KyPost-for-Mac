# Changelog

## Unreleased

### Fixed

- **A message nested thousands of MIME levels deep no longer crashes the
  reader** when it is decrypted or verified. Parsing stops at 12 levels and
  1,000 parts.
- **An attachment that finishes downloading after the app locks no longer
  opens** its preview or save panel over the lock.
- **Unpairing in Settings forgets the account's key custody and aliases**, and
  closes open compose windows, so the next account's drafts and sends do not
  use the previous account's state.
- **A security wipe that could not remove the cards it exported to Contacts
  no longer reports complete** on its next run. It keeps the list of cards
  until they are deleted.
- **A recipient key that cannot be read refuses the encrypted send**, instead
  of sending mail that recipient cannot open.
- **Attachment names, the subject and the sender line are shown with control
  and text-direction characters removed**, and an attachment is saved under
  the cleaned name. System keywords (`$Phishing` and so on) are no longer
  shown as chips in the reader.
- **Compose is read-only while a draft saves or a message sends**, so text
  typed meanwhile is not lost when the window closes.
- "Unlock Key to Verify" no longer keeps the private key in memory if the
  app locks while it opens.

### Changed

- **The signature is a mobile signature, kept on this device** and separate
  from the web signature you set in KyPost on the web. Settings → Signature
  has an on/off switch (off for a new signature; one you already saved stays
  on) and "Add to replies" / "Add to forwards". It is inserted without a
  `-- ` line, with a blank line each side, above any quoted text, and up to
  2,000 characters; control characters and invisible text-direction
  characters are refused.

## 0.6.0 — 2026-11-02

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

- **Contacts leave Apple Contacts only after you agree.** Turning on Sync with
  Apple Contacts now first shows what is sent, to which server (named by its
  address), how that server uses contacts and how long it keeps them, with
  **Agree** and **Not now**. Only Agree leads to the Contacts permission
  prompt. Consent belongs to one server, by its full address: pairing
  another, even on the same host with another port or path, needs it again.
  Turning it off also stops cards already imported from Apple Contacts but
  not yet sent from going out, including during a sync already under way
  and after "Remove Exported Contacts". The
  Contacts row says "On. Contacts are sent to <server>." or "Off.", and
  turning it off asks first, then stops sync and keeps the cards. The
  Contacts screen's Sync shows the same text. Before, the toggle started
  two-way sync after only the iOS prompt, and cards added in Apple Contacts
  were uploaded with no warning.
- **Installs that had Sync with Apple Contacts on read as off after updating**
  until you agree. Nothing is read from or written to Apple Contacts until
  then; cards already there stay.
- **Unsent contacts from before this update are held back** until you edit
  them in KyPost: the app cannot tell whether each came from Apple Contacts.
  Cards known to be Apple Contacts imports stay unsent, edited or not.
  Contacts you create in KyPost after updating sync as before.
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
