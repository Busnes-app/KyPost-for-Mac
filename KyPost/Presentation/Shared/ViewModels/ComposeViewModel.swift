//
//  ComposeViewModel.swift
//  KyPost
//
//  Compose state (spec §7). On failure the draft stays in memory — no DB
//  auto-save. The body is rich text: formatted drafts send as mode:"html"
//  (RichTextHTML), unformatted ones stay mode:"plain".
//
//  Also owns the encrypted-send flow (Client_Encrypted_Send.md): the per-message
//  encrypt/sign opt-in, the advisory keyless preflight, the one-time-link
//  confirmation and its byte-identical re-send, and the client-custody webmail
//  handoff. None of the PGP flags are ever persisted.
//

import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A file staged for sending; kept in memory with its loaded bytes.
struct ComposeAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var mimeType: String
    var data: Data
}

/// Which address field a token belongs to. Also the focus identity for
/// compose's recipient rows.
nonisolated enum RecipientField: Hashable, CaseIterable, Sendable {
    case to, cc, bcc

    var label: String {
        switch self {
        case .to: "To:"
        case .cc: "Cc:"
        case .bcc: "Bcc:"
        }
    }
}

/// A send the relay refused because some recipients have no usable key.
///
/// Holds the exact `OutgoingEmail` that was refused: the re-send must be
/// byte-identical apart from `allowPickupFallback`, so nothing is rebuilt from
/// live compose state (Client_Encrypted_Send.md "Required behavior" 5).
nonisolated struct PendingPickup: Identifiable {
    let id = UUID()
    var addresses: [String]
    var email: OutgoingEmail
}

@Observable
@MainActor
final class ComposeViewModel {
    private let sendEmail: SendEmailUseCase
    private let contacts: ContactsViewModel
    private let pgp: PgpSendService
    private let debounceInterval: Duration

    var to: [RecipientToken] = []
    var cc: [RecipientToken] = []
    var bcc: [RecipientToken] = []
    var subject = ""
    var body = AttributedString()
    var attachments: [ComposeAttachment] = []

    /// Text typed but not yet committed to a token, per field. This lives on
    /// the model rather than in the view's @State so `send()` can flush it —
    /// otherwise typing a recipient and hitting ⌘↩ mails it to nobody.
    var toInput = ""
    var ccInput = ""
    var bccInput = ""

    private(set) var suggestions: [ContactMatch] = []
    /// Which field the visible dropdown belongs to; nil when it's closed.
    private(set) var suggestionsField: RecipientField?
    private(set) var toastMessage: String?
    private(set) var isSending = false
    private(set) var errorMessage: String?
    private(set) var didSend = false

    /// PGP send flags. Fresh per compose window, and `allowPickupFallback` is
    /// never stored anywhere: the one-time-link opt-in is per message by
    /// design, and a remembered "always allow" was a specific review finding.
    var encrypt = false
    var sign = false

    /// Addresses the contacts-only preflight found no key for. A warning, not
    /// a prediction — the send path also runs WKD/keyserver discovery.
    private(set) var keylessWarning: [String] = []
    /// Set when the relay refused a send for keyless recipients; drives the
    /// confirmation dialog.
    private(set) var pendingPickup: PendingPickup?
    /// A non-failure notice: the relay's partial-success `warning`, or the
    /// webmail-handoff explanation.
    private(set) var noticeMessage: String?
    /// The message went out (or was handed off). Send stays disabled — a retry
    /// would duplicate it — but the window stays open so the notice is readable.
    private(set) var isSent = false
    /// Webmail URL for the view to open through `@Environment(\.openURL)`.
    /// Never route this into a WKWebView: it shares no session and would put
    /// an account-password field inside this app.
    private(set) var webmailHandoffURL: URL?

    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    /// `debounceInterval` is injectable so tests don't sleep.
    init(
        sendEmail: SendEmailUseCase,
        contacts: ContactsViewModel,
        pgp: PgpSendService,
        draft: ComposeDraft? = nil,
        debounceInterval: Duration = .milliseconds(150)
    ) {
        self.sendEmail = sendEmail
        self.contacts = contacts
        self.pgp = pgp
        self.debounceInterval = debounceInterval
        if let draft {
            to = tokens(from: draft.to)
            cc = tokens(from: draft.cc)
            bcc = tokens(from: draft.bcc)
            subject = draft.subject
            body = AttributedString(draft.body)
        }
    }

