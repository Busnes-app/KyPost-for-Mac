//
//  LockoutPolicy.swift
//  KyPost
//
//  Escalating-delay and eventual-wipe curve for wrong app-lock PIN attempts.
//  Swift port of kypost-android's security/LockoutPolicy.kt.
//
//  **This reverses an earlier decision in this app.** AppLockStore and the
//  README both said rate-limiting and lockout were the OS's job, because
//  verification was LAContext's. With an app-lock PIN of our own there is no
//  OS counter to lean on: the passcode ladder throttles guesses at the
//  passcode, not at this app's PIN, and a PIN checked in-process is otherwise
//  an unthrottled oracle. Both documents are updated rather than quietly
//  edited — see README's "Require Unlock to Open".
//

import Foundation

nonisolated enum LockoutPolicy {
    /// Attempts 1–2 are free; typos happen. From the third on, each wrong
    /// attempt costs the next entry here, and the last value repeats.
    private static let delaysMillis: [Int64] = [30_000, 60_000, 300_000, 900_000, 1_800_000]
    private static let firstDelayedAttempt = 3

    static func delayMillis(forAttemptCount attempts: Int) -> Int64 {
        guard attempts >= firstDelayedAttempt else { return 0 }
        let index = min(attempts - firstDelayedAttempt, delaysMillis.count - 1)
        return delaysMillis[index]
    }

    /// Whether `attemptCount` consecutive wrong attempts — no intervening
    /// success — reach the user's threshold. `.never` only ever rejects.
    static func shouldWipe(attemptCount: Int, threshold: WipeThreshold) -> Bool {
        guard let limit = threshold.attempts else { return false }
        return attemptCount >= limit
    }
}

/// How many consecutive wrong PINs erase local data — user-selectable, as on
/// Android (`LockoutPolicy.WIPE_THRESHOLD_CHOICES`).
///
/// **The default stays 10, not Android's 30.** Ten is what this app has always
/// shipped and what every existing user was told when they set their PIN;
/// quietly tripling it would loosen a protection nobody asked to loosen. A
/// user who wants Android's behaviour picks it, and picking a looser value
/// re-authenticates.
nonisolated enum WipeThreshold: Hashable, Sendable {
    case after(Int)
    case never

    static let choices: [WipeThreshold] = [.after(10), .after(20), .after(30), .never]
    static let `default`: WipeThreshold = .after(10)
    /// What an unreadable, malformed or unauthenticated stored value reads as.
    static let strictest: WipeThreshold = .after(10)

    var attempts: Int? {
        if case .after(let count) = self { return count }
        return nil
    }

    /// Whether moving from `self` to `other` lets an attacker guess more —
    /// the direction that re-authenticates.
    func isLooser(than other: WipeThreshold) -> Bool {
        switch (self, other) {
        case (.never, .never): return false
        case (.never, _): return true
        case (_, .never): return false
        case (.after(let mine), .after(let theirs)): return mine > theirs
        }
    }

    /// Stored form. Only the four choices round-trip; anything else is not a
    /// value this app wrote.
    var wire: String {
        switch self {
        case .after(let count): return String(count)
        case .never: return "never"
        }
    }

    init?(wire: String) {
        if wire == "never" {
            self = .never
            return
        }
        guard let count = Int(wire), let match = Self.choices.first(where: { $0.attempts == count }) else {
            return nil
        }
        self = match
    }
}

/// Binds the stored threshold to this device's PIN pepper.
///
/// The threshold sits beside the verifier in the Keychain, and "never" is one
/// small write away from disabling the wipe entirely. The tag is the pepper's
/// HMAC over the value, so writing a looser value takes the device-bound key
/// the PIN itself depends on; anything that does not verify — a forged or
/// garbled value, a missing tag, a pepper that is gone, a Keychain that will
/// not answer — reads as `WipeThreshold.strictest`. Deleting the record reads
/// as the default, which is the strictest choice too.
nonisolated enum WipeThresholdSeal {
    private static let domain = "KyPost wipe threshold v1:"

    static func tag(for threshold: WipeThreshold, pepper: any PinPepper) throws -> Data {
        try pepper.mix(Data((domain + threshold.wire).utf8))
    }

    static func read(_ record: AppLockStore.StoredWipeThreshold, pepper: any PinPepper) -> WipeThreshold {
        switch record {
        case .absent:
            return .default
        case .unreadable:
            return .strictest
        case .stored(let wire, let storedTag):
            guard let threshold = WipeThreshold(wire: wire),
                  let expected = try? tag(for: threshold, pepper: pepper),
                  constantTimeEqual(expected, storedTag)
            else { return .strictest }
            return threshold
        }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

/// How long the app may sit in the background (iOS) or behind a locked screen
/// (macOS) before the lock engages. Android: `AppLockSettings`, same options.
///
/// **Default is Immediately**, which is what this app has always done. Android
/// defaults to 30 seconds because locking on every background transition
/// destroyed its compose screen whenever the file picker or QR scanner ran;
/// iOS pickers run without backgrounding the app, so that reason does not
/// carry over, and lengthening an existing user's exposure without asking is
/// the wrong direction to drift.
nonisolated enum LockGracePeriod {
    static let options: [Int] = [0, 30, 60, 300]
    static let defaultSeconds = 0
    static let maxSeconds = 300

    /// Fail closed: a value this app did not write is Immediately.
    static func sanitized(_ seconds: Int?) -> Int {
        guard let seconds, options.contains(seconds) else { return 0 }
        return seconds
    }
}
