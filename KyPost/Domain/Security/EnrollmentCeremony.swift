//
//  EnrollmentCeremony.swift
//  KyPost
//
//  The device-enrollment state machine. Swift port of kypost-android's
//  pgp/EnrollmentCeremony.kt.
//

import Foundation

/// How often this device asks whether the browser has sealed yet. There is no
/// browser-to-device channel — the publish step is device-to-server only — so
/// polling is the only discovery mechanism this protocol has.
let enrollmentPollInterval: TimeInterval = 3

/// How long one polling window lasts.
///
/// **A background completion is impossible, not merely undesirable:** opening
/// the envelope needs the device key, which requires user presence, so the
/// ceremony's tail requires the user present and the app foregrounded. An
/// unbounded loop would be a screen holding a published key and a spoken-aloud
/// code until the process dies. Five minutes also means the code has rotated at
/// least twice, so the screen has had to refresh it anyway.
let enrollmentPollWindow: TimeInterval = 5 * 60

/// Every way enrollment can end. One case per row of the design's exit table,
/// because each gets a different sentence and sometimes a different button.
nonisolated enum EnrollmentState: Equatable, Sendable {
    case idle
    case checkingAccount
    case publishing
    /// Showing the short authentication string for the user to read into their
    /// browser. `windowOpen` distinguishes "still polling" from "timed out but
    /// the code is still on screen" — the Activity offers "Check again" on the
    /// latter, and the state alone cannot tell them apart.
    case showingCode(code: String, windowOpen: Bool)
    /// The browser has already sealed; finishing needs the user to authenticate.
    case readyToFinish
    case opening
    case enrolled

    // Terminal or blocked states.
    case noIdentity
    case hostileLocationEnabled
    case noDeviceCredential
    case notPaired
    case publishRejected(String)
    case timedOut
    /// GCM authentication failed: hostile or stale, never a retry.
    case envelopeRejected
    case sealFailed(String)
    /// The ring did not match what the server says it delivered, or storing
    /// it would lose key material this device already holds. Nothing was
    /// stored; the previous record is kept.
    case keyringRejected
    /// The server compared this device's acknowledgement with its delivery
    /// record and refused it. Final — the same claim cannot become true by
    /// repeating it. The record stays sealed; the user enrols again.
    case acknowledgementRefused
    case cancelled
    case failed(String)
}

/// What the ceremony needs from the outside world. Protocols rather than
/// concrete types so the whole exit table is a plain unit test — logic living
/// in a view is logic no test can reach, which is why Android split this out.
protocol EnrollmentTransport: Sendable {
    /// The account's PGP fingerprint, or nil when it has no identity.
    func identityFingerprint() async -> String?
    func publish(publicKey: Data) async -> EnrollmentPublishResult
    /// The sealed envelope, or nil when the browser has not sealed one yet.
    func fetchEnvelope() async -> EnrollmentEnvelopeResult
    /// Tells the server what this device now holds.
    func report(_ report: EnrollmentReport) async -> EnrollmentReportResult
}

nonisolated enum EnrollmentReportResult: Equatable, Sendable {
    case ok
    /// 409: the server compared the claim with its record and refused. Never
    /// retried.
    case conflict
    case unauthorized
    /// 404: no device row left to correct.
    case notFound
    /// Transport failure, 429, 5xx — worth restating later.
    case failed(String)
}

nonisolated enum EnrollmentPublishResult: Equatable, Sendable {
    case ok
    case unauthorized
    case rejected(String)
    case failed(String)
}

nonisolated enum EnrollmentEnvelopeResult: Equatable, Sendable {
    /// `delivery` is nil only from a server too old to record deliveries; a
    /// v3 envelope without it is refused rather than opened.
    case sealed(String, delivery: DeliveryMetadata? = nil)
    /// 404 covers both "never sealed" and "expired" — indistinguishable by
    /// design, and both mean keep waiting or re-run. One case so a caller
    /// cannot accidentally split them.
    case notSealed
    case unauthorized
    case failed(String)
}

/// Opening the envelope and storing it. Separated from the transport so the
/// ceremony takes no dependency on the Keychain or LocalAuthentication.
protocol EnrollmentSealer: Sendable {
    func deviceRawPublicKey() throws -> Data
    /// Opens, validates, stores durably and holds, or throws — and returns
    /// what to acknowledge. Requires user presence.
    func openAndStore(
        envelopeJSON: String,
        identityFingerprint: String,
        delivery: DeliveryMetadata?
    ) async throws -> EnrollmentReport
}

