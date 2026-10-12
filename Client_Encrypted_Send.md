# Encrypted Send from a Paired Client — macOS Integration Guide

> **PARTLY SUPERSEDED — read this first.**
>
> Everything below about **`server`-custody** send is current and implemented. What is obsolete is
> this document's central premise, stated in "Scope": *"this client pairs by QR/deep link and never
> learns the account password … **This client never holds the account's private key.**"*
>
> That stopped being true when the device enrollment ceremony landed. A browser seals the account's
> OpenPGP private key to this Mac's Secure Enclave key, and the app keeps it in
> `Domain/Security/EnrollmentVault`. It already decrypted with it; since Phase 10 it encrypts and
> signs with it too. See `AGENTS.md` — "Client-side encrypted send" and "Device enrollment".
>
> Consequently, for a `client`-custody account on an **enrolled** Mac:
> - "Out of scope, deliberately: bundling GnuPG or Sequoia and doing OpenPGP in this client" — no
>   longer true. GopenPGP is a checksum-pinned XCFramework (`Dependencies/GopenPGP`), consumed
>   through `Domain/Security/PgpCrypto.swift` alone.
> - "Do not build … any call to `POST /api/mail/send-pgp`" — that is now exactly the send path
>   (`Data/Networking/ClientEncryptedSendClient.swift`).
> - "Use `check`, never `resolve`" — still correct for `server`-custody, and inverted here:
>   `/api/pgp/recipients/resolve` is the right and only endpoint for client-side send, and it 409s
>   for precisely the accounts that path excludes.
> - The webmail handoff remains the behaviour for an **unenrolled** Mac.
>
> The rest of this document stands. Do not "fix" the code to match the superseded parts.

This document specifies how this client sends **encrypted and signed mail** through the relay, and
how it handles a recipient who has no PGP key. It mirrors the shape of `Client_PGP_Update.md` and
`Client_Contact_Update.md`: concrete API contracts, exact JSON, and clear scoping — written so a
fresh Claude session working in this repo can implement against it with no other context beyond
reading the current source files it points to.

Written 2026-07-26 against the `kypost-server` branch `feat/mobile-encrypted-send`.

## Prerequisite: the server side is not deployed yet

Every endpoint and field below lives on `feat/mobile-encrypted-send` in `kypost-server`, which is
**not yet merged to `main` and not deployed anywhere**. You can write and unit-test the client
against the contract in this document, but you cannot integration-test until that branch lands.
If a call here 404s or ignores a field, check that first before assuming a client bug.

## Scope

**In scope:** native encrypted/signed send for `server`-custody accounts, the keyless-recipient
confirmation flow, the recipient key preflight, and the webmail handoff for `client`-custody
accounts.

**Out of scope, deliberately:** bundling GnuPG or Sequoia and doing OpenPGP in this client. An
earlier plan called for exactly that. It is superseded and should not be revived without a
conversation. The reasoning, in short: this client pairs by QR/deep link and never learns the
account password, the private key is wrapped under a key derived from that password, and every
workaround is worse — a per-device key breaks inbound mail (a sender encrypts to whichever single
key they discovered via WKD/Autocrypt), a Keychain-held key makes mail recoverable without any user
secret, and server-side re-encryption requires the server to hold the key it would be protecting.
**This client never holds the account's private key.**

## Background: two key-custody modes

Every account with a PGP identity is in exactly one mode, and the two behave completely differently
for sending:

| `protection` | Who holds the private key | Sending from this client |
|---|---|---|
| `"server"` | The server, encrypted at rest under its own key | **Native.** The server signs and encrypts. Same request the browser makes. |
| `"client"` | Only the user's browser, unwrapped from a password-derived key | **Impossible here.** Save a draft and hand off to webmail. |
| `""` | No identity | Plaintext send only. |

The mode is chosen once at key creation and there is no downgrade path, so an account does not
change modes behind your back within a session. Read it from `/api/pgp/bootstrap`.

## API contract

All calls use the same pairing credentials as every other relay call —
`X-Kypost-Device-Id` / `X-Kypost-Device-Secret` headers. There is no desktop login and no session
cookie. Every endpoint below is `withMailAuth`, meaning a paired client is a first-class caller.

**Body format note:** the two 409s and the 200 are JSON. Every other error status returns a
**plain-text** body, not JSON. `RelayMailSource.swift` already decodes the 409 body defensively
(optional fields on `RelayConflictDto`) for this reason; keep that property.

### `GET /api/pgp/bootstrap`

Call once per launch, before offering an encrypt toggle. Response 200:

```json
{
  "hasIdentity": true,
  "protection": "server",
  "fingerprint": "…",
  "keyId": "…",
  "publicKey": "-----BEGIN PGP PUBLIC KEY BLOCK----- …",
  "keySource": "generated",
  "createdAt": "2026-01-01T00:00:00Z"
}
```

