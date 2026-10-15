//
//  KyPostCommands.swift
//  KyPost
//
//  macOS menu bar integration (spec Phase 7).
//

#if os(macOS)
import SwiftUI

struct KyPostCommands: Commands {
    let router: NavigationRouter

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.readerMessageCommands) private var readerCommands
    @FocusedValue(\.listMessageCommands) private var listCommands

    /// The Message menu's target in the key window; every item disabled when
    /// nothing is selected or open, the app is locked, or it is unpaired.
    private var message: MessageCommands {
        MessageCommands.resolve(
            reader: readerCommands,
            list: listCommands,
            // A pending startup wipe check or an abandoned wipe gates mail
            // like the lock does (`MailAccessGate`).
            isLocked: SingletonGraph.shared.appLockManager.isLocked || !MailAccessGate.isOpen(),
            isPaired: SingletonGraph.shared.securePairingStore.isPaired
        )
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About KyPost") {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Email") {
                openWindow(id: "compose")
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Mailbox") {
            // ⇧⌘N as in Apple Mail ("Get All New Mail"); ⌘R is Reply.
            Button("Refresh Inbox") {
                Task { await SingletonGraph.shared.inboxViewModel.refresh() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Sync Contacts") {
                Task { await SingletonGraph.shared.contactsViewModel.sync() }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Check Notifications Now") {
                Task { await SingletonGraph.shared.pullPollingScheduler.pollNow() }
            }
        }

        // Apple Mail's shortcuts. Delete carries no menu key equivalent on
        // purpose: a bare ⌫ here would fire while typing in the search field.
        // ⌫ reaches the list through `onDeleteCommand` and a reader through
        // its own handling (`EmailDetailView`). The relay has no "unread"
        // action, so there is no Mark as Unread.
        CommandMenu("Message") {
            item("Reply", message.reply)
                .keyboardShortcut("r")
            item("Reply All", message.replyAll)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            item("Forward", message.forward)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            item("Archive", message.archive)
                .keyboardShortcut("a", modifiers: [.command, .control])
            item("Move to Junk", message.junk)
                .keyboardShortcut("j", modifiers: [.command, .shift])
            item("Mark as Read", message.markRead)
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            item("Delete", message.delete)
        }
    }

    private func item(_ title: LocalizedStringKey, _ action: (() -> Void)?) -> some View {
        // Re-checked when chosen: a key equivalent can arrive before the
        // menu re-validates after the lock engages.
        Button(title) {
            guard !SingletonGraph.shared.appLockManager.isLocked, MailAccessGate.isOpen() else { return }
            action?()
        }
            .disabled(action == nil)
    }
}
#endif
