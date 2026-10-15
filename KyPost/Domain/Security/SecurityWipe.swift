//
//  SecurityWipe.swift
//  KyPost
//
//  Full destructive reset. Swift port of kypost-android's
//  security/SecurityWipe.kt.
//
//  It runs when the user's `WipeThreshold` of wrong PIN attempts accumulates,
//  and when the `AppLockStore` tripwire fires at launch.
//
//  **The steps are supplied by the caller, not built here.** Everything below
//  is the part that must be right whatever is being destroyed — fault
//  isolation, the resume marker, the attempt ceiling, the terminal state — and
//  keeping it free of SwiftData, Contacts and URLSession is what makes the
//  whole exit table an ordinary unit test with fake steps. `SecurityWipeSteps`
//  builds the real list.
//

import Foundation
import os

/// One named unit of destruction.
///
/// **A step must not catch its own errors.** Three of Android's delegated to
/// helpers whose every statement sat in its own logged `runCatching`, so the
/// step could not fail however badly it went — including the one that deletes
/// the user's contacts out of the OS provider. `Complete` was therefore a claim
/// the code structurally could not support. Let it throw; that is what the
/// isolation below is for.
@MainActor struct WipeStep {
    var name: String
    var run: () async throws -> Void

    init(_ name: String, run: @escaping () async throws -> Void) {
        self.name = name
        self.run = run
    }
}

/// Whether a wipe destroyed everything it set out to.
///
/// Scoped to **local destruction**. The best-effort server deregistration is
/// logged, not folded in: an unreachable relay says nothing about whether the
/// data on this machine is gone, and counting it would both lie to an offline
/// user and keep the resume marker set forever.
nonisolated enum WipeResult: Equatable, Sendable {
    case complete

    /// `willRetry` is false once the ceiling is reached, because at that point
    /// the app has stopped resuming the wipe by itself. The distinction exists
    /// so the UI does not promise a retry that will never happen — and
    /// `willRetry == false` is terminal, not merely informational: it persists
    /// across launches and blocks the app behind a manual-recovery notice.
    case incomplete(failedSteps: [String], willRetry: Bool)
}

@MainActor
final class SecurityWipe {
    /// How many runs one wipe gets — the first, then two resumes at later
    /// launches — before the app stops retrying. The third failed run is the
    /// one that abandons.
    ///
    /// Without a ceiling, a step that fails *permanently* means the app wipes
    /// itself on every launch, forever, with no way for the user past it.
    /// Three rides out a transient failure — a file held open, a provider
    /// briefly unavailable — and is few enough that a permanent one surfaces as
    /// a reported problem rather than a brick.
    static let maxAttempts = 3

    private let state: WipeStateStore

    init(state: WipeStateStore) {
        self.state = state
    }

    /// Runs every step, isolating each failure, and reports what could not be
    /// destroyed.
    ///
    /// `hostileLocationEnabled` / `restoreHostileLocation` carry the one
    /// setting a wipe must not silently downgrade. The sweep of the app's
    /// defaults takes the flag with it, and this wipe runs *precisely* when the
    /// machine is presumed hostile — so its side effect was to switch off the
    /// one feature that exists for that situation. A wipe may destroy data; it
    /// must not change posture.
    ///
    /// `release` runs last and **only when every step succeeded** — it is what
    /// lets the app come back unlocked (`SecurityWipeSteps.releaseLock`). A
    /// wipe that could not delete everything leaves the lock in place, so no
    /// path presents an unlocked app over data that is still here. Its own
    /// failure makes the run incomplete.
    func run(
        steps: [WipeStep],
        hostileLocationEnabled: Bool = false,
        restoreHostileLocation: (() throws -> Void)? = nil,
        release: WipeStep? = nil
    ) async -> WipeResult {
        // The marker goes down before anything is destroyed. A wipe interrupted
        // halfway is worse than one that never started, and this runs while an
        // attacker may be holding the machine — force-quitting is one keystroke
        // away.
        let posture = state.begin(hostileLocationEnabled: hostileLocationEnabled)

        var failed: [String] = []
        for step in steps {
            do {
                try await step.run()
            } catch {
                failed.append(step.name)
                Log.app.error("Wipe step failed: \(step.name, privacy: .public) — \(error)")
            }
        }

        // After the destruction, never before: written earlier it would simply
        // be swept away again. A step, so a failure to restore posture is
        // reported rather than leaving the user believing protection survived.
        // Nothing is re-enabled that was not already on.
        if posture, let restoreHostileLocation {
            do {
                try restoreHostileLocation()
            } catch {
                failed.append("restoreHostileLocationProtection")
                Log.app.error("Could not restore Hostile Location Protection after a wipe: \(error)")
            }
        }

        if failed.isEmpty, let release {
            do {
                try await release.run()
            } catch {
                failed.append(release.name)
                Log.app.error("Wipe release step failed: \(release.name, privacy: .public) — \(error)")
            }
        }

        guard !failed.isEmpty else {
            state.clear()
            return .complete
        }

        Log.app.error("WIPE INCOMPLETE — failed steps: \(failed, privacy: .public)")
        // Past the ceiling, stop asking the app to re-wipe itself at every
        // launch. What must *not* happen alongside that is clearing the marker:
        // deletion failed, so the app has to keep knowing it. The marker and
        // the failed step names persist, and every later launch reports the
        // same permanent verdict.
        let givingUp = state.attempts >= Self.maxAttempts
        state.recordFailure(steps: failed, abandoned: givingUp)
        return .incomplete(failedSteps: failed.sorted(), willRetry: !givingUp)
    }

    /// The terminal state as a value, or nil while the wipe is still being
    /// resumed (or has never run).
    ///
    /// Public so a screen can ask directly rather than inferring it from a bare
    /// "a wipe was interrupted", which is true of both a resumable wipe and an
    /// abandoned one and means opposite things.
    var abandonedWipe: WipeResult? {
        guard state.abandoned else { return nil }
        return .incomplete(failedSteps: state.failedSteps, willRetry: false)
    }

    /// "Refuse to do anything at all" — the abandoned-wipe state as a guard for
    /// entry points that never present a window.
    ///
    /// The state that reaches here is precisely: a wipe ran because the machine
    /// was presumed hostile, it could not delete everything, and it has stopped
    /// trying. The pairing credential is very often part of what survived, so
    /// the app can still receive push, still render sender and subject in a
    /// notification, and still approve an account login — every one of which is
    /// the thing the wipe existed to prevent.
    var blockedByAbandonedWipe: Bool { abandonedWipe != nil }

    /// A wipe started and never reached the end.
    ///
    /// True of both a resumable wipe and an abandoned one, which mean opposite
    /// things — ask `abandonedWipe` first.
    var hasInterruptedWipe: Bool { state.inProgress }
}
