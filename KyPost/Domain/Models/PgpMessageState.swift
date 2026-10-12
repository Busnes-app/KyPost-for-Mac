//
//  PgpMessageState.swift
//  KyPost
//
//  What this app can actually do with a message's OpenPGP content.
//
//  Pure functions of the relay's pgp* fields, so the decisions are testable
//  without SwiftUI or a stubbed network and no view re-derives them. Ported
//  from kypost-android's pgp/PgpMessageState.kt and pgp/WebmailDeepLink.kt.
//
//  This app holds no PGP private key and will not gain one — see
//  kypost-server/docs/E2E_PGP.md. Mobile and desktop-native clients implement
//  the degradation, never the crypto.
//

import Foundation

nonisolated enum PgpMessageState: Equatable, Sendable {
    /// No OpenPGP content: render normally.
    case none

    /// Encrypted, and the server deliberately did not decrypt it because the
    /// account's key is end-to-end protected. There is no body from the server.
    ///
    /// This no longer means "cannot be read here". Since device enrollment, it
    /// means **not readable here unless this device is enrolled and unlocked**
    /// — the reader can fetch the payload and decrypt it locally. Webmail
    /// remains the fallback for every device that is not enrolled, which is
    /// most of them, so nothing that mentions webmail becomes wrong; it just
    /// stops being the only route.
    case clientProtected

    /// Encrypted, and the server tried to decrypt and failed. There is a real
    /// error to show.
    case decryptFailed

    /// Encrypted, and the server decrypted it for us. Worth surfacing rather
    /// than rendering silently: the user should be able to tell that the
    /// server read their mail.
    case decryptedByServer
}

/// The ordering matters. A non-blank `pgpDecryptError` is checked before the
/// body, because the server populates the error and leaves the body empty —
/// reading that as `.clientProtected` would tell the user to go to webmail for
/// a message that will fail there too, for a reason we were already told.
nonisolated func pgpMessageState(
    pgpEncrypted: Bool,
    pgpDecryptError: String,
    body: String?
) -> PgpMessageState {
    guard pgpEncrypted else { return .none }
    if !pgpDecryptError.isBlank { return .decryptFailed }
    if let body, !body.isBlank { return .decryptedByServer }
    return .clientProtected
}

/// SF Symbol for an inbox row, or nil for no marker.
///
/// Only the two states that yield no readable content are marked.
/// `.decryptedByServer` is deliberately unmarked: the row opens and reads
/// normally, so a marker there would sit on most rows of a server-mode mailbox
/// carrying nothing the user can act on — and the detail view already discloses
/// that the server decrypted it.
nonisolated func pgpRowSymbol(_ state: PgpMessageState) -> String? {
    switch state {
    case .clientProtected: "lock.fill"
    case .decryptFailed: "exclamationmark.triangle.fill"
    case .none, .decryptedByServer: nil
    }
}

/// The one marker a row shows for its OpenPGP state, signature included.
///
/// A failed signature or a changed signer key **outranks** the content state:
/// "we couldn't read this" is a smaller thing to say than "the key this sender
/// signs with is not the one you pinned". Where neither applies, the content
/// state's own marker stands.
nonisolated func pgpRowSymbol(
    content: PgpMessageState,
    signature: PgpSignatureState
) -> String? {
    signatureRowSymbol(signature) ?? pgpRowSymbol(content)
}

/// Spelled-out row label for VoiceOver, or nil when the row carries no marker.
///
/// `deviceIsEnrolled` changes what the lock on a client-protected row *means*.
/// Announcing "can't be read in this app" on a device that can in fact open it
/// is a false statement to the one user who cannot see the screen to check —
/// so the sentence follows the device's actual capability rather than the
/// message's state alone.
nonisolated func pgpRowAccessibilityLabel(
    state: PgpMessageState,
    subject: String,
    deviceIsEnrolled: Bool
) -> String? {
    switch state {
    case .clientProtected:
        deviceIsEnrolled
            ? "Encrypted, unlock to read: \(subject)"
            : "Encrypted, can't be read in this app: \(subject)"
    case .decryptFailed: "Encrypted, couldn't be decrypted: \(subject)"
    case .none, .decryptedByServer: nil
    }
}

