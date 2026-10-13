//
//  PgpRelayFixtureEmitter.swift
//  KyPost Tests
//
//  Emits the exact bytes this client would put on the wire, for
//  scripts/verify-pgp-against-relay.sh to feed to the relay's OWN validators.
//
//  This is not a test of the send path — the rest of ClientEncryptedSendTests
//  is that. It exists because everything in this repository checks the send
//  path against fakes written in this repository, so the one thing never
//  checked is whether the server agrees. Re-deriving the server's rules here
//  would produce exactly the second, weaker copy that divergence is made of.
//
//  Skipped unless KYPOST_EMIT_RELAY_FIXTURES is set, which the script does. It
//  shows as a skip rather than a pass so a run that emitted nothing cannot be
//  mistaken for a run that emitted something.
//
//  The files land in the host app's own temporary directory, NOT in a path the
//  caller chooses: the app is sandboxed (ENABLE_APP_SANDBOX), so the test
//  process cannot write to an arbitrary mktemp -d the script made. The script
//  reads them back out of the sandbox container.
//
//  Real GopenPGP, real keys, the real ClientEncryptedSendClient over a stub
//  transport: the JSON written here is the literal request body the app would
//  have POSTed, not a reconstruction of it.
//

import Foundation
import Testing
@testable import KyPost

private let emitFixtures = ProcessInfo.processInfo.environment["KYPOST_EMIT_RELAY_FIXTURES"] != nil

/// Inside the sandbox this is the container's own tmp; the script resolves the
/// same directory from the outside via the bundle id.
private let fixtureDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("kypost-relay-fixtures", isDirectory: true)

/// Non-ASCII on purpose: the protected subject is the one header that has to
/// survive MIME encoding, and an ASCII-only fixture proves nothing about it.
private let fixtureSubject = "Café — Redundancies confirmed"

/// The user id on TestPgpFixtures' key. The relay binds every delivery's From
/// to the request's, so a fixture whose From is not the signer's own address
/// would be checking a weaker thing than the real send does.
private let fixtureAddress = "decrypt@example.invalid"

private struct FixtureOpener: VaultOpening {
    func open() async -> VaultOpenOutcome {
        .opened(privateKey: Data(TestPgpFixtures.armoredPrivate.utf8))
    }
}

private struct FixtureResolver: RecipientKeyResolving {
    func resolve(addresses: [String]) async -> ResolveResult {
        .success(addresses.map {
            ResolvedRecipientKey(
                address: $0,
                publicKey: TestPgpFixtures.armoredPublic,
                usable: true,
                tier: "contact"
            )
        })
    }
}

/// The real ClientEncryptedSendClient, wired to a transport that keeps the
/// request instead of sending it.
private final class BodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?
    func record(_ data: Data?) { lock.lock(); defer { lock.unlock() }; body = data }
    var captured: Data? { lock.lock(); defer { lock.unlock() }; return body }
}

@Suite struct PgpRelayFixtureEmitterTests {
    @Test(.enabled(if: emitFixtures))
    func emitTheWireBytesForTheRelayProbe() async throws {
        let out = fixtureDirectory
        // Removed first so a run that fails halfway cannot leave last run's
        // files behind for the probe to validate and call a pass.
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let capture = BodyCapture()
        let http = stubClient(json: #"{"sentSaved": true}"#) { request in
            capture.record(request.httpBody)
        }
        let client = ClientEncryptedSendClient(
            httpClient: http,
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "dev-1", deviceSecret: "secret-1")
        )

        // A BCC recipient is what makes this more than one delivery: each BCC
        // gets its own ciphertext so no BCC's key id appears in a packet
        // another recipient can read. The probe asserts on that count.
        let sender = ClientEncryptedSender(
            opener: FixtureOpener(),
            resolver: FixtureResolver(),
            transport: client,
            crypto: GopenPGPCrypto(),
            pins: { .none },
            accountAddress: fixtureAddress,
            session: EnrollmentSession(),
            now: { Date(timeIntervalSince1970: 1_787_000_000) }
        )

        let outcome = await sender.send(draft: ClientSendDraft(
            to: "to@example.com",
            cc: "cc@example.com",
            bcc: "bcc@example.com",
            subject: fixtureSubject,
            body: "<p>The numbers are attached.</p>",
            mode: "html"
        ))
        guard case .sent = outcome else {
            Issue.record("fixture send did not succeed: \(outcome)")
            return
        }

        let body = try #require(capture.captured, "the send client posted no body")
        try body.write(to: out.appendingPathComponent("request.json"))

        // Pull the first delivery back out of the JSON rather than out of the
        // in-memory model: what the probe validates has to be what actually
        // serialised, including any encoding the encoder applied.
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let deliveries = try #require(json["deliveries"] as? [[String: Any]])
        let first = try #require(deliveries.first?["ciphertext"] as? String)
        try Data(first.utf8).write(to: out.appendingPathComponent("delivery.eml"))

        // The protected content part, recovered by decrypting the delivery —
        // not rebuilt by calling buildProtectedContent a second time. A
        // second construction here could agree with itself while disagreeing
        // with what was actually encrypted.
        let armored = try #require(
            Self.armoredBlock(in: first),
            "no PGP MESSAGE block in the delivery this client just built"
        )
        let decrypted = try GopenPGPCrypto().decrypt(
            armoredCiphertext: armored,
            privateKey: Data(TestPgpFixtures.armoredPrivate.utf8),
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        try decrypted.body.write(to: out.appendingPathComponent("protected.mime"))
    }

    private static func armoredBlock(in delivery: String) -> String? {
        guard
            let start = delivery.range(of: "-----BEGIN PGP MESSAGE-----"),
            let end = delivery.range(of: "-----END PGP MESSAGE-----")
        else { return nil }
        return String(delivery[start.lowerBound..<end.upperBound])
    }
}
