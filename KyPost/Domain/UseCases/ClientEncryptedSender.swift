//
//  ClientEncryptedSender.swift
//  KyPost
//
//  Encrypts and signs one message on this device, then hands the ciphertext to
//  the relay. Swift port of kypost-android's pgp/ClientEncryptedSender.kt.
//
//  **No platform imports**, following EncryptedMessageReader — which is what
//  lets the whole exit table be an ordinary unit test with fakes.
//
//  Nothing here decides whether the account *may* use this path;
//  `pgpComposeState` does that. This runs only once that decision is made.
//

import Foundation

/// Discovery found a key whose fingerprint does not match the one pinned to
/// that contact.
nonisolated let pgpTierKeyChanged = "key_changed"

/// One resolved recipient key.
nonisolated struct ResolvedRecipientKey: Equatable, Sendable {
    var address: String
    var publicKey: String = ""
    var usable: Bool = false
    var tier: String = ""
}

/// How a recipient-key lookup ended.
nonisolated enum ResolveResult: Equatable, Sendable {
    case success([ResolvedRecipientKey])
    /// 409 — this account is not client-protected, so this is the wrong send
    /// path entirely.
    case notClientProtected
    /// 413 — more recipients than the server will resolve at once.
    case tooMany(String)
    case failed(String)
}

/// Recipient key lookup, behind a protocol so this orchestrator takes no
/// dependency on URLSession or pairing credentials.
protocol RecipientKeyResolving: Sendable {
    func resolve(addresses: [String]) async -> ResolveResult
}

/// One delivery: a set of recipients and the ciphertext addressed to them.
nonisolated struct ClientEncryptedDelivery: Equatable, Sendable {
    var recipients: [String]
    var ciphertext: String
}

nonisolated struct ClientEncryptedMessage: Equatable, Sendable {
    var from: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var deliveries: [ClientEncryptedDelivery]
    var sentCopy: String
    var mode: String
    /// The held keyring's generation; nil for legacy armor. A converted
    /// account refuses a send that does not name its current generation
    /// (KyPost-Server #210), and a legacy account must never see a made-up one.
    var materialGeneration: UInt64? = nil
}

nonisolated struct ClientSendResult: Equatable, Sendable {
    var sentSaved: Bool = false
    var warning: String = ""
}

/// The relay hop.
protocol ClientEncryptedTransport: Sendable {
    func send(_ message: ClientEncryptedMessage) async -> Result<ClientSendResult, MailSendFailure>
}

/// Carries the relay's refusal without this file depending on how it was
/// spelled.
nonisolated struct MailSendFailure: Equatable, Sendable, Error {
    /// The refusals the sender turns into their own exit-table rows.
    nonisolated enum Kind: Equatable, Sendable {
        case other
        /// 409 `reenrollmentRequired`: this device is not enrolled at the
        /// account's current generation.
        case reenrollmentRequired
        /// 409 `pgpStateChanged`: the account's key material moved since this
        /// device's keys were delivered.
        case pgpStateChanged
    }

    var message: String
    var kind: Kind = .other
}

/// Everything the sender needs from a draft, so this file does not depend on
/// the compose screen's own model.
nonisolated struct ClientSendDraft: Equatable, Sendable {
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    /// "html" or "plain".
    var mode: String = "html"
    var attachments: [OutgoingMimeAttachment] = []
}

/// Every way a client-encrypted send can end — one per row of compose's exit
/// table.
nonisolated enum ClientSendOutcome: Equatable, Sendable {
    case sent(sentSaved: Bool, warning: String)

    /// **Not an error.** The user dismissed a prompt they raised, so the screen
    /// goes back to offering Send.
    case cancelled
    case notEnrolled
    case noSecureLockScreen
    case unsealFailed(String)
    /// The account is not client-protected after all.
    case notClientProtected
    /// No mail account configured, so no valid `From` can be built.
    case noAccountAddress
    /// A pinned key's fingerprint no longer matches what discovery returned.
    /// Deliberately distinct from `keysMissing`, and checked before it.
    case keyChanged([String])
    /// A key this device verified by QR has been revoked by its owner. The
    /// pin stays the address's pin — no fallback to the relay's key — so the
    /// send stops until the user verifies the new key in person.
    case recipientKeyRevoked([String])
    case keysMissing([String])
    case tooManyRecipients(String)
    case resolveFailed(String)
    case encryptFailed(String)
    case sendFailed(String)
    /// The relay refused: this device holds key material from before the
    /// account's current generation. Set up encryption on this device again.
    case reenrollmentRequired
    /// The relay refused: the account's keys changed after this device's were
    /// delivered. Set up encryption on this device again.
    case pgpStateChanged
}