    // MARK: - Contacts

    /// The book both the dropdown and the address book search.
    var contactIndex: ContactSearchIndex { contacts.searchIndex }

    /// iOS loads contacts only when the Contacts tab is opened, so compose
    /// asks for them itself.
    func loadContactsIfNeeded() async {
        await contacts.loadIfNeeded()
    }

    // MARK: - PGP

    /// Nil means "not known yet": compose offers no PGP controls rather than
    /// one that might lie.
    var pgpCustody: PgpKeyCustody? { pgp.custody }

    /// Which PGP controls this compose window may offer.
    ///
    /// Re-derived on every read rather than stored: enrollment can change
    /// while the app runs, and a value captured when the window opened would
    /// keep offering an on-device send after the key was wiped.
    var pgpComposeControls: PgpComposeState {
        pgp.composeState(deviceEnrolled: SingletonGraph.shared.enrollmentVault.isEnrolled)
    }

    /// On the client-side path the two chips are one decision: the relay
    /// accepts `multipart/encrypted` only, so sign-only cannot be expressed.
    var pgpChipsAreCoupled: Bool { pgpComposeControls.clientSide }

    func loadPgpIdentityIfNeeded() async {
        await pgp.loadIfNeeded()
    }

    /// Inline, non-blocking warning text, worded as "no key on file" — never as
    /// a promise that a plaintext link will be sent, because the send path's
    /// discovery ladder may still find a key.
    var keylessWarningText: String? {
        guard !keylessWarning.isEmpty else { return nil }
        let names = keylessWarning.joined(separator: ", ")
        return "We don't have a PGP key on file for \(names). We'll still look one up when sending."
    }

    /// Verbatim from Client_Encrypted_Send.md — the wording carries the
    /// security property. Names every address; never "some recipients".
    ///
    /// Takes the pickup rather than reading the optional property: the copy is
    /// only ever correct when there are addresses to name, and `conflictError`
    /// only builds a refusal from a non-empty list, so there is no such thing
    /// as a keyless confirmation with nobody in it.
    func pickupConfirmationMessage(for pickup: PendingPickup) -> String {
        let names = pickup.addresses.joined(separator: ", ")
        return """
        We don't have a PGP key for \(names). They'll get an email with a one-time link instead.

        To make that work, this message's contents are stored on your KyPost server — unencrypted — for up to 7 days or until the link is opened. Everyone else on this message still gets it encrypted.
        """
    }

    /// Confirmed the one-time-link fallback: re-sends the refused request,
    /// byte-identical apart from the flag. No preflight, no rebuild.
    ///
    /// Takes `pickup` rather than reading `self.pendingPickup`: the view hands
    /// this in from the confirmation dialog's `presenting:` data, captured at
    /// the moment the button was tapped. Reading the property instead would
    /// race the dialog's own dismissal — SwiftUI clears `isPresented` (and
    /// this class clears `pendingPickup` through that binding's setter)
    /// synchronously, before this `Task { }`-wrapped action body ever runs.
    func confirmPickupFallback(_ pickup: PendingPickup) async {
        guard !isSending, !isSent, !didSend else { return }
        // Claimed here rather than in `deliver`, so nothing can slip between
        // the guard above and the in-flight state (see `send`).
        isSending = true
        defer { isSending = false }
        // A fresh attempt starts with a clean slate: an earlier notice or
        // keyless-address list must not linger over whatever this one produces.
        noticeMessage = nil
        keylessWarning = []
        var email = pickup.email
        pendingPickup = nil
        email.allowPickupFallback = true
        await deliver(email)
    }

    func cancelPickupFallback() {
        pendingPickup = nil
        keylessWarning = []
    }

