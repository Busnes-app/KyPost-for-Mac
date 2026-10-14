//
//  RelayPairingConnection.swift
//  KyPost
//
//  The connection one pairing attempt uses (DeviceRegistrationService):
//  its own ephemeral URLSession and its own PinnedSessionDelegate, so the
//  pin it enforces — the link's, the stored one, or the hash its first
//  handshake presented — never reaches the shared relay session that
//  background sync and mail use. Ended with the attempt.
//

import Foundation

@MainActor
final class RelayPairingConnection: PairingConnection {
    /// The pin this connection's delegate enforces. Written here, read off
    /// the main actor by the delegate on every handshake.
    private nonisolated final class PinSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        init(_ value: String?) { self.value = value }

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: String) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    private let host: String
    private let slot: PinSlot
    private let delegate: PinnedSessionDelegate
    private let session: URLSession
    private let client: NativeRegistrationClient

    /// `host` is the relay's host; `pin`, when set, is enforced from the
    /// first handshake on. Any other host gets default TLS handling, and a
    /// redirect to one is refused by the delegate.
    init(host: String, pin: String?) {
        let host = host.lowercased()
        let slot = PinSlot(pin)
        let delegate = PinnedSessionDelegate { candidate in
            candidate.lowercased() == host ? slot.get() : nil
        }
        let configuration = PinnedSessionDelegate.relaySessionConfiguration()
        // One connection: the registration reuses the probed connection
        // where it can, and every new one is checked against the pin.
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.host = host
        self.slot = slot
        self.delegate = delegate
        self.session = session
        client = NativeRegistrationClient(httpClient: .pinned(session: session, delegate: delegate))
    }

    /// The session is new, so its first request opens a connection and the
    /// server-trust challenge fires: connection reuse or TLS resumption from
    /// another session cannot leave this without an observed hash.
    func probe(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // HEAD on the origin: no credentials, no body, and the status is
        // irrelevant — only the handshake matters. A 404 probes a certificate
        // exactly as well as a 200 does.
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        return delegate.lastSeenHash(forHost: url.host() ?? host)
    }

    func pin(_ hash: String) {
        slot.set(hash)
    }

    func register(deviceToken: String, params: PairingParams, deviceId: String?) async -> RegistrationOutcome {
        await client.register(deviceToken: deviceToken, params: params, deviceId: deviceId)
    }

    func close() {
        session.invalidateAndCancel()
    }
}