nonisolated struct ClientEncryptedSender: Sendable {
    private let opener: any VaultOpening
    private let resolver: any RecipientKeyResolving
    private let transport: any ClientEncryptedTransport
    private let crypto: any PgpEncrypting
    /// Keys verified on this device. Not defaulted, like the reader's.
    private let pins: RecipientPinSnapshot
    private let session: EnrollmentSession
    /// The address every delivery's `From` must carry, from bootstrap's
    /// `suggestedUserIDs[0]`. The relay compares each delivery's own header
    /// against it and answers 403 on a mismatch.
    private let accountAddress: String
    private let now: @Sendable () -> Date
    private let boundaryToken: @Sendable () -> String

    init(
        opener: any VaultOpening,
        resolver: any RecipientKeyResolving,
        transport: any ClientEncryptedTransport,
        crypto: any PgpEncrypting,
        pins: RecipientPinSnapshot,
        accountAddress: String,
        session: EnrollmentSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        boundaryToken: @escaping @Sendable () -> String = PgpMimeWriter.randomBoundaryToken
    ) {
        self.opener = opener
        self.resolver = resolver
        self.transport = transport
        self.crypto = crypto
        self.pins = pins
        self.accountAddress = accountAddress
        self.session = session
        self.now = now
        self.boundaryToken = boundaryToken
    }

    /// Encrypt-and-sign, always both.
    ///
    /// There is no `sign` flag because this path cannot honour one: the relay
    /// accepts `multipart/encrypted` only, so sign-only is impossible, and
    /// `pgpComposeState` couples the two chips whenever `clientSide` is set.
    /// A parameter that silently did nothing would be worse than its absence.
    func send(draft: ClientSendDraft) async -> ClientSendOutcome {
        let from = accountAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else { return .noAccountAddress }

        let fields = splitRecipientFields(to: draft.to, cc: draft.cc, bcc: draft.bcc)
        let addresses = fields.all

        // Resolve **before** unlocking. A send that was going to be refused
        // anyway must not interrupt the user for a biometric they gain nothing
        // from. (The web client prompts first; this is a deliberate
        // divergence, not an oversight.)
        let resolved: [ResolvedRecipientKey]
        switch await resolver.resolve(addresses: addresses) {
        case .success(let results): resolved = results
        case .notClientProtected: return .notClientProtected
        case .tooMany(let message): return .tooManyRecipients(message)
        case .failed(let message): return .resolveFailed(message)
        }
        var byAddress = Dictionary(
            resolved.map { ($0.address.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // A broken pin outranks a missing key, and is checked first.
        // `key_changed` means discovery found a key whose fingerprint does not
        // match the pinned one — which is what a rotation looks like, and also
        // what interception looks like. Folding it into "no key on file" tells
        // the user nothing changed at the exact moment the one thing worth
        // telling them did.
        let changed = addresses.filter { byAddress[$0.lowercased()]?.tier == pgpTierKeyChanged }
        guard changed.isEmpty else { return .keyChanged(changed) }

        // A key verified on this device outranks the relay, and all of this
        // runs before the vault opens.
        switch Self.applyPins(pins, addresses: addresses, resolved: &byAddress) {
        case .proceed: break
        case .revoked(let revoked): return .recipientKeyRevoked(revoked)
        case .changed(let mismatched): return .keyChanged(mismatched)
        }

        let missing = addresses.filter { address in
            guard let key = byAddress[address.lowercased()] else { return true }
            return !key.usable || key.publicKey.isEmpty
        }
        // There is no pickup fallback on this path and there must not be: the
        // server-side one works by storing the plaintext, which is the very
        // thing client-side protection exists to prevent.
        guard missing.isEmpty else { return .keysMissing(missing) }

        if !session.isHeld {
            switch await opener.open() {
            case .opened(let material):
                session.install(material)
            case .cancelled: return .cancelled
            case .notEnrolled: return .notEnrolled
            case .noSecureLockScreen: return .noSecureLockScreen
            case .failed(let message): return .unsealFailed(message)
            }
        }

        // Built once and shared by every delivery and the Sent copy, so no
        // recipient can receive a subtly different message from another.
        let contentType = draft.mode.lowercased() == "plain" ? "text/plain" : "text/html"
        let protectedContent = Data(PgpMimeWriter.buildProtectedContent(
            contentType: "\(contentType); charset=utf-8",
            body: draft.body,
            subject: draft.subject,
            attachments: draft.attachments,
            boundaryToken: boundaryToken
        ).utf8)

        let date = PgpMimeWriter.rfc5322Date(now())
        let envelope = OutgoingEnvelope(from: from, to: fields.to, cc: fields.cc, date: date)

        // To and CC share one ciphertext; each BCC gets their own, so no BCC
        // recipient's key id appears in a packet another recipient can read.
        var groups: [[String]] = []
        let shared = fields.to + fields.cc
        if !shared.isEmpty { groups.append(shared) }
        groups.append(contentsOf: fields.bcc.map { [$0] })

        // Re-read per use rather than trusting the branch above: the app can
        // lock between the unseal and here, and every lock boundary clears
        // this holder.
        //
        // The message is built entirely inside `withKey`, which holds a lock
        // and so cannot await. The relay hop happens after, outside it — a
        // network round trip is not something to hold a lock across, and the
        // key is not needed for it.
        // A local two-case result rather than `Result`, whose failure type
        // must be an Error — and an exit-table row is not an error.
        enum Prepared {
            case ready(ClientEncryptedMessage)
            case stop(ClientSendOutcome)
        }

        // Signing and the Sent copy use the explicit active key only; a
        // retired key is never a fallback. The generation rides on the
        // message so the relay can refuse a send prepared under stale keys.
        let prepared: Prepared = session.withMaterial { material in
            guard let material else { return .stop(.notEnrolled) }
            let privateKey = material.signingKey

            var deliveries: [ClientEncryptedDelivery] = []
            for recipients in groups {
                let keys = recipients.compactMap { byAddress[$0.lowercased()]?.publicKey }
                do {
                    let armored = try crypto.encryptAndSign(
                        plaintext: protectedContent,
                        recipientKeys: keys,
                        privateKey: privateKey
                    )
                    deliveries.append(ClientEncryptedDelivery(
                        recipients: recipients,
                        ciphertext: PgpMimeWriter.wrapAsPgpMime(
                            envelope: envelope,
                            armoredMessage: armored,
                            boundaryToken: boundaryToken
                        )
                    ))
                } catch {
                    return .stop(.encryptFailed(Self.message(for: error)))
                }
            }

            // Encrypted to the public half of the key just unsealed, never to
            // anything the server supplied. A hostile server handing back
            // "your" public key would otherwise get a readable copy of every
            // message sent, with nothing on screen looking any different.
            do {
                let ownKey = try crypto.ownPublicKey(privateKey: privateKey)
                let sentCopy = PgpMimeWriter.wrapAsPgpMime(
                    envelope: envelope,
                    armoredMessage: try crypto.encryptAndSign(
                        plaintext: protectedContent,
                        recipientKeys: [ownKey],
                        privateKey: privateKey
                    ),
                    boundaryToken: boundaryToken
                )
                return .ready(ClientEncryptedMessage(
                    from: from,
                    to: fields.to,
                    cc: fields.cc,
                    bcc: fields.bcc,
                    deliveries: deliveries,
                    sentCopy: sentCopy,
                    mode: draft.mode.isEmpty ? "html" : draft.mode,
                    materialGeneration: material.materialGeneration
                ))
            } catch {
                return .stop(.encryptFailed(Self.message(for: error)))
            }
        }

        let message: ClientEncryptedMessage
        switch prepared {
        case .ready(let built): message = built
        case .stop(let outcome): return outcome
        }

        switch await transport.send(message) {
        case .success(let result):
            return .sent(sentSaved: result.sentSaved, warning: result.warning)
        case .failure(let failure):
            switch failure.kind {
            case .reenrollmentRequired: return .reenrollmentRequired
            case .pgpStateChanged: return .pgpStateChanged
            case .other: return .sendFailed(failure.message)
            }
        }
    }

    enum PinCheck: Equatable {
        case proceed
        case revoked([String])
        case changed([String])
    }

    /// The write-path counterpart of `EncryptedMessageReader.signerKeys`.
    /// For each recipient pinned on this device: a revoked pin refuses the
    /// send; a broken pin, or a relay key that fingerprints differently from
    /// the pin (computed from the bytes, never the relay's fingerprint field),
    /// is a key change; a match encrypts to the **pinned** bytes. An address
    /// the relay had no usable key for is left to the missing-key check.
    static func applyPins(
        _ pins: RecipientPinSnapshot,
        addresses: [String],
        resolved: inout [String: ResolvedRecipientKey]
    ) -> PinCheck {
        var revoked: [String] = []
        var changed: [String] = []
        for address in addresses {
            let key = address.lowercased()
            switch pins.state(for: address) {
            case nil:
                continue
            case .revoked:
                revoked.append(address)
            case .broken:
                changed.append(address)
            case .intact(let publicKey, let fingerprint):
                guard var entry = resolved[key], entry.usable, !entry.publicKey.isEmpty else { continue }
                guard PgpFingerprint.compute(fromArmored: entry.publicKey) == fingerprint else {
                    changed.append(address)
                    continue
                }
                entry.publicKey = publicKey
                resolved[key] = entry
            }
        }
        if !revoked.isEmpty { return .revoked(revoked) }
        if !changed.isEmpty { return .changed(changed) }
        return .proceed
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PgpCryptoError.unusableKey:
            "the key on this device could not be read"
        case let PgpCryptoError.cannotEncrypt(detail):
            detail
        default:
            "this message could not be encrypted"
        }
    }
}