/// Drives enrollment and reports every transition.
///
/// `onState` rather than an owned stream: the view model owns what survives a
/// redraw, and a callback lets a test record the full transcript rather than
/// sampling a conflating stream.
actor EnrollmentCeremony {
    private let transport: any EnrollmentTransport
    private let sealer: any EnrollmentSealer
    private let deviceId: String
    private let hostileLocationEnabled: @Sendable () -> Bool
    private let hasDeviceCredential: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onState: @Sendable (EnrollmentState) -> Void
    /// Records that the acknowledgement did not land, for the launch-time
    /// reporter to restate. Android enqueues a WorkManager job here.
    private let deferReport: @Sendable () -> Void
    /// Records that it was settled — landed, or refused with a 409 — clearing
    /// any earlier pending restatement. A refused claim left pending from an
    /// earlier failed delivery would otherwise be repeated on the next
    /// foreground, and a 409 is terminal.
    private let reportSettled: @Sendable () -> Void

    /// Set once a keypair exists, so teardown knows whether there is anything
    /// to destroy and cannot report a deletion it never performed.
    private var keyPairLive = false

    init(
        transport: any EnrollmentTransport,
        sealer: any EnrollmentSealer,
        deviceId: String,
        hostileLocationEnabled: @escaping @Sendable () -> Bool,
        hasDeviceCredential: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        deferReport: @escaping @Sendable () -> Void = {},
        reportSettled: @escaping @Sendable () -> Void = {},
        onState: @escaping @Sendable (EnrollmentState) -> Void
    ) {
        self.deferReport = deferReport
        self.reportSettled = reportSettled
        self.transport = transport
        self.sealer = sealer
        self.deviceId = deviceId
        self.hostileLocationEnabled = hostileLocationEnabled
        self.hasDeviceCredential = hasDeviceCredential
        self.now = now
        self.sleep = sleep
        self.onState = onState
    }

    /// Runs one enrollment attempt to a terminal state.
    @discardableResult
    func run() async -> EnrollmentState {
        // Checked first, and again before storing: the envelope is accepted
        // only when Hostile Location Protection is off, and turning it on
        // destroys one. It is a deliberate posture change, not a default.
        if hostileLocationEnabled() { return emit(.hostileLocationEnabled) }
        guard hasDeviceCredential() else { return emit(.noDeviceCredential) }

        emit(.checkingAccount)
        guard let fingerprint = await transport.identityFingerprint(), !fingerprint.isEmpty else {
            return emit(.noIdentity)
        }

        emit(.publishing)
        let rawPublicKey: Data
        do {
            rawPublicKey = try sealer.deviceRawPublicKey()
            keyPairLive = true
        } catch {
            return emit(.sealFailed("\(error)"))
        }

        switch await transport.publish(publicKey: rawPublicKey) {
        case .ok:
            break
        case .unauthorized:
            return emit(.notPaired)
        case .rejected(let message):
            return emit(.publishRejected(message))
        case .failed(let message):
            return emit(.failed(message))
        }

        return await poll(rawPublicKey: rawPublicKey, fingerprint: fingerprint)
    }

    /// One polling window. The code is re-derived every tick because it rotates
    /// with the bucket, and a stale code on screen is one the browser rejects.
    private func poll(rawPublicKey: Data, fingerprint: String) async -> EnrollmentState {
        let deadline = now().addingTimeInterval(enrollmentPollWindow)
        while now() < deadline {
            let code = deviceEnrollmentCode(
                rawPublicKey: rawPublicKey,
                deviceId: deviceId,
                bucket: enrollmentBucket(at: now())
            )
            emit(.showingCode(code: code, windowOpen: true))

            switch await transport.fetchEnvelope() {
            case .sealed(let json, let delivery):
                return await finish(envelopeJSON: json, fingerprint: fingerprint, delivery: delivery)
            case .notSealed:
                await sleep(enrollmentPollInterval)
            case .unauthorized:
                return emit(.notPaired)
            case .failed(let message):
                return emit(.failed(message))
            }
        }
        return emit(.timedOut)
    }

    private func finish(
        envelopeJSON: String,
        fingerprint: String,
        delivery: DeliveryMetadata?
    ) async -> EnrollmentState {
        // Re-checked here, not only at the start: the user can turn Hostile
        // Location Protection on while the window is open, and storing an
        // envelope after that would leave the account's key on a device that
        // is supposed to hold nothing.
        if hostileLocationEnabled() { return emit(.hostileLocationEnabled) }

        emit(.opening)
        let report: EnrollmentReport
        do {
            report = try await sealer.openAndStore(
                envelopeJSON: envelopeJSON,
                identityFingerprint: fingerprint,
                delivery: delivery
            )
        } catch EnrollmentVaultError.cancelled {
            // Not an error: the user dismissed a prompt they raised. The
            // envelope is still there, so the screen offers "Check again".
            return emit(.cancelled)
        } catch EnrollmentSealerError.envelopeRejected {
            return emit(.envelopeRejected)
        } catch EnrollmentSealerError.keyringRejected {
            return emit(.keyringRejected)
        } catch {
            return emit(.sealFailed("\(error)"))
        }

        // Only now, with the record durable: an acknowledgement for material
        // that is not on disk would be a claim this device cannot back.
        switch await transport.report(report) {
        case .ok:
            reportSettled()
        case .conflict:
            reportSettled()
            return emit(.acknowledgementRefused)
        case .unauthorized, .notFound, .failed:
            // A dropped report is not a failed enrollment: the record is
            // sealed, so the next launch or foreground restates it.
            deferReport()
        }
        return emit(.enrolled)
    }

    @discardableResult
    private func emit(_ state: EnrollmentState) -> EnrollmentState {
        onState(state)
        return state
    }
}

nonisolated enum EnrollmentSealerError: Error, Equatable {
    /// GCM authentication failed. **Hostile or stale, never a retry** — the AAD
    /// binds the sealing to this device and this identity, so a failure means
    /// the envelope was minted for someone else or under an identity the
    /// account no longer advertises.
    case envelopeRejected
    /// The envelope did not parse at all: wrong version, wrong algorithm, or
    /// wrong-sized fields. Same conclusion — re-run the ceremony.
    case envelopeMalformed
    /// The opened ring is not what the server delivered, or storing it would
    /// lose key material already held. Nothing was stored.
    case keyringRejected
    /// The legacy merge with the previous record could not be built. Nothing
    /// was stored; the previous record is kept.
    case mergeFailed
}
