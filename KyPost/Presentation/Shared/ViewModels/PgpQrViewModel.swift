//
//  PgpQrViewModel.swift
//  KyPost
//
//  The two halves of in-person PGP key exchange (Client_PGP_Update.md):
//  showing your own key as a QR code, and scanning someone else's onto a
//  contact.
//
//  Both map NetworkError → state here rather than in PgpQrClient, because the
//  mapping is only unambiguous once you know which endpoint you called: the
//  shared NetworkError collapses 401/403 into .unauthorized. On /token that
//  can only have been a 401 (it is pairing-authenticated); on /key it can only
//  have been a 403 (it has no auth to reject). See PgpQrClient's header.
//

import Foundation
import Observation

// MARK: - My QR Code

@Observable
@MainActor
final class MyPgpQrViewModel {
    enum State: Equatable {
        /// No relay pairing — nothing to authenticate the mint call with.
        case needsPairing
        case loading
        case showing(urlString: String, expiresAt: Date)
        /// 400 — this account has no PGP identity configured yet.
        case noPgpIdentity
        /// 401 — the server rejected this device's pairing credentials.
        case pairingRejected
        /// 503 — server-side config gap. Static: never auto-retried.
        case unavailable
        case failed(String)
    }

    /// The fingerprint shown beside the code, and where it came from.
    enum OwnFingerprint: Equatable {
        /// Computed from this device's own key; the code carries it as `#fp=`.
        case thisDevice(String)
        /// The server's word only; the code carries no `#fp=`.
        case serverReported(String)
    }

    /// Refresh this long before expiry, so a code on screen is always
    /// scannable rather than expiring in someone's camera.
    private static let refreshLeadTime: TimeInterval = 10

    private let client: PgpQrClient
    private let pairingStore: SecurePairingStore
    private let bootstrapClient: PgpSendClient
    private let session: EnrollmentSession
    private let crypto: any PgpEncrypting
    private let opener: any VaultOpening
    private let deviceIsEnrolled: () -> Bool

    private(set) var state: State = .loading
    private(set) var fingerprint: OwnFingerprint?
    /// Enrolled, but the key is not unlocked: unlocking lets the code carry
    /// this device's own fingerprint.
    private(set) var canUnlockKey = false
    /// Drives the countdown; updated by `observeExpiry()` while visible.
    private(set) var now = Date()

    init(
        client: PgpQrClient,
        pairingStore: SecurePairingStore,
        bootstrapClient: PgpSendClient,
        session: EnrollmentSession,
        crypto: any PgpEncrypting,
        opener: any VaultOpening,
        deviceIsEnrolled: @escaping () -> Bool
    ) {
        self.client = client
        self.pairingStore = pairingStore
        self.bootstrapClient = bootstrapClient
        self.session = session
        self.crypto = crypto
        self.opener = opener
        self.deviceIsEnrolled = deviceIsEnrolled
    }

    /// Whole seconds until the shown code expires, or nil when none is shown.
    var secondsRemaining: Int? {
        guard case .showing(_, let expiresAt) = state else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    func refresh() async {
        guard let pairing = try? pairingStore.loadPairing() else {
            state = .needsPairing
            return
        }
        state = .loading
        let auth = RelayAuth(pairing: pairing)
        let local = ownFingerprint()
        do {
            let response = try await client.fetchToken(serverUrl: pairing.srv, auth: auth)
            guard let expiresAt = response.expiresAtDate else {
                state = .failed("The server sent an expiry date this app couldn't read.")
                return
            }
            guard let payload = PgpQrClient.qrPayload(pickupURL: response.url, fingerprint: local) else {
                state = .failed("The server sent a code this app couldn't read.")
                return
            }
            if let local {
                fingerprint = .thisDevice(local)
            } else {
                fingerprint = await serverFingerprint(srv: pairing.srv, auth: auth)
                    .map(OwnFingerprint.serverReported)
            }
            canUnlockKey = local == nil && deviceIsEnrolled()
            now = Date()
            state = .showing(urlString: payload, expiresAt: expiresAt)
        } catch NetworkError.unauthorized {
            state = .pairingRejected
        } catch NetworkError.serviceUnavailable {
            state = .unavailable
        } catch NetworkError.badRequest {
            state = .noPgpIdentity
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Opens this device's key (a presence prompt), then re-mints the code
    /// with its fingerprint.
    func unlockKey() async {
        switch await opener.open() {
        case .opened(let material):
            session.install(material)
            await refresh()
        case .cancelled:
            return
        case .notEnrolled:
            canUnlockKey = false
        case .noSecureLockScreen:
            state = .failed("Couldn't unlock this device's key: no device passcode is set.")
        case .failed(let message):
            state = .failed("Couldn't unlock this device's key: \(message).")
        }
    }

    /// The primary fingerprint of the key this device signs with, computed
    /// from the key itself — never from anything the server sent.
    private func ownFingerprint() -> String? {
        session.withKey { key in
            guard let key, let publicKey = try? crypto.ownPublicKey(privateKey: key) else { return nil }
            return PgpFingerprint.compute(fromArmored: publicKey)
        }
    }

    private func serverFingerprint(srv: String, auth: RelayAuth) async -> String? {
        guard let publicKey = try? await bootstrapClient.fetchBootstrap(serverUrl: srv, auth: auth).publicKey
        else { return nil }
        return PgpFingerprint.compute(fromArmored: publicKey)
    }

    /// Ticks the countdown and re-mints shortly before expiry. The view drives
    /// this from `.task`, so it is cancelled when the screen goes away and no
    /// tokens are minted for a code nobody is looking at.
    func observeExpiry() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // Any non-.showing state (error, loading) simply has no countdown
            // to advance — keep waiting rather than exiting, so a refresh the
            // user triggers picks the countdown back up.
            guard case .showing(_, let expiresAt) = state else { continue }
            now = Date()
            if expiresAt.timeIntervalSince(now) <= Self.refreshLeadTime {
                await refresh()
            }
        }
    }
}

// MARK: - Scan to Add Contact Key

@Observable
@MainActor
final class ScanPgpKeyViewModel {
    enum State: Equatable {
        case scanning
        case fetching
        /// Fetched; showing the fingerprint for the two people to compare.
        /// `inPerson` is true only when the code carried the showing device's
        /// own fingerprint and the fetched key matched it.
        case confirming(PgpQrKeyResponse, inPerson: Bool)
        case pickingContact(PgpQrKeyResponse, inPerson: Bool)
        case saved(name: String, inPerson: Bool)
        /// `canRescan` is false for failures rescanning cannot fix (503).
        case failed(message: String, canRescan: Bool)
    }

