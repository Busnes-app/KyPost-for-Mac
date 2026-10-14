//
//  MessageCommands.swift
//  KyPost
//
//  What the macOS Message menu (KyPostCommands) acts on: the focused
//  window's reader and its list, published as focused scene values.
//

import SwiftUI

/// The Message menu's actions for one window. A nil action is a disabled
/// item, so "nothing selected" needs no separate flag.
struct MessageCommands {
    var reply: (() -> Void)?
    var replyAll: (() -> Void)?
    var forward: (() -> Void)?
    var archive: (() -> Void)?
    var junk: (() -> Void)?
    var delete: (() -> Void)?
    var markRead: (() -> Void)?

    /// Every item disabled.
    static let none = MessageCommands()

    /// The one set the menu shows, from the focused window's reader (the
    /// preview pane or a pop-out) and its list.
    ///
    /// Reply, Reply All and Forward come from the reader when there is one:
    /// it knows whether the body has arrived and whether the message may be
    /// quoted at all. Archive, Junk, Delete and Mark as Read come from the
    /// list when there is one, so they are held for Undo like the list's own
    /// buttons; a pop-out has no list and acts at once, like its toolbar.
    /// Nothing at all while the app is locked or unpaired.
    static func resolve(
        reader: MessageCommands?,
        list: MessageCommands?,
        isLocked: Bool,
        isPaired: Bool
    ) -> MessageCommands {
        guard !isLocked, isPaired else { return .none }
        return MessageCommands(
            reply: reader?.reply ?? list?.reply,
            replyAll: reader?.replyAll ?? list?.replyAll,
            forward: reader?.forward ?? list?.forward,
            archive: list?.archive ?? reader?.archive,
            junk: list?.junk ?? reader?.junk,
            delete: list?.delete ?? reader?.delete,
            markRead: list?.markRead ?? reader?.markRead
        )
    }
}

extension FocusedValues {
    /// Published by `EmailDetailView`.
    @Entry var readerMessageCommands: MessageCommands?
    /// Published by the macOS mail list (`MacRootView`).
    @Entry var listMessageCommands: MessageCommands?
}
