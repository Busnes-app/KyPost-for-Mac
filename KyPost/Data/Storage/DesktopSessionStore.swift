//
//  DesktopSessionStore.swift
//  KyPost
//
//  What is left of desktop pairing (`kypost://desktop-pair`): the eraser.
//  Older builds exchanged a desktop pairing code for a session token and kept
//  it in the Keychain, but nothing ever sent it — mail, contacts and
//  notifications all authenticate with the native pairing
//  (`SecurePairingStore`). The flow is gone; a token an older build stored
//  is still removed by unpair, the security wipe and the failed-unlock reset.
//

import Foundation

final class DesktopSessionStore: Sendable {
    /// The Keychain accounts older builds wrote. Never written now.
    nonisolated static let legacyKeys = [
        "desktopSessionToken",
        "desktopSessionExpiresAt",
        "desktopSessionUserId",
        "desktopSessionUserEmail",
        "desktopSessionSrv",
        "desktopSessionPairedAt",
    ]

    private let keychain: KeychainStorage

    init(keychain: KeychainStorage) {
        self.keychain = keychain
    }

    /// Removes every legacy key. Each gets its own attempt; the first error
    /// still propagates, so a wipe reports what it could not remove.
    func clear() throws {
        var firstError: Error?
        for key in Self.legacyKeys {
            do {
                try keychain.remove(key)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}
