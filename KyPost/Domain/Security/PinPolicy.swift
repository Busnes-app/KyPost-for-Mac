//
//  PinPolicy.swift
//  KyPost
//
//  What counts as an acceptable app-lock PIN. Swift port of kypost-android's
//  security/PinPolicy.kt.
//

import Foundation

/// Why a proposed PIN was refused, or that it was accepted.
nonisolated enum PinPolicyResult: Equatable, Sendable {
    case valid
    case tooShort
    case tooLong
    case notNumeric
    case tooCommon
}

/// The lock wipes after the user's `WipeThreshold` (10 by default) wrong
/// attempts, so an attacker gets that many guesses — which is what makes the
/// handful of PINs everybody picks a real risk rather than a theoretical one.
/// All of them would otherwise land inside `weakPins`.
nonisolated enum PinPolicy {
    /// **Eight, not six.** Iteration count cannot defend a small keyspace: both
    /// the verifier and the wrapping key are peppered with a device-bound
    /// secret that forces brute force to run on this machine, but 10^6 is still
    /// minutes-to-an-hour of those calls where 10^8 is days.
    static let minLength = 8
    static let maxLength = 12

    /// What a PIN entry field keeps of its text. `PinPolicy` alone decides the
    /// length, so a field caps at `maxLength` here rather than at a literal —
    /// Android's unlock layout hardcoded 6 while the policy required 8 to 12,
    /// and a valid PIN could never be typed in full (Android #139).
    static func capped(_ entry: String) -> String {
        entry.count > maxLength ? String(entry.prefix(maxLength)) : entry
    }

    /// Sized for `minLength` and up. `validate` checks length first, so a
    /// six-digit entry here would be dead code — rejected as `tooShort` before
    /// the set is ever consulted.
    ///
    /// Pure ascending/descending/constant runs of any length are caught by
    /// `isRun` instead, so this covers the repeating- and dated-pattern
    /// families a run check cannot see.
    private static let weakPins: Set<String> = [
        // Repeating pairs and quads.
        "12121212", "21212121", "11223344", "44332211", "12341234", "43214321",
        "10101010", "01010101", "12002100", "13131313", "69696969",
        // Keypad walks.
        "14725836", "36925814", "15935780", "78945612", "95135780",
        // Dates people pick: 19xx/20xx years doubled, and common birth years.
        "19701970", "19801980", "19901990", "20002000", "20102010", "20202020",
        "01011990", "01012000", "12345678", "87654321",
    ]

    static func validate(_ pin: String) -> PinPolicyResult {
        // `count` over Characters is right here only because the numeric check
        // below rejects everything that is not an ASCII digit, so one Character
        // is one digit by the time length can be misread.
        if pin.count < minLength { return .tooShort }
        if pin.count > maxLength { return .tooLong }
        // `isASCII && isNumber`, not `isNumber` alone: Swift considers "٤" and
        // "𝟜" numbers, and neither survives the round trip through a digit
        // keypad or a PBKDF2 password the user has to retype.
        guard pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .notNumeric }
        if weakPins.contains(pin) { return .tooCommon }
        if isRun(pin) { return .tooCommon }
        return .valid
    }

    /// Catches the longer ascending/descending runs `weakPins` cannot
    /// enumerate once PINs may be up to `maxLength` digits (e.g. "23456789").
    private static func isRun(_ pin: String) -> Bool {
        let digits = pin.compactMap { $0.wholeNumberValue }
        guard digits.count == pin.count, digits.count > 1 else { return false }
        let deltas = zip(digits, digits.dropFirst()).map { $1 - $0 }
        return deltas.allSatisfy { $0 == 1 }
            || deltas.allSatisfy { $0 == -1 }
            || deltas.allSatisfy { $0 == 0 }
    }
}
