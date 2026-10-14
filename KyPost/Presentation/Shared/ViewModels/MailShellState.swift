//
//  MailShellState.swift
//  KyPost
//
//  What the iOS shell shows, held above the stack/split switch so rotating,
//  resizing a multitasking window, or folding a device does not lose it:
//  the open message (by its (folder, id) row), the open contact, select
//  mode, the search field, and the one compose sheet.
//
//  Scene memory only. The open message is the list row (metadata and the
//  cached body), never a decrypted body: plaintext stays in the reader's
//  `EncryptedReadViewModel` and dies with that view. Nothing here is stored
//  or restored, and the scene root's `.id(generation)` replaces it on a
//  wipe or Hostile Location Protection rebuild.
//

import Foundation
import Observation
import SwiftUI

/// The iOS compose sheet's content. One slot: iOS shows one compose at a
/// time, and a `mailto:` arriving meanwhile waits in the router.
enum ComposeSheet: Identifiable, Equatable {
    case blank(id: UUID)
    case draft(ComposeDraft)

    var id: UUID {
        switch self {
        case .blank(let id): id
        case .draft(let draft): draft.id
        }
    }

    var draft: ComposeDraft? {
        if case .draft(let draft) = self { draft } else { nil }
    }
}

@Observable
@MainActor
final class MailShellState {
    /// Set by the shell from the window's width; see `ShellLayout.resolve`.
    var layout: ShellLayout = .stack
    /// The message on screen — pushed in the stack, the detail in the split.
    var openEmail: Email?
    /// Selected rows by (folder, id); only meaningful while selecting.
    var selection: Set<MailRowKey> = []
    var isSelecting = false
    /// The search field. Plain memory: never stored or restored.
    var searchText = ""
    var isSearchPresented = false
    /// The contact on screen, by local id, so an edit or a sync re-reads it.
    var openContactID: UUID?
    var compose: ComposeSheet?
    /// List and reader; the folder sidebar opens from its toolbar button.
    /// `.automatic` hides the list behind the reader on a landscape phone.
    var inboxColumns: NavigationSplitViewVisibility = .doubleColumn

    var openKey: MailRowKey? { openEmail?.id }

    /// The columns a write leaves the split with. A split collapsing on its
    /// way out (rotating to the stack) writes `.detailOnly`, and the next
    /// split would open as the reader alone with no list; the list beside
    /// the reader is the point of the split, so that value is not kept.
    nonisolated static func keptColumns(
        _ requested: NavigationSplitViewVisibility
    ) -> NavigationSplitViewVisibility {
        requested == .detailOnly ? .doubleColumn : requested
    }

    /// Opens a row. A row tapped while selecting toggles instead.
    func open(_ email: Email) {
        guard !isSelecting else { return }
        openEmail = email
    }

    func closeMessage() {
        openEmail = nil
    }

    func beginSelection() {
        isSelecting = true
    }

    func endSelection() {
        selection = []
        isSelecting = false
    }

    /// A folder switch (picker, sidebar, notification tap, leaving the
    /// account) ends the selection and closes the message: both belong to
    /// the folder that was on screen.
    func folderChanged() {
        endSelection()
        openEmail = nil
    }

    /// The list's rows changed (a refresh, a held action, search results).
    /// Rows that left take their selection with them. In the split the
    /// detail follows the list, so a message no longer listed closes; in the
    /// stack it stays open over the list, as it always has.
    func listChanged(visible: [MailRowKey]) {
        let keys = Set(visible)
        selection.formIntersection(keys)
        if layout == .split, let openKey, !keys.contains(openKey) {
            openEmail = nil
        }
    }

    /// The account was forgotten (unpair, another account paired): nothing
    /// on screen may still show its mail or its contacts.
    func accountForgotten() {
        folderChanged()
        searchText = ""
        isSearchPresented = false
        openContactID = nil
    }

    /// The contact on screen was deleted (here, or by a sync): close it, or
    /// the stack would push an empty screen for it after a layout switch.
    func contactsChanged(present ids: Set<UUID>) {
        if let openContactID, !ids.contains(openContactID) {
            self.openContactID = nil
        }
    }

    /// The view model ended the search itself (folder switch, notification
    /// tap, leaving the account): the field clears and closes too.
    func searchDismissed() {
        searchText = ""
        isSearchPresented = false
    }
}
