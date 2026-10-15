//
//  TestSupport.swift
//  KyPost Tests
//
//  Scaffolding shared by the suite: the stub transport every networking test
//  builds on, a box for values captured inside its @Sendable closure, and the
//  scratch keychain/pairing setup.
//

import Foundation
@testable import KyPost

nonisolated let server = "https://relay.example.com"

/// An `HTTPClient` whose transport answers every request with `json` and
/// `status`, handing the request to `onRequest` first so tests can assert on
/// the URL, headers, or body it saw.
func stubClient(
    status: Int = 200,
    json: String = "{}",
    onRequest: (@Sendable (URLRequest) -> Void)? = nil
) -> HTTPClient {
    HTTPClient { request in
        onRequest?(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(json.utf8), response)
    }
}

/// Lock-protected storage for whatever a test captures inside `stubClient`'s
/// closure. The closure is `@Sendable`, so it cannot write to a local `var`.
///
/// `nonisolated`: the whole helper opts out of the test target's default
/// MainActor isolation. Its entire point is to be read and written from the
/// `@Sendable`, off-actor closures the transport stubs run — the internal
/// `NSLock` is what makes that safe, not actor isolation.
nonisolated final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        stored = value
    }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    /// Read-modify-write under a single acquisition — for counters and the
    /// append-only logs the concurrency tests assert on.
    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

/// A `SecurePairingStore` on a keychain scoped to this test, paired unless
/// `paired` is false. The scratch service name keeps parallel suites from
/// reading each other's pairing.
func makePairedStore(paired: Bool = true) throws -> SecurePairingStore {
    let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
    let store = SecurePairingStore(keychain: keychain)
    if paired {
        try store.savePairing(Pairing(
            sub: "u1",
            deviceSecret: "s1",
            srv: server,
            registrationUrl: nil,
            pairingToken: "pt",
            lastDeviceId: nil,
            pairedAt: Date()
        ))
    }
    return store
}

/// A contact with `emails` and no other payload — the shape the search and
/// compose-recipient tests rank against.
func makeContact(_ name: String, _ emails: String...) -> Contact {
    var contact = Contact(
        uid: nil,
        name: name,
        avatarUrl: nil,
        createdAt: Date(),
        updatedAt: Date()
    )
    contact.emails = emails.map { ContactLabeledValue(label: nil, value: $0) }
    return contact
}

/// A pairing connection that answers the probe with `observed` and registers
/// through `client`. Records what the service asked of it, so a test can
/// assert on the pin in force when the registration went out.
@MainActor
final class StubPairingConnection: PairingConnection {
    let host: String
    /// The pin the service opened the connection with.
    let initialPin: String?
    private let observed: String?
    private let client: NativeRegistrationClient
    private(set) var enforcedPin: String?
    /// The pin in force when `register` was called; nil if it never was.
    private(set) var pinAtRegister: String??
    private(set) var registrations = 0
    private(set) var isClosed = false

    init(host: String, pin: String?, observed: String?, client: NativeRegistrationClient) {
        self.host = host
        initialPin = pin
        enforcedPin = pin
        self.observed = observed
        self.client = client
    }

    func probe(_ url: URL) async -> String? {
        observed
    }

    func pin(_ hash: String) {
        enforcedPin = hash
    }

    func register(deviceToken: String, params: PairingParams, deviceId: String?) async -> RegistrationOutcome {
        registrations += 1
        pinAtRegister = .some(enforcedPin)
        return await client.register(deviceToken: deviceToken, params: params, deviceId: deviceId)
    }

    func close() {
        isClosed = true
    }
}

/// Opens `StubPairingConnection`s over `client` and keeps every one opened.
@MainActor
final class StubPairingConnections {
    var observed: String?
    private let client: NativeRegistrationClient
    private(set) var opened: [StubPairingConnection] = []

    init(client: HTTPClient, observed: String? = "hash-observed") {
        self.client = NativeRegistrationClient(httpClient: client)
        self.observed = observed
    }

    var last: StubPairingConnection? { opened.last }

    func make(host: String, pin: String?) -> any PairingConnection {
        let connection = StubPairingConnection(host: host, pin: pin, observed: observed, client: client)
        opened.append(connection)
        return connection
    }
}

/// A registration service whose pairings ride stub connections over the same
/// `client` its re-registrations use.
@MainActor
func makeRegistrationService(
    client: HTTPClient,
    pairingStore: SecurePairingStore,
    settings: PushSettingsStore,
    connections: StubPairingConnections? = nil
) -> DeviceRegistrationService {
    let connections = connections ?? StubPairingConnections(client: client)
    return DeviceRegistrationService(
        client: NativeRegistrationClient(httpClient: client),
        securePairingStore: pairingStore,
        pushSettingsStore: settings,
        makePairingConnection: { connections.make(host: $0, pin: $1) }
    )
}
