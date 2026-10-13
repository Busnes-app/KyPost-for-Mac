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

    /// Refresh this long before expiry, so a code on screen is always
    /// scannable rather than expiring in someone's camera.
    private static let refreshLeadTime: TimeInterval = 10

    private let client: PgpQrClient
    private let pairingStore: SecurePairingStore

    private(set) var state: State = .loading
    /// Drives the countdown; updated by `observeExpiry()` while visible.
    private(set) var now = Date()

    init(client: PgpQrClient, pairingStore: SecurePairingStore) {
        self.client = client
        self.pairingStore = pairingStore
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
        do {
            let response = try await client.fetchToken(
                serverUrl: pairing.srv,
                auth: RelayAuth(pairing: pairing)
            )
            guard let expiresAt = response.expiresAtDate else {
                state = .failed("The server sent an expiry date this app couldn't read.")
                return
            }
            now = Date()
            state = .showing(urlString: response.url, expiresAt: expiresAt)
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
        case confirming(PgpQrKeyResponse)
        case pickingContact(PgpQrKeyResponse)
        case saved(String)
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
        guard let url = PgpQrClient.keyURL(fromScannedPayload: payload) else {
            state = .failed(
                message: "That doesn't look like a KyPost key code.",
                canRescan: true
            )
            return
        }
        state = .fetching
        do {
            let key = try await client.fetchKey(from: url)
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
            state = .confirming(verified)
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

    /// Fingerprint confirmed in person — move on to choosing whose key it is.
    func confirmFingerprint() async {
        guard case .confirming(let key) = state else { return }
        contacts = (try? await repository.contacts()) ?? []
        state = .pickingContact(key)
    }

    func rescan() {
        pastedLink = ""
        state = .scanning
    }

    /// Attaches `key` to `contact`, or to a new contact named after the key's
    /// owner when nil. Saving marks the contact for sync, so the key reaches
    /// the server on the next push rather than needing its own endpoint.
    func attach(to contact: Contact?, key: PgpQrKeyResponse) async {
        var target = contact ?? Contact(
            name: key.name,
            createdAt: Date(),
            updatedAt: Date()
        )
        target.pgpKey = key.publicKey
        do {
            // The fingerprint was confirmed in person: this key becomes the
            // pin for the contact's addresses.
            try await repository.saveContact(target, verifiedInPerson: true)
            state = .saved(target.name)
        } catch {
            state = .failed(
                message: "Couldn't save the key: \(error.localizedDescription)",
                canRescan: false
            )
        }
    }
}
