//
//  DeviceEnrollmentViewModel.swift
//  KyPost
//
//  Owns the enrollment ceremony's lifetime and its latest state.
//

import Foundation
import Observation

@Observable
@MainActor
final class DeviceEnrollmentViewModel {
    private(set) var state: EnrollmentState = .idle

    private let makeCeremony: @Sendable (@escaping @Sendable (EnrollmentState) -> Void)
        -> EnrollmentCeremony?
    private var task: Task<Void, Never>?

    init(
        makeCeremony: @escaping @Sendable (@escaping @Sendable (EnrollmentState) -> Void)
            -> EnrollmentCeremony?
    ) {
        self.makeCeremony = makeCeremony
    }

    /// True once there is nothing left to do — the screen's button becomes
    /// "Done" rather than "Cancel".
    var isFinished: Bool { state == .enrolled }

    /// Whether "Check again" is worth offering.
    ///
    /// `showingCode` means two different things depending on whether a polling
    /// window is still running behind it, which is why the state carries that
    /// flag rather than the view inferring it.
    var offersRetry: Bool {
        switch state {
        case .timedOut, .cancelled, .readyToFinish, .failed, .sealFailed,
             .keyringRejected, .acknowledgementRefused:
            true
        case .showingCode(_, let windowOpen):
            !windowOpen
        default:
            false
        }
    }

    func start() {
        task?.cancel()
        state = .idle
        task = Task { [makeCeremony] in
            guard let ceremony = makeCeremony({ [weak self] state in
                Task { @MainActor in self?.state = state }
            }) else {
                await MainActor.run { self.state = .notPaired }
                return
            }
            await ceremony.run()
        }
    }

    /// Leaving the screen ends the window. The ceremony's tail needs the user
    /// present anyway, so a window running behind a dismissed screen would be
    /// a published key and a spoken-aloud code with nobody watching.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