    /// Client-custody account: the key exists only in the user's browser, so
    /// save the composed message as a server-side draft and send them there.
    func handOffToWebmail(fontTraits: @escaping RichTextHTML.FontTraits) async {
        guard !isSending, !isSent, !didSend else { return }
        // A fresh attempt starts with a clean slate: an earlier notice or
        // keyless-address list must not linger over whatever this one produces.
        noticeMessage = nil
        keylessWarning = []
        for field in RecipientField.allCases where !commitPendingInput(for: field) {
            return
        }
        // Entry points own this flag; `handOff` and `deliver` don't, so a
        // nested defer can't clear it early when `deliver` hands off. Claimed
        // before the first `await` below — otherwise a double-tap slips
        // through the guard above and saves two drafts.
        isSending = true
        defer { isSending = false }
        await handOff(draft: outgoingEmail(fontTraits: fontTraits))
    }

    /// Called by the view once it has opened `webmailHandoffURL`, so a redraw
    /// can't reopen the browser.
    func didOpenWebmail() {
        webmailHandoffURL = nil
    }

    // MARK: - Recipients

    subscript(field: RecipientField) -> [RecipientToken] {
        get {
            switch field {
            case .to: to
            case .cc: cc
            case .bcc: bcc
            }
        }
        set {
            switch field {
            case .to: to = newValue
            case .cc: cc = newValue
            case .bcc: bcc = newValue
            }
        }
    }

    subscript(input field: RecipientField) -> String {
        get {
            switch field {
            case .to: toInput
            case .cc: ccInput
            case .bcc: bccInput
            }
        }
        set {
            switch field {
            case .to: toInput = newValue
            case .cc: ccInput = newValue
            case .bcc: bccInput = newValue
            }
        }
    }

    /// Adds `token` unless that address is already a recipient anywhere.
    ///
    /// Duplicates are checked across all three fields, not just the target:
    /// the same person in both To and Cc is always a mistake, and it's what
    /// the spec asks for.
    @discardableResult
    func add(_ token: RecipientToken, to field: RecipientField) -> Bool {
        guard !isRecipient(token.address) else {
            showToast("\(token.label) is already a recipient")
            return false
        }
        self[field].append(token)
        errorMessage = nil
        return true
    }

    func remove(_ token: RecipientToken, from field: RecipientField) {
        self[field].removeAll { $0.id == token.id }
    }

    func isRecipient(_ address: String) -> Bool {
        let key = address.lowercased()
        return RecipientField.allCases.contains { field in
            self[field].contains { $0.comparisonKey == key }
        }
    }

    /// Turns whatever is uncommitted in `field` into a token. Called on
    /// Return, on a separator keystroke, on blur, and from `send()`.
    ///
    /// `reportingErrors` is false on blur: half-typed text is usually a
    /// search in progress, and clicking to another field shouldn't scold
    /// anyone. The text stays put and send() complains if it's still bad.
    @discardableResult
    func commitPendingInput(for field: RecipientField, reportingErrors: Bool = true) -> Bool {
        let text = self[input: field].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        func reject(_ address: String) -> Bool {
            if reportingErrors {
                errorMessage = "\(address) isn't a valid email address"
            }
            return false
        }

        let parsed = EmailAddress.parse(text)
        // No "@" anywhere means this isn't an attempt at an address at all.
        guard !parsed.isEmpty else { return reject(text) }
        guard parsed.allSatisfy({ EmailAddress.isValid($0.address) }) else {
            return reject(parsed.first { !EmailAddress.isValid($0.address) }?.address ?? text)
        }
        for entry in parsed {
            add(resolve(address: entry.address, name: entry.name), to: field)
        }
        self[input: field] = ""
        closeSuggestions()
        return true
    }

    func selectSuggestion(_ match: ContactMatch, for field: RecipientField) {
        add(
            RecipientToken(
                address: match.entry.address,
                displayName: match.entry.displayName,
                contactId: match.entry.contact.localId
            ),
            to: field
        )
        self[input: field] = ""
        closeSuggestions()
    }

    // MARK: - Suggestions

