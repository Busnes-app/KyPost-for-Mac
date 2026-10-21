//
//  PgpComposeState.swift
//  KyPost
//
//  Which PGP controls compose offers, and how recipients are split for a
//  client-encrypted send. Swift port of kypost-android's pgp/PgpComposeState.kt
//  and pgp/RecipientFields.kt.
//

import Foundation

/// The two `protection` values this app understands. Anything else degrades to
/// "not server".
nonisolated let pgpProtectionServer = "server"
nonisolated let pgpProtectionClient = "client"

nonisolated struct PgpComposeState: Equatable, Sendable {
    var canEncrypt: Bool
    var canSign: Bool
    /// Show "Continue in webmail" instead of the toggles: this account's key is
    /// held only by the user and this device is not enrolled, so neither the
    /// server nor this app can encrypt on its behalf.
    var handoffToWebmail: Bool
    /// The encryption happens **here**, and the send goes to
    /// `/api/mail/send-pgp` rather than `/api/mail/send`.
    ///
    /// One flag rather than leaving the view to re-derive the combination:
    /// getting it wrong means posting encrypt/sign flags to the endpoint that
    /// answers 409 for precisely this account type.
    var clientSide = false
}

/// - Parameters:
///   - hasIdentity: nil when bootstrap could not be reached.
///   - protection: nil when bootstrap could not be reached. Unknown hides
///     everything — guessing "server" offers a toggle that 409s, and guessing
///     "client" sends people to webmail for no reason. An unrecognised
///     non-nil value is treated as "not server": degrade, never guess.
///   - deviceEnrolled: whether this device still holds the account's key.
///   - accountAddress: bootstrap's `suggestedUserIDs[0]` and nothing else —
///     the server derives it from the same expression. Blank means no mail
///     account is configured, so no delivery `From` can be built, and an
///     enrolled client-custody account still falls back to the handoff rather
///     than offering a Send the relay is certain to refuse with 403.
nonisolated func pgpComposeState(
    hasIdentity: Bool?,
    protection: String?,
    deviceEnrolled: Bool = false,
    accountAddress: String = ""
) -> PgpComposeState {
    guard let protection, hasIdentity == true else {
        return PgpComposeState(canEncrypt: false, canSign: false, handoffToWebmail: false)
    }
    // An enrolled device holds the key the browser sealed to it, so it can do
    // the crypto itself. This is the case the old "this device never holds the
    // account's private key" contract ruled out; enrollment replaced it.
    if protection == pgpProtectionClient,
       deviceEnrolled,
       !accountAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return PgpComposeState(
            canEncrypt: true, canSign: true, handoffToWebmail: false, clientSide: true
        )
    }
    if protection == pgpProtectionClient {
        return PgpComposeState(canEncrypt: false, canSign: false, handoffToWebmail: true)
    }
    if protection == pgpProtectionServer {
        return PgpComposeState(canEncrypt: true, canSign: true, handoffToWebmail: false)
    }
    return PgpComposeState(canEncrypt: false, canSign: false, handoffToWebmail: false)
}

/// What compose's webmail handoff may do with the composed message.
nonisolated enum DraftHandoffMode: Equatable, Sendable {
    /// Encrypt and sign the draft to the account's own key on this device, and
    /// upload only the ciphertext.
    case encryptAndSave
    /// Upload nothing and open webmail: this device holds no key to encrypt
    /// with, and a client-custody draft is never posted in the clear.
    case openWithoutSave
    /// Upload nothing: custody is unknown or not client, or no `From` can be
    /// built.
    case refuse
}

/// Android `draftHandoffMode`. Decided when the handoff runs, never when the
/// window opened: enrollment can change in between.
nonisolated func draftHandoffMode(
    hasIdentity: Bool?,
    protection: String?,
    enrolled: Bool,
    accountAddress: String
) -> DraftHandoffMode {
    guard hasIdentity == true, protection == pgpProtectionClient else { return .refuse }
    guard enrolled else { return .openWithoutSave }
    guard !accountAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .refuse }
    return .encryptAndSave
}

/// What compose's Save Draft button may upload.
nonisolated enum DraftSaveMode: Equatable, Sendable {
    /// Encrypt and sign to the account's own key here; upload only `{to, pgpDraft}`.
    case encrypted
    /// Upload the fields as they are. Only where the relay already reads them
    /// at send time: server custody, or no PGP identity at all.
    case plain
    /// Upload nothing, and hide the button.
    case unavailable
}

/// Linux `Compose.qml` `trySaveDraft`. Reads bootstrap's raw answers, never
/// `PgpKeyCustody`: that maps an unknown `hasIdentity` to `.noIdentity`, which
/// would turn "unknown" into "plain". Fails closed on anything unrecognised.
nonisolated func draftSaveMode(
    hasIdentity: Bool?,
    protection: String?,
    enrolled: Bool,
    accountAddress: String
) -> DraftSaveMode {
    let handoff = draftHandoffMode(
        hasIdentity: hasIdentity, protection: protection,
        enrolled: enrolled, accountAddress: accountAddress
    )
    if handoff == .encryptAndSave { return .encrypted }
    switch hasIdentity {
    case true?:
        return protection == pgpProtectionServer ? .plain : .unavailable
    case false?:
        let blank = (protection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return blank ? .plain : .unavailable
    case nil:
        return .unavailable
    }
}

/// Compose's three recipient fields, split and de-overlapped.
nonisolated struct RecipientFields: Equatable, Sendable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []

    var all: [String] { to + cc + bcc }
}

/// Splits the comma-joined recipient fields, **keeping each field distinct**.
///
/// Deliberately not the preflight's flatten-and-dedupe. There the question is
/// "which addresses need a key", and asking twice about one person is only
/// noise. Reusing that here would collapse a BCC recipient into the To bucket,
/// putting someone the sender marked blind into a header every other recipient
/// reads.
///
/// Overlap is resolved by precedence rather than kept: an address already in To
/// is dropped from CC and BCC, and one already in CC is dropped from BCC.
/// Keeping it would build that person a second, redundant delivery *and* leave
/// the sender believing the extra copy was blind while the To header already
/// names them. First spelling wins, since that is the one the user typed and
/// will see named back to them.
nonisolated func splitRecipientFields(to: String, cc: String, bcc: String) -> RecipientFields {
    var seen = Set<String>()
    func take(_ field: String) -> [String] {
        field.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
    // Evaluation order *is* the precedence: To, then CC, then BCC.
    let toList = take(to)
    let ccList = take(cc)
    return RecipientFields(to: toList, cc: ccList, bcc: take(bcc))
}
