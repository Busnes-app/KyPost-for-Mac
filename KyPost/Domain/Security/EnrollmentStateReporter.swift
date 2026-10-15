//
//  EnrollmentStateReporter.swift
//  KyPost
//
//  Restates this device's enrollment to the server when the ceremony's own
//  acknowledgement did not land, or after a deliberate teardown. Counterpart
//  of kypost-android's pgp/EnrollmentStateWorker.kt.
//
//  Android uses a WorkManager job with exponential backoff. Here it runs at
//  launch and on every foreground — both already gated behind the app lock —
//  and only while a marker says there is something to say. The decision
//  functions are pure so the whole table is a unit test.
//

import Foundation

/// What to do after one attempt.
nonisolated enum EnrollmentReportOutcome: Equatable, Sendable {
    case done
    case retry
    case giveUp
}

/// A ceiling, so a report the server will never take does not run forever.
nonisolated let maxEnrollmentReportAttempts = 8

/// What the record on disk lets this device claim, read without the key.
nonisolated struct EnrollmentRecordSummary: Equatable, Sendable {
    var kind: VaultRecordKind
    var acknowledgement: KeyringAcknowledgement?
}

/// What to tell the server for the record on disk; nil means say nothing.
///
/// A keyring record is confirmed with the values stored beside it, never
/// restated as the legacy boolean — a converted account refuses that.
/// `notEnrolled` makes the server forget its delivery record, so it is sent
/// only on a proven loss: a deliberate teardown (`tornDown`). Finding no
/// record on an ordinary launch proves nothing — it is also what a device
/// awaiting its first delivery looks like.
nonisolated func enrollmentReportFor(
    _ record: EnrollmentRecordSummary?,
    tornDown: Bool
) -> EnrollmentReport? {
    guard let record else { return tornDown ? .notEnrolled : nil }
    switch record.kind {
    case .legacyArmor:
        return .legacy
    case .keyring:
        guard let ack = record.acknowledgement else { return nil }
        return .keyring(materialGeneration: ack.materialGeneration, fingerprint: ack.fingerprint)
    }
}

/// Retry whenever the server's marker may be wrong and waiting could help.
nonisolated func enrollmentReportOutcome(
    _ result: EnrollmentReportResult,
    attempts: Int
) -> EnrollmentReportOutcome {
    switch result {
    case .ok:
        return .done
    case .failed:
        return attempts >= maxEnrollmentReportAttempts ? .giveUp : .retry
    // No device row to correct, or a claim the server compared with its
    // delivery record and refused: repeating it cannot help.
    case .unauthorized, .notFound, .conflict:
        return .giveUp
    }
}

/// Whether an attempt spends the teardown marker: only when the correction
/// landed or no device row remains to correct. A transient failure keeps it
/// past the attempt ceiling — with no record on disk, "not enrolled" stays
/// true however long it waits.
nonisolated func teardownReportSpent(_ result: EnrollmentReportResult) -> Bool {
    switch result {
    case .ok, .unauthorized, .notFound, .conflict: true
    case .failed: false
    }
}

/// A pending acknowledgement: tries so far, and the delivery it belongs to.
nonisolated struct PendingEnrollmentReport: Equatable, Sendable {
    var attempts: Int
    var revision: String
}

/// The vault half the reporter needs, so the reporter is testable without the
/// Keychain.
nonisolated protocol EnrollmentReportStore: Sendable {
    /// Throws when the record cannot be read: an unreadable record proves
    /// nothing and must not speak for the device.
    func recordSummary() throws -> EnrollmentRecordSummary?
    var teardownReportPending: Bool { get }
    var pendingReport: PendingEnrollmentReport? { get }
    /// Compare-and-set: acts only while the marker is still `expected`, so a
    /// request that finishes after a newer delivery cannot clear or rewind it.
    @discardableResult
    func replacePendingReport(ifRevision expected: String, with next: PendingEnrollmentReport?) -> Bool
    @discardableResult func clearTeardownReport() -> Bool
}

nonisolated extension EnrollmentVault: EnrollmentReportStore {
    func recordSummary() throws -> EnrollmentRecordSummary? {
        // The clear header: restating enrollment never needs the key, so it
        // never raises the presence prompt.
        guard let header = try storedHeader() else { return nil }
        return EnrollmentRecordSummary(kind: header.kind, acknowledgement: header.acknowledgement)
    }
}

nonisolated struct EnrollmentStateReporter: Sendable {
    private let store: any EnrollmentReportStore
    private let send: @Sendable (EnrollmentReport) async -> EnrollmentReportResult

    init(
        store: any EnrollmentReportStore,
        send: @escaping @Sendable (EnrollmentReport) async -> EnrollmentReportResult
    ) {
        self.store = store
        self.send = send
    }

    /// One attempt, if a marker asks for one. Returns what was sent, or nil.
    @discardableResult
    func runIfNeeded() async -> EnrollmentReport? {
        let tornDown = store.teardownReportPending
        let pending = store.pendingReport
        guard tornDown || pending != nil else { return nil }

        let summary: EnrollmentRecordSummary?
        do {
            summary = try store.recordSummary()
        } catch {
            return nil
        }
        guard let report = enrollmentReportFor(summary, tornDown: tornDown) else {
            if let pending { store.replacePendingReport(ifRevision: pending.revision, with: nil) }
            return nil
        }

        let result = await send(report)
        if tornDown, teardownReportSpent(result) { store.clearTeardownReport() }
        // Only a pending acknowledgement counts attempts; a teardown report is
        // governed by its own marker above. Every write is conditional on the
        // revision read before sending: a re-enrollment while the request was
        // in flight wrote a newer marker this result says nothing about.
        guard let pending else { return report }
        let attempts = pending.attempts + 1
        switch enrollmentReportOutcome(result, attempts: attempts) {
        case .done, .giveUp:
            store.replacePendingReport(ifRevision: pending.revision, with: nil)
        case .retry:
            store.replacePendingReport(
                ifRevision: pending.revision,
                with: PendingEnrollmentReport(attempts: attempts, revision: pending.revision)
            )
        }
        return report
    }
}

/// Runs the reporter from the app's lifecycle hooks — launch, unlock, iOS
/// foreground, macOS activation — behind the app lock and the abandoned-wipe
/// gate, at most one run at a time. Hooks overlap (macOS fires launch and
/// activation together), and two runs would read the same marker and send the
/// same claim twice.
@MainActor
final class EnrollmentReportTrigger {
    private var inFlight: Task<Void, Never>?

    /// Starts a run unless gated or one is already in flight; returns it.
    @discardableResult
    func fire(
        isLocked: Bool,
        blockedByAbandonedWipe: Bool,
        makeReporter: () -> EnrollmentStateReporter?
    ) -> Task<Void, Never>? {
        // Telling the server what key material this device holds is not a
        // claim to make while locked, or from a device the app failed to erase.
        guard !isLocked, !blockedByAbandonedWipe, inFlight == nil,
              let reporter = makeReporter() else { return nil }
        let task = Task { [weak self] in
            await reporter.runIfNeeded()
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }
}
