//
//  SecurityWipeTests.swift
//  KyPost Tests
//
//  Phase 11: the wipe's marker, its fault isolation, its resume ceiling and
//  its terminal state — everything that has to be right whatever is being
//  destroyed. The step list itself is built elsewhere; these run against fakes.
//

import Foundation
import Testing
@testable import KyPost

private func makeWipeStore(keychain: KeychainStorage? = nil) -> WipeStateStore {
    WipeStateStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!, keychain: keychain)
}

private func scratchKeychain() -> KeychainStorage {
    KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
}

@MainActor
private func steps(_ names: [String], failing: Set<String> = []) -> (list: [WipeStep], ran: Box<[String]>) {
    let ran = Box<[String]>([])
    let list = names.map { name in
        WipeStep(name) {
            ran.mutate { $0.append(name) }
            if failing.contains(name) { throw WipeStepFailure("\(name) refused") }
        }
    }
    return (list, ran)
}

@MainActor
@Suite struct SecurityWipeTests {
    @Test func aCleanRunReportsCompleteAndClearsTheMarker() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)
        let (list, ran) = steps(["a", "b", "c"])

        #expect(await wipe.run(steps: list) == .complete)
        #expect(ran.value == ["a", "b", "c"])
        #expect(!state.inProgress)
        #expect(!wipe.hasInterruptedWipe)
        #expect(wipe.abandonedWipe == nil)
    }

    /// One failure must not abandon the rest. The steps after a broken one are
    /// the ones most worth running: an attacker is holding the machine.
    @Test func aFailedStepDoesNotStopTheOthers() async {
        let wipe = SecurityWipe(state: makeWipeStore())
        let (list, ran) = steps(["a", "b", "c"], failing: ["b"])

        let result = await wipe.run(steps: list)
        #expect(result == .incomplete(failedSteps: ["b"], willRetry: true))
        #expect(ran.value == ["a", "b", "c"])
    }

    /// The claim that must never be made falsely.
    @Test func anIncompleteRunKeepsTheMarkerSoItResumes() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)
        let (list, _) = steps(["a", "b"], failing: ["a"])

        _ = await wipe.run(steps: list)
        #expect(state.inProgress)
        #expect(wipe.hasInterruptedWipe)
        #expect(state.failedSteps == ["a"])
    }

    /// Three runs — the first and two resumes — ride out a transient failure;
    /// the third failure is where the app stops re-wiping itself at every
    /// launch, which without a ceiling is a brick with no way past it.
    @Test func theCeilingEndsTheAutomaticRetries() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)

        for attempt in 1...SecurityWipe.maxAttempts {
            let (list, _) = steps(["a"], failing: ["a"])
            let result = await wipe.run(steps: list)
            let expectRetry = attempt < SecurityWipe.maxAttempts
            #expect(result == .incomplete(failedSteps: ["a"], willRetry: expectRetry))
        }
        #expect(wipe.blockedByAbandonedWipe)
        #expect(wipe.abandonedWipe == .incomplete(failedSteps: ["a"], willRetry: false))
    }

    /// Giving up must not be expressed by forgetting. The marker and the step
    /// names survive, so every later launch can still say data may be here.
    @Test func givingUpKeepsTheEvidence() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)
        for _ in 1...SecurityWipe.maxAttempts {
            let (list, _) = steps(["a"], failing: ["a"])
            _ = await wipe.run(steps: list)
        }
        #expect(state.inProgress)
        #expect(state.abandoned)
        #expect(state.failedSteps == ["a"])
    }

    /// The counter belongs to one wipe, not to the install. Ordinary user
    /// actions trigger wipes, so a monotonic counter would be spent long before
    /// the wipe that matters — a thief burning PIN attempts — which would then
    /// abandon itself on its first failed step.
    @Test func aNewEpisodeGetsTheFullBudget() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)

        let (failing, _) = steps(["a"], failing: ["a"])
        _ = await wipe.run(steps: failing)
        let (clean, _) = steps(["a"])
        #expect(await wipe.run(steps: clean) == .complete)

        // A wipe after a clean one starts over rather than inheriting a count.
        let (failingAgain, _) = steps(["a"], failing: ["a"])
        #expect(await wipe.run(steps: failingAgain)
            == .incomplete(failedSteps: ["a"], willRetry: true))
        #expect(state.attempts == 1)
    }

    /// An abandoned episode is over even though its marker is still set — so a
    /// wipe triggered afterwards starts fresh rather than abandoning itself
    /// immediately.
    @Test func aWipeAfterAnAbandonedOneStartsANewEpisode() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)
        for _ in 1...SecurityWipe.maxAttempts {
            let (list, _) = steps(["a"], failing: ["a"])
            _ = await wipe.run(steps: list)
        }
        #expect(wipe.blockedByAbandonedWipe)

        let (list, _) = steps(["a"], failing: ["a"])
        #expect(await wipe.run(steps: list) == .incomplete(failedSteps: ["a"], willRetry: true))
        #expect(state.attempts == 1)
    }

    // MARK: - Posture

    /// A wipe may destroy data; it must not downgrade posture. This one runs
    /// *precisely* when the machine is presumed hostile, and the defaults sweep
    /// takes the flag with it.
    @Test func hostileLocationProtectionIsRestoredAfterTheSweep() async {
        let wipe = SecurityWipe(state: makeWipeStore())
        let restored = Box(false)
        let (list, _) = steps(["a"])

        _ = await wipe.run(
            steps: list,
            hostileLocationEnabled: true,
            restoreHostileLocation: { restored.value = true }
        )
        #expect(restored.value)
    }

    @Test func protectionThatWasOffIsNotTurnedOn() async {
        let wipe = SecurityWipe(state: makeWipeStore())
        let restored = Box(false)
        let (list, _) = steps(["a"])

        _ = await wipe.run(
            steps: list,
            hostileLocationEnabled: false,
            restoreHostileLocation: { restored.value = true }
        )
        #expect(!restored.value)
    }

    /// The posture is sticky across resumes. Re-reading it on a resumed run
    /// reads defaults the interrupted run already swept, answers false, and
    /// loses the setting permanently — so the user re-pairs onto a disk-backed
    /// plaintext database on a machine the app has just decided is hostile.
    @Test func theRecordedPostureSurvivesAResumeThatCannotSeeTheFlag() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)
        let (first, _) = steps(["a"], failing: ["a"])
        _ = await wipe.run(steps: first, hostileLocationEnabled: true, restoreHostileLocation: {})

        let restored = Box(false)
        let (resumed, _) = steps(["a"])
        _ = await wipe.run(
            steps: resumed,
            // The resumed run can no longer see the flag: the first run swept it.
            hostileLocationEnabled: false,
            restoreHostileLocation: { restored.value = true }
        )
        #expect(restored.value)
    }

    /// A restore that fails is reported, not assumed. Otherwise the user
    /// believes protection survived a wipe that switched it off.
    @Test func aFailedRestoreIsAReportedStep() async {
        let wipe = SecurityWipe(state: makeWipeStore())
        let (list, _) = steps(["a"])

        let result = await wipe.run(
            steps: list,
            hostileLocationEnabled: true,
            restoreHostileLocation: { throw WipeStepFailure("no") }
        )
        #expect(result == .incomplete(
            failedSteps: ["restoreHostileLocationProtection"], willRetry: true
        ))
    }

    // MARK: - The release step

    /// The lock comes off only when everything else went. A wipe that left
    /// data behind must not bring the app back unlocked over it.
    @Test func theReleaseRunsOnlyAfterACompleteRun() async {
        let wipe = SecurityWipe(state: makeWipeStore())
        let released = Box(0)
        let release = WipeStep("appLockOff") { released.mutate { $0 += 1 } }

        let (failing, _) = steps(["a", "b"], failing: ["b"])
        #expect(await wipe.run(steps: failing, release: release)
            == .incomplete(failedSteps: ["b"], willRetry: true))
        #expect(released.value == 0)

        let (clean, _) = steps(["a", "b"])
        #expect(await wipe.run(steps: clean, release: release) == .complete)
        #expect(released.value == 1)
    }

    /// A release that fails is a failed step: the marker stays, and the wipe
    /// resumes.
    @Test func aFailedReleaseIsIncomplete() async {
        let state = makeWipeStore()
        let wipe = SecurityWipe(state: state)
        let (list, _) = steps(["a"])
        let release = WipeStep("appLockOff") { throw WipeStepFailure("no") }

        #expect(await wipe.run(steps: list, release: release)
            == .incomplete(failedSteps: ["appLockOff"], willRetry: true))
        #expect(state.inProgress)
    }

    // MARK: - The Keychain mirror

    /// A defaults plist any process can delete was the only record that a wipe
    /// was owed. The Keychain copy keeps the app from opening as if nothing
    /// happened.
    @Test func theInProgressMarkerSurvivesLosingTheDefaults() async {
        let keychain = scratchKeychain()
        let wipe = SecurityWipe(state: makeWipeStore(keychain: keychain))
        let (list, _) = steps(["a"], failing: ["a"])
        _ = await wipe.run(steps: list)

        // The same Keychain, a fresh (deleted) defaults domain.
        let fresh = SecurityWipe(state: makeWipeStore(keychain: keychain))
        #expect(fresh.hasInterruptedWipe)
    }

    /// An abandoned wipe whose defaults were deleted resumes rather than
    /// opening — and rather than blocking forever: the same shape is a
    /// reinstall, and reinstalling has to stay the recovery.
    @Test func anAbandonedMarkerWithoutItsDefaultsResumesTheWipe() async {
        let keychain = scratchKeychain()
        let wipe = SecurityWipe(state: makeWipeStore(keychain: keychain))
        for _ in 1...SecurityWipe.maxAttempts {
            let (list, _) = steps(["a"], failing: ["a"])
            _ = await wipe.run(steps: list)
        }
        #expect(wipe.blockedByAbandonedWipe)

        let state = makeWipeStore(keychain: keychain)
        let fresh = SecurityWipe(state: state)
        #expect(fresh.hasInterruptedWipe)
        #expect(!fresh.blockedByAbandonedWipe)

        // A clean resume clears both copies.
        let (clean, _) = steps(["a"])
        #expect(await fresh.run(steps: clean) == .complete)
        #expect(!SecurityWipe(state: makeWipeStore(keychain: keychain)).hasInterruptedWipe)
        #expect(!state.inProgress)
    }

    /// Either copy saying "abandoned" blocks, as long as the episode's
    /// defaults record is there.
    @Test func eitherCopyOfAbandonedBlocks() async {
        let keychain = scratchKeychain()
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let state = WipeStateStore(defaults: defaults, keychain: keychain)
        let wipe = SecurityWipe(state: state)
        for _ in 1...SecurityWipe.maxAttempts {
            let (list, _) = steps(["a"], failing: ["a"])
            _ = await wipe.run(steps: list)
        }
        // Someone flips the plist's copy back.
        defaults.set(false, forKey: "wipe.abandoned")
        #expect(wipe.blockedByAbandonedWipe)
    }

    /// A clean wipe leaves nothing in the Keychain to resume.
    @Test func aCleanRunClearsTheKeychainCopy() async throws {
        let keychain = scratchKeychain()
        let wipe = SecurityWipe(state: makeWipeStore(keychain: keychain))
        let (list, _) = steps(["a"])
        #expect(await wipe.run(steps: list) == .complete)
        #expect(try keychain.string(forKey: "wipe.inProgress") == nil)
        #expect(try keychain.string(forKey: "wipe.abandoned") == nil)
    }
}