    private let client: PgpQrClient
    private let repository: ContactSyncRepository

    private(set) var state: State = .scanning
    private(set) var contacts: [Contact] = []
    /// Paste-a-link fallback: the only path on macOS, a backup on iOS.
    var pastedLink = ""

    init(client: PgpQrClient, repository: ContactSyncRepository) {
        self.client = client
        self.repository = repository
    }

    func handleScannedPayload(_ payload: String) async {
        guard let code = PgpQrClient.scannedKeyCode(fromPayload: payload) else {
            state = .failed(
                message: "That doesn't look like a KyPost key code.",
                canRescan: true
            )
            return
        }
        if code.shownFingerprint == .malformed {
            state = .failed(message: Self.notTheShownKey, canRescan: true)
            return
        }
        state = .fetching
        do {
            let key = try await client.fetchKey(from: code.url)
            // Never display or store the relay's fingerprint string — compute
            // it from the key bytes, and treat a mismatch with the relay's
            // claim as the attack it would be (PgpFingerprint's header).
            guard let computed = PgpFingerprint.compute(fromArmored: key.publicKey) else {
                state = .failed(
                    message: "The key data couldn't be read — ask them to show a fresh code.",
                    canRescan: true
                )
                return
            }
            let claimed = key.fingerprint.filter { !$0.isWhitespace }.uppercased()
            if !claimed.isEmpty, claimed != computed {
                state = .failed(
                    message: "This key's real fingerprint doesn't match what the server claimed. Don't save it — the server may be misbehaving.",
                    canRescan: true
                )
                return
            }
            var verified = key
            verified.fingerprint = computed
            switch code.shownFingerprint {
            case .fingerprint(let shown) where shown == computed:
                state = .confirming(verified, inPerson: true)
            case .absent:
                state = .confirming(verified, inPerson: false)
            case .fingerprint, .malformed:
                state = .failed(message: Self.notTheShownKey, canRescan: true)
            }
        } catch NetworkError.unauthorized {
            // /key has no auth middleware, so this is the 403 branch: the
            // pairing token was expired or forged, never a credentials problem.
            state = .failed(
                message: "That code has expired — ask them to show a fresh one.",
                canRescan: true
            )
        } catch NetworkError.serviceUnavailable {
            state = .failed(
                message: "Key exchange isn't set up on that server.",
                canRescan: false
            )
        } catch NetworkError.server(statusCode: 404) {
            state = .failed(
                message: "They haven't set up a PGP key yet.",
                canRescan: true
            )
        } catch NetworkError.badRequest {
            state = .failed(
                message: "That doesn't look like a KyPost key code.",
                canRescan: true
            )
        } catch {
            state = .failed(message: error.localizedDescription, canRescan: true)
        }
    }

    func submitPastedLink() async {
        await handleScannedPayload(pastedLink)
    }

    /// Move on to choosing whose key it is.
    func confirmFingerprint() async {
        guard case .confirming(let key, let inPerson) = state else { return }
        contacts = (try? await repository.contacts()) ?? []
        state = .pickingContact(key, inPerson: inPerson)
    }

    func rescan() {
        pastedLink = ""
        state = .scanning
    }

    /// Attaches the key being picked for to `contact`, or to a new contact
    /// named after the key's owner when nil. Saving marks the contact for
    /// sync, so the key reaches the server on the next push rather than
    /// needing its own endpoint.
    func attach(to contact: Contact?) async {
        guard case .pickingContact(let key, let inPerson) = state else { return }
        var target = contact ?? Contact(
            name: key.name,
            createdAt: Date(),
            updatedAt: Date()
        )
        target.pgpKey = key.publicKey
        do {
            // Only a key matching the fingerprint the other device computed
            // itself becomes the pin for the contact's addresses.
            try await repository.saveContact(target, verifiedInPerson: inPerson)
            state = .saved(name: target.name, inPerson: inPerson)
        } catch {
            state = .failed(
                message: "Couldn't save the key: \(error.localizedDescription)",
                canRescan: false
            )
        }
    }

    static let notTheShownKey =
        "This key doesn't match the code they showed. Nothing was saved — ask them to show a fresh code."
}
