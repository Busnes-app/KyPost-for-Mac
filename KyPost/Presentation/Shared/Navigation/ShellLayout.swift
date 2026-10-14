//
//  ShellLayout.swift
//  KyPost
//
//  The iOS/iPadOS shell's wide-window decision and the rules that tie the
//  inbox list's presence to the Undo window. Pure values, so the whole
//  decision table is a plain unit test (`WideLayoutTests`).
//

import SwiftUI

/// How the iOS shell lays out Inbox and Contacts.
nonisolated enum ShellLayout: Hashable, Sendable {
    /// One column: list, then the message or contact pushed over it.
    case stack
    /// List and detail side by side (Inbox adds a collapsible folder sidebar).
    case split

    /// The narrowest window that splits, in points. Android's measured
    /// threshold (KyPost-for-Android 071d2b28, 800dp): a split hands the list
    /// roughly 40% of the window, so anything narrower gives an unfolded or
    /// rotated device a list narrower than the same device's phone layout.
    /// Measured here: iPhone Duo inner display 669 pt portrait / 951 pt
    /// landscape, cover 466 / 678; iPad mini 744 / 1133; iPad Pro 13-inch
    /// 1032 / 1376, half Split View in landscape 683.
    static let splitMinimumWidth: CGFloat = 800

    /// The layout for a window. The size class guards against a wide but
    /// compact window (none measured so far); the width decides.
    static func resolve(isRegularWidth: Bool, windowWidth: CGFloat) -> ShellLayout {
        isRegularWidth && windowWidth >= splitMinimumWidth ? .split : .stack
    }
}

/// Whether the inbox list is on screen, from the three things that hide it.
nonisolated struct InboxListPresence: Equatable, Sendable {
    var onInboxTab: Bool
    var layout: ShellLayout
    var messageOpen: Bool

    /// In the stack an open message covers the list; in the split it sits
    /// beside it.
    var isListOnScreen: Bool {
        onInboxTab && (layout == .split || !messageOpen)
    }

    /// What the list going away means for the inbox.
    enum Departure: Equatable, Sendable {
        /// The user left the list (another tab, or a message opened over it
        /// in the stack): held list actions commit, as on every leave.
        case left
        /// The window changed shape under the user. Nothing was left: held
        /// actions stay on their own timer and Undo stays available.
        case relaid
    }

    /// Nil while the list stays (or comes back) on screen.
    static func departure(from old: InboxListPresence, to new: InboxListPresence) -> Departure? {
        guard old.isListOnScreen, !new.isListOnScreen else { return nil }
        return old.layout == new.layout ? .left : .relaid
    }
}

extension EnvironmentValues {
    /// The iOS shell's current layout, for views that differ between the two
    /// (the reader hides the tab bar only when it covers the list).
    @Entry var shellLayout: ShellLayout = .stack
    /// Opens a compose in the iOS shell's own sheet. Nil outside that shell.
    @Entry var presentCompose: (@MainActor (ComposeDraft) -> Void)? = nil
}
