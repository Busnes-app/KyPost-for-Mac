//
//  PgpSendService.swift
//  KyPost
//
//  What compose needs to know before offering encryption
//  (Client_Encrypted_Send.md "Required behavior" 1 and 3):
//    - the account's key custody, fetched once per session from
//      GET /api/pgp/bootstrap. The mode is chosen at key creation and has no
//      downgrade path, so it cannot change behind a session's back.
//    - the recipient key preflight, POST /api/pgp/recipients/check.
//
//  Both degrade quietly. A bootstrap failure leaves custody unknown and
//  compose offers no PGP toggles; a preflight failure warns about nothing. The
//  relay's 409 is the real gate either way.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class PgpSendService {
    private let client: PgpSendClient
    private let securePairingStore: SecurePairingStore

    /// Nil until a successful load: unknown, not "no identity". Compose shows
    /// no toggle while it is nil — better no toggle than one that lies.
    private(set) var custody: PgpKeyCustody?

    /// Bootstrap's raw answers, kept so the compose state can be re-derived.
    private(set) var hasIdentity: Bool?
    private(set) var protection: String?

    /// `suggestedUserIDs[0]`, or empty when the account has no mail address
    /// configured — in which case no delivery `From` can be built.
    private(set) var accountAddress = ""

    init(client: PgpSendClient, securePairingStore: SecurePairingStore) {
        self.client = client
        self.securePairingStore = securePairingStore
    }

    /// Which controls compose may offer.
    ///
    /// **Derived on every call, never cached.** Custody is fixed when the key
    /// is created, so the bootstrap response is worth caching — but enrollment
    /// can change while the app is running, and a state computed once at
    /// launch would keep offering an on-device send after the key was wiped,
    /// or keep hiding it after the user enrolled.
    func composeState(deviceEnrolled: Bool) -> PgpComposeState {
        pgpComposeState(
            hasIdentity: hasIdentity,
            protection: protection,
            deviceEnrolled: deviceEnrolled,
            accountAddress: accountAddress
        )
    }

    /// Installs a bootstrap answer without a network call, and marks the
    /// session loaded so `loadIfNeeded` leaves it alone. Only the DEBUG
    /// screenshot build uses this (SingletonGraph, DemoContent.isEnabled) —
    /// nothing in a shipping build may decide custody locally.
    func preload(hasIdentity: Bool, protection: String, accountAddress: String) {
        self.hasIdentity = hasIdentity
        self.protection = protection
        self.accountAddress = accountAddress
        custody = pgpKeyCustody(hasIdentity: hasIdentity, protection: protection)
    }

    /// Loads key custody once per session. Cheap to call from every compose
    /// window's `.task`.
    func loadIfNeeded() async {
        guard custody == nil, let credentials = pairingCredentials else { return }
        do {
            let response = try await client.fetchBootstrap(
                serverUrl: credentials.serverUrl,
                auth: credentials.auth
            )
            hasIdentity = response.hasIdentity
            protection = response.protection
            accountAddress = response.suggestedUserIDs?.first ?? ""
            custody = pgpKeyCustody(
                hasIdentity: response.hasIdentity,
                protection: response.protection
            )
        } catch {
            // .error, not .debug: this failure silently disables every PGP
            // toggle with no visible sign to the user, so it must be the kind
            // of thing a customer sysdiagnose actually captures.
            //
            // The *shape* is public, the description is not. `.decoding`
            // interpolates the failing key path and `.conflict` carries the
            // relay's response body — recipient addresses among them — and
            // `.public` wrote all of it into the unified log, which persists
            // and travels in every sysdiagnose.
            Log.mail.error(
                "PGP bootstrap failed: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// The account's addresses, fetched fresh rather than from this
    /// session's cache: an RSVP names one of them as the attendee, and a cache
    /// filled before an unpair and re-pair would answer as the old account.
    /// Nil when unpaired or the fetch failed.
    func fetchAccountAddresses() async -> [String]? {
        guard let credentials = pairingCredentials else { return nil }
        guard let response = try? await client.fetchBootstrap(
            serverUrl: credentials.serverUrl,
            auth: credentials.auth
        ) else { return nil }
        return response.suggestedUserIDs ?? []
    }

    /// Addresses among `addresses` with no usable key **in the user's
    /// contacts**.
    ///
    /// A lower bound, never a promise: the send path also runs WKD and
    /// keyserver discovery, so an address returned here may still be encrypted
    /// to successfully. Word the warning as "no key on file", never as "this
    /// will be sent as a plaintext link".
    func keylessRecipients(among addresses: [String]) async -> [String] {
        guard !addresses.isEmpty, let credentials = pairingCredentials else { return [] }
        do {
            let results = try await client.checkRecipients(
                addresses,
                serverUrl: credentials.serverUrl,
                auth: credentials.auth
            )
            return keylessAddresses(in: results)
        } catch {
            Log.mail.debug("PGP recipient preflight failed: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private var pairingCredentials: (serverUrl: String, auth: RelayAuth)? {
        guard let pairing = try? securePairingStore.loadPairing(), !pairing.srv.isEmpty else {
            return nil
        }
        return (pairing.srv, RelayAuth(pairing: pairing))
    }
}