The full response carries more fields (`wrappedPrivateKey`, `unlockRequired`, `signerPublicKeys`,
`payloadEndpoint`, …) that exist for the browser. **Ignore them.** The only fields this client needs
are `hasIdentity` and `protection`. Parse permissively — treat unknown fields as ignorable and an
unknown `protection` value as "not `server`", i.e. degrade rather than guess.

### `POST /api/pgp/recipients/check`

The preflight. Ask before sending, so the 409 below is a confirmation rather than a surprise.

Request:
```json
{"addresses": ["alice@example.com", "bob@example.com"]}
```

Response 200:
```json
{"results": [
  {"address": "alice@example.com", "hasKey": true,  "revoked": false, "expired": false, "tier": "contact-verified"},
  {"address": "bob@example.com",   "hasKey": false, "revoked": false, "expired": false, "tier": "none"}
]}
```

`hasKey` is `true` only when a key exists **and** is usable (not revoked, not expired). Read
`revoked`/`expired` only to explain *why* a key is unusable; never treat "revoked but present" as
sendable.

### `POST /api/mail/send`

The same endpoint this client already uses. Three fields are relevant here, all optional and all
defaulting to `false`:

```json
{
  "to": "alice@example.com",
  "cc": "", "bcc": "",
  "subject": "…", "body": "…", "mode": "plain",
  "attachments": [],

  "encrypt": true,
  "sign": true,
  "allowPickupFallback": false
}
```

`allowPickupFallback` is meaningful only when `encrypt` is true.

### Responses

**200 — sent.**
```json
{"ok": true, "sentSaved": true, "warning": ""}
```
`warning` is non-empty on a *partial* problem: the Sent copy failed to save, and/or some pickup
links failed to deliver (`"failed to deliver a pickup link to 1 of 3 recipient(s)"`, possibly
joined to another warning by `"; "`). **The message was still sent.** Show the warning; do not
present it as a failure and do not offer a retry that would duplicate the message. Treat it as
opaque human-readable text — do not pattern-match on its wording.

**409 with `clientSideNeeded` — the account is `client`-custody.**
```json
{"error": "this account's PGP key is end-to-end protected, so the server cannot sign or encrypt on your behalf",
 "clientSideNeeded": true}
```
Categorical. No retry from this client fixes it. Go to the webmail handoff below.

**409 with `keylessRecipients` — at least one recipient has no usable key.**
```json
{"error": "some recipients have no usable PGP key; sending them a one-time link stores this message's plaintext on the server for 7 days",
 "keylessRecipients": ["bob@example.com"],
 "pickupFallbackAvailable": true}
```
**Nothing was delivered.** The refusal happens before any SMTP. Re-sending the identical request
with `allowPickupFallback: true` is safe and cannot duplicate.

**502 — plain text.** Either SMTP failed outright (`"failed to send email: …"`), or every pickup
link failed to deliver (`"failed to deliver a pickup link to any recipient; nothing was sent"`).
Nothing was sent in either case.

**400 — plain text.** Signing requested with no identity, a bad recipient list, oversized
attachments. There is also a legacy `"none of the recipients have a known pgp key…"` 400 that the
409 gate now shadows in practice; handle it generically.

**503 / 401 / 429** behave exactly as they do for every other relay call today.

## Three traps

These are the mistakes this section exists to prevent. Two of them have already been made once.

**1. Use `check`, never `resolve`.** `POST /api/pgp/recipients/resolve` looks like the right
endpoint and is not. It returns recipients' *actual public keys* so a `client`-custody **browser**
can encrypt locally, and it **409s for any account that is not `client`-protected**. A
`server`-custody client asking `resolve` "does this recipient have a key" is refused every time. An
earlier draft of the server design got this backwards.

**2. `check` is contacts-only, so `hasKey: false` is not a prediction of the 409.** The preflight
looks only in the user's contacts. The send path additionally runs the discovery ladder — WKD and
keyserver lookups, subject to the user's discovery settings. So an address the preflight reports as
keyless may well be encrypted to successfully. The preflight is a **lower bound**: use it to warn
early, never to promise. Concretely: do not say "this will be sent as a plaintext link" up front —
say "we don't have a key on file for bob@example.com" and let the 409 be what actually drives the
confirmation.

**3. The pickup link stores plaintext on the server for seven days.** The browser has a second,
sealed variant where it encrypts the message locally and the key rides in the URL fragment. That
path is gated to `client`-custody accounts, which cannot send from this client at all — so **every**
pickup link this client causes to be sent is the server-readable kind. The confirmation UI must say
so honestly. This is the entire reason the opt-in exists; softening the copy defeats it.

## Required behavior

1. **On launch**, `GET /api/pgp/bootstrap`. Cache `hasIdentity` and `protection` for the session.
2. **In compose**, offer "Encrypt" and "Sign" toggles when `hasIdentity` is true. When `protection`
   is `"client"`, either hide them and show the handoff affordance instead, or leave them visible
   and let step 6 handle it — but never let the user believe an encrypted send succeeded from here.
