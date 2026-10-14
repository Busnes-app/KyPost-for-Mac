//
//  MailAccessGate.swift
//  KyPost
//
//  The startup-wipe gate, for windows other than the main one.
//

import Foundation

/// Whether mail may be shown or acted on outside the main window.
///
/// The main window holds everything behind `StartupGatePlaceholder` while
/// the startup wipe check runs, and behind `ManualRecoveryView` after an
/// abandoned wipe. A macOS pop-out reader is its own scene and macOS
/// restores it at launch, so it checks the same two things itself (App
/// AGENTS.md, entry points that guard the wipe state). The app lock is
/// separate: `LockedOverlay` and `AppLockManager.isLocked`.
@MainActor
enum MailAccessGate {
    static func isOpen() -> Bool {
        AppEnvironment.shared.startupWipeVerdict != .pending
            && !SingletonGraph.shared.securityWipe.blockedByAbandonedWipe
    }
}
