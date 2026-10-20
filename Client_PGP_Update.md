# PGP Key Exchange via QR Code — Mobile Integration Guide

> Implementation record: this note uses historical repository names and describes its original rollout. For current installation and supported behavior, start with [README.md](README.md); KyPost Server owns the current wire contracts. Completion notes here do not establish present-day live integration coverage.

This document describes how to add PGP key-exchange functionality to this (separate-repo) mobile app,
enabling users to share their PGP public keys in person via QR code (akin to a PGP key-signing
handshake). It mirrors `Client_Contact_Update.md`'s shape — concrete API contracts, suggested UI
flows, and clear scoping — written so a fresh Claude session working in this repo can implement
against it with no other context beyond reading the current source files it points to.

The backend (`llama-labels` repo) now supports per-user PGP identities and provides two QR-gated
endpoints that mint time-limited session tokens and serve public keys over HTTPS. This document
specifies the mobile contract and suggests how to integrate this into the existing contact sync
workflow.

## Context

The `llama-labels` backend's `PUT /api/contacts/{id}` endpoint already supports a `pgpKey` field
(armored ASCII string) on the `Contact` schema, as documented in `Client_Contact_Update.md`
(Part 5, "Fields with no device mapping"). Users can attach a PGP public key to any contact —
either pasted manually or, now, scanned from this mobile app's QR reader.

To participate in a PGP key-exchange handshake in person:

1. **User A** generates a temporary QR code (valid for 2 minutes) via the app's "My QR Code" screen,
   which calls a backend session-authenticated endpoint.
2. **User B** uses the app's "Scan to add contact key" scanner to read User A's QR code.
3. The scanner decodes the HTTPS URL embedded in the QR, fetches the public key data (which is
   token-gated but public), displays a fingerprint for User A to confirm out-of-band, and offers
   to save the key to a contact (new or existing) via the standard `/api/contacts` sync flow.

This follows the same user-controlled key binding pattern already established for contacts: the app
does not auto-fetch keys from a keyserver, only stores and displays keys the user explicitly
handles.

## QR Payload Format

The QR code encodes a single HTTPS URL: the `url` field returned by `GET /api/pgp/qr/token`.

**Format:** `https://<host>/api/pgp/qr/key?t=<token>`

This is a plain HTTPS URL. Any generic QR scanner (barcode library, device camera app, etc.) can
read it — the data is not app-specific. However, the mobile app's own scanner should treat a
successfully-decoded `/api/pgp/qr/key` URL as a signal to fetch and parse the JSON contract
described below.

## API Contract

### `GET /api/pgp/qr/token`

