//
//  WipeStateStore.swift
//  KyPost
//
//  The security wipe's own progress marker. Swift port of the wipe-state half
//  of kypost-android's SecurityWipe.kt.
//
//  **This store must outlive the wipe's own deletions.** `SecurityWipe` sweeps
//  the app's `UserDefaults` domain, and `retainedKeyPrefix` is what keeps this
//  record out of that sweep — an interruption that erased the evidence a wipe
//  was started is exactly the state the marker exists to prevent.
//
//  **The two markers that gate the app are mirrored into the Keychain.** A
//  defaults plist is a file any process running as the user can delete, and
//  deleting it used to be enough to make a half-wiped app open as if nothing
//  had happened. Either copy saying "a wipe is owed" is believed.
//

import Foundation
import os

nonisolated final class WipeStateStore: Sendable {
    /// Every key here begins with this, and the defaults sweep skips the
    /// prefix rather than a list of names — a list goes stale the first time a
    /// key is added. The Keychain mirror uses the same names; nothing in the
    /// wipe removes Keychain items under it.
    static let retainedKeyPrefix = "wipe."

    private enum Key {
        static let inProgress = "wipe.inProgress"
        static let attempts = "wipe.attempts"
        static let abandoned = "wipe.abandoned"
        static let failedSteps = "wipe.failedSteps"
        static let hostileLocationWasEnabled = "wipe.hostileLocationWasEnabled"
    }

    private let defaults: UserDefaults
    /// Nil only in tests that exercise the defaults half alone.
    private let keychain: KeychainStorage?

    init(defaults: UserDefaults = .standard, keychain: KeychainStorage?) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// A wipe started and has not yet finished cleanly — by either copy.
    ///
    /// A Keychain marker with no defaults record is the shape of a deleted
    /// plist, and also of a reinstall (Keychain items survive both). Either
    /// way the answer is to run the wipe again, not to block: it destroys
    /// what a deleted plist was hiding, and after a reinstall it finds little
    /// left and completes, which clears both copies — so reinstalling stays
    /// the recovery `ManualRecoveryView` promises.
    var inProgress: Bool {
        defaults.bool(forKey: Key.inProgress)
            || keychainFlag(Key.inProgress) || keychainFlag(Key.abandoned)
    }

    var attempts: Int { defaults.integer(forKey: Key.attempts) }

    /// The terminal state: the app has stopped resuming the wipe by itself,
    /// **without** forgetting that data may still be here.
    ///
    /// Only while the defaults record of this episode is there too — see
    /// `inProgress` for what a Keychain-only marker means instead.
    var abandoned: Bool {
        guard defaults.bool(forKey: Key.inProgress) else { return false }
        return defaults.bool(forKey: Key.abandoned) || keychainFlag(Key.abandoned)
    }

    var failedSteps: [String] {
        (defaults.array(forKey: Key.failedSteps) as? [String] ?? []).sorted()
    }

    /// The Hostile Location Protection posture captured at the *start* of the
    /// wipe, kept here rather than re-read on a resume.
    ///
    /// Re-reading it would read the defaults an interrupted run already swept,
    /// answer false, and lose the setting permanently — so the user re-pairs
    /// onto a disk-backed plaintext database on a machine the app has just
    /// decided is hostile. Once a wipe has recorded that protection was on,
    /// every resume of that wipe restores it.
    var hostileLocationWasEnabled: Bool { defaults.bool(forKey: Key.hostileLocationWasEnabled) }

    /// Sets the marker, counts this attempt and records the posture, before
    /// anything is destroyed. Returns the posture the *first* run of this wipe
    /// observed.
    ///
    /// The attempt counter belongs to one wipe, not to the install. A set
    /// marker means this run resumes an episode already under way, so the count
    /// climbs and the ceiling bounds it; a clear marker starts a new episode
    /// with the full budget. Ordinary user actions can trigger a wipe, so a
    /// counter monotonic for the life of the install would be spent long
    /// before the wipe that matters — a thief burning PIN attempts — which
    /// would then abandon itself on its first failed step.
    ///
    /// An abandoned episode is over even though its marker is still set, so it
    /// does not lend its spent counter to the next one.
    @discardableResult
    func begin(hostileLocationEnabled: Bool) -> Bool {
        let posture = hostileLocationEnabled || defaults.bool(forKey: Key.hostileLocationWasEnabled)
        let resuming = defaults.bool(forKey: Key.inProgress) && !abandoned
        defaults.set(true, forKey: Key.inProgress)
        setKeychainFlag(Key.inProgress, true)
        defaults.set(posture, forKey: Key.hostileLocationWasEnabled)
        defaults.set(resuming ? attempts + 1 : 1, forKey: Key.attempts)
        defaults.set(false, forKey: Key.abandoned)
        setKeychainFlag(Key.abandoned, false)
        return posture
    }

    /// Persists what this run could not destroy, alongside whether the app has
    /// stopped resuming it.
    func recordFailure(steps: [String], abandoned: Bool) {
        defaults.set(steps, forKey: Key.failedSteps)
        defaults.set(abandoned, forKey: Key.abandoned)
        setKeychainFlag(Key.abandoned, abandoned)
    }

    /// Ends this wipe — **only ever from the clean-run branch**, because these
    /// values are the record that destruction is still owed.
    ///
    /// **The attempt count deliberately stays**, and is reset by `begin` when
    /// it observes a clear marker. Resetting it in both places is what let the
    /// ceiling bound nothing on Android: the counter cycled 1, 2, 0, 1, 2, 0
    /// across seven consecutive failing wipes. Resetting only at episode start
    /// keeps "the ceiling bounds one wipe" true even if this method is edited
    /// later.
    ///
    /// A Keychain copy that will not go away keeps the marker set, so the
    /// next launch runs the (idempotent) wipe again rather than forgetting.
    func clear() {
        defaults.removeObject(forKey: Key.inProgress)
        defaults.removeObject(forKey: Key.abandoned)
        defaults.removeObject(forKey: Key.failedSteps)
        defaults.removeObject(forKey: Key.hostileLocationWasEnabled)
        try? keychain?.remove(Key.inProgress)
        try? keychain?.remove(Key.abandoned)
    }

    // MARK: - Keychain mirror

    /// A Keychain that will not answer reads as "no marker", leaving the
    /// decision to the defaults copy. Reading it as "a wipe is owed" would
    /// erase the user's data because a Mac login item started before the
    /// Keychain was ready.
    private func keychainFlag(_ key: String) -> Bool {
        (try? keychain?.string(forKey: key)) == "true"
    }

    /// Best effort: the defaults copy is written regardless, and is still the
    /// record that resumes the wipe.
    private func setKeychainFlag(_ key: String, _ value: Bool) {
        do {
            if value {
                try keychain?.set("true", forKey: key)
            } else {
                try keychain?.remove(key)
            }
        } catch {
            Log.app.error("Could not mirror the wipe marker \(key, privacy: .public) into the Keychain: \(error)")
        }
    }
}