/// Whether to show a signature verdict at all.
///
/// True only for `.decryptedByServer`. For a client-protected message the
/// server never saw the plaintext, so its `pgpSigned`/`pgpVerified` values are
/// not a verdict about content anyone verified — showing "signature not
/// verified" would assert something we have no basis for.
///
/// This stays false for `.clientProtected` even now that the app can decrypt
/// locally, and the distinction is the point: after an on-device decrypt the
/// verdict comes from `ReadOutcome.decrypted`, computed over plaintext this
/// device actually verified. These server flags never become that, so they
/// must not be rendered as though they had.
nonisolated func showsSignaturePill(state: PgpMessageState, signed: Bool) -> Bool {
    state == .decryptedByServer && signed
}

/// Whether Reply, Reply All and Forward may open compose for a message.
///
/// False only for `.clientProtected`. A reply to one would either quote the
/// decrypted plaintext into a `ComposeDraft` — a scene value state
/// restoration archives to disk — or hand off through a server-side draft
/// (`/api/mail/draft`), which uploads it. Webmail, where the browser holds
/// the key, is the place to answer it. Decided from the row's state, so it
/// holds before, during and after an on-device decrypt.
nonisolated func mayReplyOrForward(_ state: PgpMessageState) -> Bool {
    state != .clientProtected
}

/// Whether the reader offers "Open in webmail" for a client-protected message:
/// only when this device cannot read it.
///
/// - Not enrolled: no key will ever be held here.
/// - Before an outcome, or after `needsUnlock`/`cancelled`: Decrypt is the
///   offer, and the user is the missing input — not webmail.
/// - Decrypted: only when parts were dropped, so the missing files have
///   somewhere to be fetched from.
/// - Every other outcome means this device could not open the message.
nonisolated func readerOffersWebmail(
    outcome: ReadOutcome?,
    deviceIsEnrolled: Bool,
    attachmentsOmitted: Bool
) -> Bool {
    switch outcome {
    case nil, .needsUnlock, .cancelled:
        !deviceIsEnrolled
    case .decrypted:
        attachmentsOmitted
    case .notEnrolled, .noSecureLockScreen, .tooLarge, .notClientProtected,
         .noEncryptedContent, .unsealFailed, .fetchFailed, .decryptFailed:
        true
    }
}

/// `/read` URL components for the paired server, or nil when `serverUrl` isn't
/// a usable absolute URL — callers render "no button" rather than a dead one.
///
/// INBOX is sent as an absent `mailbox` param rather than the literal string,
/// matching the links the web app builds for itself.
private nonisolated func webmailReadComponents(
    serverUrl: String,
    mailbox: String
) -> URLComponents? {
    let trimmed = serverUrl.trimmingCharacters(in: .whitespaces)
    let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    guard var components = URLComponents(string: base),
          components.scheme != nil,
          components.host != nil
    else { return nil }

    components.path += "/read"

    let mailbox = mailbox.trimmingCharacters(in: .whitespaces)
    if !mailbox.isEmpty, mailbox.caseInsensitiveCompare(StandardFolder.inbox) != .orderedSame {
        components.queryItems = [URLQueryItem(name: "mailbox", value: mailbox)]
    }
    return components.url == nil ? nil : components
}

/// Builds the webmail URL that opens one mailbox — the compose handoff opens
/// Drafts after saving, because a client-protected key exists only in the
/// browser.
nonisolated func webmailMailboxURL(serverUrl: String, mailbox: String) -> URL? {
    webmailReadComponents(serverUrl: serverUrl, mailbox: mailbox)?.url
}

/// Builds the webmail URL that opens one specific message — the same `/read`
/// route a web push click uses, so no server change backs it.
nonisolated func webmailMessageURL(serverUrl: String, mailbox: String, messageId: String) -> URL? {
    guard !messageId.isBlank,
          var components = webmailReadComponents(serverUrl: serverUrl, mailbox: mailbox)
    else { return nil }
    components.queryItems = (components.queryItems ?? [])
        + [URLQueryItem(name: "message", value: messageId)]
    return components.url
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