**Authentication:** Session cookie (via the app's login session).

**TTL:** 2 minutes.

**Response (200 OK):**
```json
{
  "token": "string",
  "expiresAt": "RFC3339 timestamp (e.g. 2025-07-14T12:34:56Z)",
  "url": "https://<host>/api/pgp/qr/key?t=<token>"
}
```

**Response on error:**
- **400 Bad Request:** The caller has no PGP identity configured yet (generate or import one first).
- **401 Unauthorized:** Session cookie missing or expired.
- **503 Service Unavailable:** The server's pairing subsystem isn't configured (a persistent ops
  issue, not something a client-side retry will resolve — surface this distinctly from a transient
  failure).

**Usage:** Call this endpoint when the user taps "Show My QR Code" on the "My QR Code" screen.
Render the returned `url` as a QR code. Refresh before `expiresAt` (or offer a pull-to-refresh
gesture) to extend the TTL.

### `GET /api/pgp/qr/key?t=<token>`

**Authentication:** None required (token is the credential).

**Query parameter:** `t=<token>` (the token from the response above).

**Response on success (200 OK):**
```json
{
  "name": "string",
  "fingerprint": "string (hex, e.g. A1B2C3D4E5F6...)",
  "publicKey": "string (PGP armored ASCII block)"
}
```

**Response on error:**
- **403 Forbidden:** Token is invalid, expired, or has a tampered/mismatched signature.
- **404 Not Found:** The token owner has no PGP identity configured (backend still running, but
  user hasn't generated a key yet).
- **503 Service Unavailable:** The server's pairing subsystem isn't configured — a persistent ops
  issue, not a transient failure; don't retry indefinitely.

**Usage:** When the app's scanner decodes a `/api/pgp/qr/key` URL, extract the `t` parameter and
GET this endpoint. Parse the response; on success, display the `fingerprint` to the user for
out-of-band verification (e.g., "Does this match what [other person]'s device shows?"), then
offer to save `publicKey` to a contact via the `PUT /api/contacts/{id}` endpoint's `pgpKey` field
(see `Client_Contact_Update.md` for the sync flow).

## Suggested Screens

### Screen 1: "My QR Code"

An authenticated screen (part of Settings or a dedicated encryption section) that:

1. **On load:** Calls `GET /api/pgp/qr/token` and renders the returned `url` as a QR code using
   the QR-generation library of your choice (e.g., QR code generator, native APIs, or a third-party
   package).
2. **Displays:** The generated code, plus the `expiresAt` timestamp so the user knows when to
   refresh.
3. **Pull-to-refresh / refresh button:** Calls the endpoint again to mint a new token before the
   old one expires.
4. **Error handling:** If the endpoint returns `400`, display a message like "You haven't set up
   PGP encryption yet. Go to [Settings] to generate a key." If it returns `401`, the session has
   expired — prompt to re-authenticate. If it returns `503`, this is a persistent server
   configuration issue, not a transient one — show a static "unavailable" message rather than an
   auto-retry loop.

### Screen 2: "Scan to Add Contact Key"

A screen with a QR/barcode scanner that:

1. **Scanner input:** Decodes a QR code (or any barcode/URL). If the decoded data is an HTTPS URL
   pointing to `/api/pgp/qr/key?t=...`, extract the token.
2. **Fetch the key:** GET `/api/pgp/qr/key?t=<token>`. If the response is `200 OK`:
   - Display the `fingerprint` (and optionally the `name`) for visual confirmation.
   - Include a message like "Confirm this fingerprint matches [other person]'s device before saving."
3. **User confirmation:** Once the user confirms the fingerprint, present a contact picker or
   create-new-contact flow:
   - If the user selects an existing contact: propose saving the `publicKey` to that contact's
     `pgpKey` field via `PUT /api/contacts/{id}` (existing sync endpoint from `Client_Contact_Update.md`).
   - If the user chooses to create a new contact: pre-populate `name` from the QR response and
     save the key in a `PUT /api/contacts` create call.
4. **Error handling:**
   - If the URL is not a valid `/api/pgp/qr/key` URL, display "Invalid QR code" and prompt to scan
     again.
   - If the GET fails with `403`, display "Token expired or invalid. Ask the other person to
     refresh their QR code and scan again."
   - If the GET fails with `404`, display "This person hasn't set up PGP encryption yet."
   - If the GET fails with `503`, this is a persistent server configuration issue on the other
     person's server — don't offer an immediate retry as the fix; show a static "unavailable"
     message instead.
   - If the sync `PUT /api/contacts/...` call fails, display a sync error (reuse the same UX
     pattern as the existing contact sync).

## Explicitly Deferred

The following aspects are **not** specified by this document and are left to whoever implements
this feature:

- **QR scanning library choice:** Which barcode/QR scanning library to use (native OS camera
  integration, a third-party Kotlin/Swift/Dart package, etc.) is a platform-specific decision.
  This guide specifies only the contract (URL format) and the expected flow; the scanner
  implementation is open.
- **QR code generation library choice:** Similarly, the library used to render the QR code on the
  "My QR Code" screen (native OS support, third-party package, etc.) is not prescribed.
- **Exact UI/UX hookup:** How "My QR Code" and "Scan to add contact key" screens integrate into
  the existing Android/iOS navigation, where they appear in Settings or elsewhere, button labels,
  and screen layout are all left to the implementer.
- **Android/iOS-specific UI patterns:** Use of platform-native dialogs, bottom sheets, snackbars,
  haptic feedback, etc. is not prescribed — apply the platform's own conventions.

---

## Verification (Manual)

Once implemented, test the following:

- [ ] Call `GET /api/pgp/qr/token` with a valid session cookie; confirm the response includes a
      valid, unique token and an HTTPS URL.
- [ ] Call `GET /api/pgp/qr/key?t=<token>` unauthenticated; confirm it returns the user's public
      key, fingerprint, and name.
- [ ] Let the token expire (wait > 2 minutes) and call `GET /api/pgp/qr/key?t=<token>` again;
      confirm it returns `403 Forbidden`.
- [ ] As User A, generate a QR code on "My QR Code", scan it with User B's device running the
      "Scan to add contact key" flow. Confirm User B sees User A's fingerprint for visual
      confirmation.
- [ ] Complete the contact-save flow: confirm the key lands on the contact's `pgpKey` field in
      the backend and survives a full sync round-trip (pull, store in Room, push).
- [ ] Attempt to scan a QR code for a user with no PGP key configured; confirm the error handling
      shows "This person hasn't set up PGP encryption yet" or similar.