    /// Debounced so fast typing doesn't re-rank on every keystroke or flicker
    /// the dropdown through intermediate states.
    func updateSuggestions(for field: RecipientField) {
        searchTask?.cancel()
        let query = self[input: field]
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            closeSuggestions()
            return
        }
        searchTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            suggestions = ContactSearch.matches(
                query,
                in: contacts.searchIndex,
                options: .autocomplete
            )
            suggestionsField = field
        }
    }

    func closeSuggestions() {
        searchTask?.cancel()
        searchTask = nil
        suggestions = []
        suggestionsField = nil
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    // MARK: - Draft parsing

    private func tokens(from header: String) -> [RecipientToken] {
        let parsed = EmailAddress.parse(header)
        guard parsed.isEmpty else {
            return parsed.map { resolve(address: $0.address, name: $0.name) }
        }
        // Nothing address-shaped in there, but the draft still means it as a
        // recipient — ComposeDraft.reply falls back to the sender's *name*
        // when an email has no sender address. Keep it visible as a token and
        // let send() reject it, rather than emptying the field silently.
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [RecipientToken(address: trimmed)]
    }

    /// Looks `address` up in the address book so a reply shows "Alice Chen"
    /// rather than a bare address. Falls back to whatever name came with it.
    private func resolve(address: String, name: String? = nil) -> RecipientToken {
        let key = address.lowercased()
        let entry = contacts.searchIndex.entries.first { $0.address.lowercased() == key }
        return RecipientToken(
            address: address,
            displayName: entry?.displayName ?? name,
            contactId: entry?.contact.localId
        )
    }

    var attachmentTotalBytes: Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }

    /// Loads a picked/dropped file into the draft, enforcing the same 25 MB
    /// total budget the backend applies. fileImporter URLs are
    /// security-scoped; access is claimed around the read.
    func addAttachment(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            guard attachmentTotalBytes + data.count <= SendEmailUseCase.maxAttachmentBytes else {
                errorMessage = "Attachments too large (max 25 MB total)"
                return
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            attachments.append(ComposeAttachment(
                name: url.lastPathComponent,
                mimeType: mimeType,
                data: data
            ))
            errorMessage = nil
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeAttachment(_ attachment: ComposeAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Sends the draft. `fontTraits` resolves bold/italic on body runs (from
    /// the view's font resolution context) so formatted text goes out as HTML.
    func send(fontTraits: @escaping RichTextHTML.FontTraits) async {
        // `didSend` as well as `isSent`: the window dismisses on `didSend`
        // through an onChange, and a second ⌘↩ in that gap would post the
        // message twice.
        guard !isSending, !isSent, !didSend else { return }
        // Claimed here, not in `deliver`: the recipient preflight below is an
        // `await` on a network round-trip, and a guard that only closes after
        // it leaves a window in which a second ⌘↩ passes the check above and
        // posts the message a second time.
        isSending = true
        defer { isSending = false }
        // A fresh attempt starts with a clean slate: an earlier notice must not
        // linger over whatever this one produces. `keylessWarning` is cleared
        // here too so a rejected recipient below doesn't leave a stale address
        // list on screen next to the fresh error — it is reassigned again
        // once validation passes.
        noticeMessage = nil
        keylessWarning = []
        // A recipient typed but not committed is still a recipient the user
        // means to mail. Bail on invalid text rather than dropping it.
        for field in RecipientField.allCases where !commitPendingInput(for: field) {
            return
        }
        let email = outgoingEmail(fontTraits: fontTraits)

        // The client-custody path encrypts here and posts to /api/mail/send-pgp.
        // Checked before the preflight below, which asks the server whether it
        // has keys — a question this path answers itself, with /resolve.
        if pgpComposeControls.clientSide, encrypt {
            await deliverClientEncrypted(email)
            return
        }

        // Reassigned either way, so turning Encrypt off clears a warning left
        // by an earlier encrypted attempt.
        keylessWarning = encrypt
            ? await pgp.keylessRecipients(among: email.to + email.cc + email.bcc)
            : []
        await deliver(email)
    }

    /// Builds the request once. `send` and the pickup re-send share the same
    /// value: rebuilding risks a subtly different message.
    private func outgoingEmail(
        fontTraits: @escaping RichTextHTML.FontTraits
    ) -> OutgoingEmail {
        let isHTML = RichTextHTML.hasFormatting(body, fontTraits: fontTraits)
        return OutgoingEmail(
            to: to.map(\.address),
            cc: cc.map(\.address),
            bcc: bcc.map(\.address),
            subject: subject,
            body: isHTML
                ? RichTextHTML.htmlDocument(from: body, fontTraits: fontTraits)
                : String(body.characters),
            mode: isHTML ? "html" : "plain",
            attachments: attachments.map {
                OutgoingAttachment(name: $0.name, mimeType: $0.mimeType, data: $0.data)
            },
            encrypt: encrypt,
            sign: sign
        )
    }

    /// Like `handOff`, this deliberately doesn't own `isSending`: its callers
    /// claim it before their first `await` so no suspension point sits between
    /// their guard and the claim. A nested defer here would clear the flag
    /// early on the `clientSideNeeded` path, which hands off through `handOff`.
    private func deliver(_ email: OutgoingEmail) async {
        // This attempt's outcome is the only one that counts: an earlier
        // refusal must not outlive it and keep a stale dialog answerable.
        pendingPickup = nil

        switch await sendEmail(email) {
        case .success:
            didSend = true
            errorMessage = nil
        case .sentWithWarning(let warning):
            // Sent. Keep the window open so the notice is readable, and leave
            // Send disabled: a retry would duplicate the message.
            isSent = true
            errorMessage = nil
            noticeMessage = warning
        case .keylessRecipients(let addresses, let pickupFallbackAvailable):
            guard pickupFallbackAvailable else {
                errorMessage = """
                No usable PGP key for \(addresses.joined(separator: ", ")), and this server \
                doesn't offer one-time links. Remove them, or turn Encrypt off to send in the clear.
                """
                return
            }
            pendingPickup = PendingPickup(addresses: addresses, email: email)
            errorMessage = nil
        case .clientSideNeeded:
            // The account's key is held only by the browser. Nothing this
            // client retries can fix it, so hand off.
            await handOff(draft: email)
        case .invalid(let message):
            errorMessage = message
        case .unauthorized:
            errorMessage = "Not authorized — re-pair the device or check credentials."
        case .notPaired:
            errorMessage = "Pair this device before sending."
        case .rateLimited(let retryAfter):
            errorMessage = retryAfter.map {
                "Too many attempts — try again in \(NetworkError.formatRetryAfter($0))."
            } ?? "Too many attempts — try again later."
        case .notConfigured:
            errorMessage = "Set up your mail account in the web app first."
        case .upstreamFailure(let message):
            errorMessage = message
        case .failure(let message):
            errorMessage = message
        }
    }

    /// Encrypts on this device and posts the ciphertext to the relay.
    ///
    /// Like `deliver`, this does not own `isSending`: the caller claims it
    /// before its first `await`.
    private func deliverClientEncrypted(_ email: OutgoingEmail) async {
        pendingPickup = nil

        guard let sender = SingletonGraph.shared.makeClientEncryptedSender(
            accountAddress: pgp.accountAddress
        ) else {
            errorMessage = "Pair this device before sending."
            return
        }

        let draft = ClientSendDraft(
            to: email.to.joined(separator: ", "),
            cc: email.cc.joined(separator: ", "),
            bcc: email.bcc.joined(separator: ", "),
            subject: email.subject,
            body: email.body,
            mode: email.mode,
            attachments: email.attachments.map {
                OutgoingMimeAttachment(
                    name: $0.name,
                    mimeType: $0.mimeType,
                    dataBase64: $0.data.base64EncodedString()
                )
            }
        )

        switch await sender.send(draft: draft) {
        case .sent(_, let warning):
            errorMessage = nil
            if warning.isEmpty {
                didSend = true
            } else {
                // Sent. Keep the window open so the notice is readable, and
                // leave Send disabled — a retry would duplicate the message.
                isSent = true
                noticeMessage = warning
            }
        // Not an error: the user dismissed a prompt they raised, so the screen
        // goes back to offering Send with nothing said.
        case .cancelled:
            errorMessage = nil
        case .notEnrolled:
            errorMessage = "This device is no longer set up to encrypt. Enroll it again in Settings."
        case .noSecureLockScreen:
            errorMessage = "This device has no passcode or biometric lock, so it can't hold your key."
        case .unsealFailed(let message):
            errorMessage = "Couldn't unlock this device's key: \(message)"
        case .notClientProtected:
            errorMessage = "This account isn't set up for on-device encryption."
        case .noAccountAddress:
            errorMessage = "No mail address is configured for this account, so this message can't be sent from here."
        // Louder than a missing key, and deliberately never folded into it: a
        // pin that no longer matches is what a rotation looks like, and also
        // what interception looks like.
        case .keyChanged(let addresses):
            keylessWarning = addresses
            errorMessage = """
            The key on file for \(addresses.joined(separator: ", ")) has changed. Confirm the new \
            fingerprint with them before sending.
            """
        case .recipientKeyRevoked(let addresses):
            keylessWarning = addresses
            errorMessage = """
            The key you verified for \(addresses.joined(separator: ", ")) has been revoked by its \
            owner. Verify their new key by QR before sending.
            """
        // No pickup fallback here, and there must not be: the server-side one
        // works by storing the plaintext this path exists to avoid.
        case .keysMissing(let addresses):
            keylessWarning = addresses
            errorMessage = """
            No usable key for \(addresses.joined(separator: ", ")). This account encrypts on your \
            device, so there's no way to send to them without one.
            """
        case .tooManyRecipients(let message):
            errorMessage = "Too many recipients: \(message)"
        case .resolveFailed(let message):
            errorMessage = "Couldn't look up recipient keys: \(message)"
        case .encryptFailed(let message):
            errorMessage = "Couldn't encrypt this message: \(message)"
        case .sendFailed(let message):
            errorMessage = "Couldn't send this message: \(message)"
        // Both converted-account refusals mean the keys on this device are no
        // longer the account's current ones; each says why, and both name the
        // only remedy. Not retryable as-is.
        case .reenrollmentRequired:
            errorMessage = "This device holds older encryption keys. Set up encryption on this device again in Settings, then send."
        case .pgpStateChanged:
            errorMessage = "Your account's encryption keys changed since this device was set up. Set up encryption on this device again in Settings, then send."
        }
    }

    /// Saves the message as a server-side draft and points the view at
    /// webmail's Drafts view, where the browser holds the key.
    private func handOff(draft: OutgoingEmail) async {
        var draft = draft
        // A draft has no PGP semantics; RelaySendRequest drops the flags, but
        // keep the value honest for anything that inspects it later.
        draft.encrypt = false
        draft.sign = false
        draft.allowPickupFallback = false

        switch await sendEmail.saveDraft(draft) {
        case .success, .sentWithWarning:
            isSent = true
            errorMessage = nil
            guard let url = sendEmail.webmailDraftsURL else {
                noticeMessage = """
                This account's PGP key is held only by your browser, so it has to sign and \
                encrypt there. We saved this message to Drafts — couldn't work out this \
                server's web address, so open Drafts in your browser to finish sending it.
                """
                return
            }
            noticeMessage = """
            This account's PGP key is held only by your browser, so it has to sign and encrypt \
            there. We saved this message to Drafts and opened webmail to finish sending it.
            """
            webmailHandoffURL = url
        case .unauthorized:
            errorMessage = "Not authorized — re-pair the device or check credentials."
        case .notPaired:
            errorMessage = "Pair this device before sending."
        case .invalid(let message), .failure(let message),
             .notConfigured(let message), .upstreamFailure(let message):
            errorMessage = "Couldn't save this as a draft: \(message)"
        case .rateLimited:
            errorMessage = "Couldn't save this as a draft — too many attempts. Try again shortly."
        case .clientSideNeeded, .keylessRecipients:
            // A draft carries no PGP flags, so neither refusal is reachable.
            errorMessage = "Couldn't save this as a draft."
        }
    }
}

// MARK: - Reply / Reply All / Forward drafts

/// Prefilled compose state built from an existing email. Codable + Hashable
/// so macOS can pass it as a "compose" WindowGroup value; Identifiable so
/// iOS can present it with sheet(item:).
struct ComposeDraft: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""

    init(
        id: UUID = UUID(),
        to: String = "",
        cc: String = "",
        bcc: String = "",
        subject: String = "",
        body: String = ""
    ) {
        self.id = id
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Hand-written because synthesized Decodable doesn't fall back to
    /// property defaults for absent keys: a scene value archived by a build
    /// without `bcc` would throw here and the restored window would come up
    /// blank. Every key is optional for the same reason.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        to = try container.decodeIfPresent(String.self, forKey: .to) ?? ""
        cc = try container.decodeIfPresent(String.self, forKey: .cc) ?? ""
        bcc = try container.decodeIfPresent(String.self, forKey: .bcc) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }

    static func reply(to email: Email) -> ComposeDraft {
        ComposeDraft(
            to: email.senderEmail.isEmpty ? email.senderName : email.senderEmail,
            subject: prefixed("Re:", email.subject),
            body: quotedBody(of: email)
        )
    }

    /// Reply to the sender, Cc'ing everyone else on the original To/Cc —
    /// minus the sender (already in To) and our own address (`ownAddress`,
    /// the pairing's sub).
    static func replyAll(to email: Email, ownAddress: String?) -> ComposeDraft {
        var draft = reply(to: email)
        var excluded = [email.senderEmail.lowercased()]
        if let ownAddress { excluded.append(ownAddress.lowercased()) }
        var seen = Set<String>()
        let others = (addresses(in: email.sentTo) + addresses(in: email.cc)).filter {
            !excluded.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted
        }
        draft.cc = others.joined(separator: ", ")
        return draft
    }

    static func forward(_ email: Email) -> ComposeDraft {
        let sender = email.senderName == email.senderEmail || email.senderName.isEmpty
            ? email.senderEmail
            : "\(email.senderName) <\(email.senderEmail)>"
        var header = """
        ---------- Forwarded message ----------
        From: \(sender)
        Date: \(email.receivedAt.formatted(date: .abbreviated, time: .shortened))
        Subject: \(email.subject)
        """
        if !email.sentTo.isEmpty {
            header += "\nTo: \(email.sentTo)"
        }
        return ComposeDraft(
            subject: prefixed("Fwd:", email.subject),
            body: "\n\n\(header)\n\n\(plainText(email.body))"
        )
    }

    // MARK: - Helpers

    /// "Re:"/"Fwd:" prefix, skipped when the subject already carries it.
    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return trimmed
        }
        return trimmed.isEmpty ? prefix : "\(prefix) \(trimmed)"
    }

    /// "On {date}, {sender} wrote:" attribution plus the original body,
    /// each line "> "-quoted, after two blank lines for the reply text.
    private static func quotedBody(of email: Email) -> String {
        let sender = email.senderName.isEmpty ? email.senderEmail : email.senderName
        let date = email.receivedAt.formatted(date: .abbreviated, time: .shortened)
        let quoted = plainText(email.body)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\nOn \(date), \(sender) wrote:\n\(quoted)"
    }

    /// Bare addresses from a comma-joined header string whose entries may be
    /// "Name <addr>" or bare addresses.
    private static func addresses(in header: String) -> [String] {
        EmailAddress.parse(header).map(\.address)
    }

    /// Reduces an HTML body to quotable plain text (the compose editor is
    /// text, not a web view): tags stripped, block ends → newlines, common
    /// entities decoded. Plain bodies pass through untouched.
    static func plainText(_ body: String) -> String {
        guard body.range(of: "<[a-zA-Z!/]", options: .regularExpression) != nil else {
            return body
        }
        var text = body
        for pattern in ["(?is)<(style|script|head)\\b.*?</\\1>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)<br\\b[^>]*>|</(p|div|tr|li|h[1-6]|blockquote|table)>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // Collapse the newline runs left behind by nested block markup.
        text = text.replacingOccurrences(
            of: "\\n[ \\t]*(\\n[ \\t]*)+",
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