3. **Preflight before send**, when Encrypt is on: `POST /api/pgp/recipients/check` with every To,
   CC and BCC address. Surface addresses with `hasKey: false` as an inline, non-blocking warning
   ("no key on file"), worded per trap 2.
4. **Send** with `encrypt`/`sign` set and `allowPickupFallback: false`.
5. **On 409 with `keylessRecipients`**: show a confirmation naming those exact addresses, stating
   plainly that they will receive a one-time link and that the message's plaintext will sit on the
   server for up to seven days. Default the dialog to cancel. On confirm, re-send the
   **byte-identical request** with `allowPickupFallback: true`. Do not re-run the preflight, do not
   rebuild the message, do not re-encode attachments — rebuild risks a subtly different message.
6. **On 409 with `clientSideNeeded`**: `POST /api/mail/draft` with the same body (minus the PGP
   fields) to save the composed message, then open `/read?mailbox=Drafts` on the paired server's
   base URL via the environment `openURL` action, so the user's browser handles it. Explain why:
   the key is held only in the browser. Never render this in an embedded `WKWebView` — it shares no
   session and would put an account-password field inside this app. Note that **this client does
   not implement `POST /api/mail/draft` yet** (see below); that call has to be built as part of
   this step.
7. **On 200 with a non-empty `warning`**: show it as a notice on a successful send.
8. **Discriminate the two 409s by field, not by status code, and not by the error prose.** The
   messages are user-facing copy and may be reworded; the fields are the contract.

## Confirmation dialog copy

The wording carries the security property, so it is part of the contract rather than a detail to
be improvised:

> **Send an unencrypted link?**
>
> We don't have a PGP key for bob@example.com. They'll get an email with a one-time link instead.
>
> To make that work, this message's contents are stored on your KyPost server — unencrypted — for
> up to 7 days or until the link is opened. Everyone else on this message still gets it encrypted.
>
> [ Cancel ] [ Send link anyway ]

Name the addresses explicitly. Do not summarize as "some recipients".

## Do not build

- Any OpenPGP implementation, key generation, or key unwrapping in this client. See Scope.
- Any call to `POST /api/pgp/pickup` (the browser-sealed pickup path). It 409s for
  `server`-custody accounts by design.
- Any call to `POST /api/mail/send-pgp`. That endpoint takes a pre-built ciphertext delivery from a
  client that did its own encryption; this client never has one.
- A remembered "always allow pickup fallback" preference. The opt-in is per-message on the web for
  a reason — it was a specific review finding that the checkbox must reset on every compose.

## Current state of this repo (`kypost-for-Mac`)

Already implemented, do not redo:

- Read-side PGP message state — `KyPost/Domain/Models/PgpMessageState.swift`,
  `KyPost/Domain/Models/Email.swift`, `KyPost/Data/Database/EmailEntity.swift`, surfaced through
  `KyPost/Presentation/Screens/EmailDetailView.swift` and
  `KyPost/Presentation/Components/EmailListRow.swift`. Tests in
  `KyPost Tests/PgpMessageStateTests.swift`. Design notes in
  `docs/superpowers/specs/2026-07-25-pgp-message-state-design.md`.
- The `clientSideNeeded` 409 — `RelayConflictDto` at `KyPost/Data/Mail/RelayMailSource.swift:162`,
  thrown as `MailSourceError.clientSideNeeded` around `:367-383`.

To add:

- **Draft save.** Unlike `kypost-android` and `kypost-Linux`, this client has no
  `POST /api/mail/draft` call at all — `RelayMailSource.swift:203` only mentions the endpoint in a
  comment. The `client`-custody handoff in step 6 depends on it, so it has to be built here first.
  The request body is the same shared shape as `/api/mail/send` (to/cc/bcc/subject/body/mode/
  attachments); the response is `{"ok": true}` and every failure is a plain-text error.
- `encrypt`, `sign`, `allowPickupFallback` on the send request body around
  `RelayMailSource.swift:367`, and on whatever carries them from `ComposeViewModel`.
- The second 409 shape: extend `RelayConflictDto` with `keylessRecipients: [String]?` and
  `pickupFallbackAvailable: Bool?`, and add a `MailSourceError` case carrying the address list. A
  409 with neither field must still map to a generic error rather than inheriting PGP wording.
- The preflight call and its DTOs.
- The compose-side confirmation dialog and the re-send.
- Surfacing `warning` from the 200 body, if compose does not already.

Tests belong in `KyPost Tests/MailTests.swift` alongside the existing relay tests. Cover at minimum:
both 409 shapes mapping to distinct errors; a 409 body with neither field falling back to a generic
error; a malformed 409 body not crashing the decode; the re-send carrying
`allowPickupFallback: true` with an otherwise identical body; and a 200 with a non-empty `warning`
still counting as success.
