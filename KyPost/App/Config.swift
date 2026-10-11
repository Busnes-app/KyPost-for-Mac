//
//  Config.swift
//  KyPost
//
//  App-wide constants. Values marked "binding contract" must match the
//  Android reference implementation exactly (spec §DOX).
//

import Foundation

enum Config {
    // Binding contract: deep-link scheme is exactly kypost://native-pair.
    nonisolated static let deepLinkScheme = "kypost"
    static let pairingHost = "native-pair"

    // Desktop pairing (Desktop Pairing guide): kypost://desktop-pair?code=…&srv=…
    static let desktopPairingHost = "desktop-pair"
    /// Pairing codes are 32 characters (16 random bytes, hex-encoded).
    static let desktopPairingCodeLength = 32

    static let defaultFolder = "INBOX"

    /// Foreground refresh cadence for keyword tabs and pull-mode polling (spec §2, §3).
    static let foregroundRefreshInterval: TimeInterval = 90

    /// iOS background pull task (spec §3: ~15 min platform minimum).
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let backgroundPullTaskId = "org.kysecurity.mail.pull"
    static let backgroundPullInterval: TimeInterval = 15 * 60

    // Binding contract: theme names match web theme.ts / Android AppTheme.kt.
    static let defaultThemeName = "Dark Matter"
}
