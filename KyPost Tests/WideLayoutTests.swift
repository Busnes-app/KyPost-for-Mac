//
//  WideLayoutTests.swift
//  KyPost Tests
//
//  The iOS widescreen layout: when a window splits (`ShellLayout`), what a
//  layout switch keeps (`MailShellState`), and which disappearances of the
//  inbox list commit held Undo actions (`InboxListPresence`,
//  `InboxViewModel.leaveInbox(commitsHeldActions:)`).
//

import Foundation
import SwiftUI
import Testing
@testable import KyPost

private func mail(_ id: String, in folder: String = "INBOX") -> Email {
    Email(serverId: id, folder: folder, senderName: "", senderEmail: "", subject: id, body: "",
          keywords: [], receivedAt: Date(), read: false, starred: false)
}

private func key(_ id: String, in folder: String = "INBOX") -> MailRowKey {
    MailRowKey(folder: folder, serverId: id)
}

// MARK: - When the window splits

@Suite struct ShellLayoutTests {
    /// Window widths in points, measured on the simulators this layout was
    /// checked on (see `ShellLayout.splitMinimumWidth`).
    @Test(arguments: [
        // iPhone Duo cover screen, portrait and landscape.
        (466.0, false, .stack),
        (678.0, false, .stack),
        // iPhone Duo inner display: book (portrait) stays a stack so
        // unfolding never narrows the list; rotated it splits.
        (669.0, true, .stack),
        (951.0, true, .split),
        // iPad mini, portrait and landscape.
        (744.0, true, .stack),
        (1133.0, true, .split),
        // iPad Pro 13-inch, portrait, landscape, and half a landscape
        // Split View.
        (1032.0, true, .split),
        (1376.0, true, .split),
        (683.0, true, .stack),
        // iPhone 18 Pro Max: portrait is compact; landscape is regular and
        // wide enough.
        (440.0, false, .stack),
        (956.0, true, .split),
    ] as [(Double, Bool, ShellLayout)])
    func eachMeasuredWindow(width: Double, regular: Bool, expected: ShellLayout) {
        #expect(ShellLayout.resolve(isRegularWidth: regular, windowWidth: CGFloat(width)) == expected)
    }

    @Test func theThresholdIsInclusiveAndAndroids() {
        #expect(ShellLayout.splitMinimumWidth == 800)
        #expect(ShellLayout.resolve(isRegularWidth: true, windowWidth: 800) == .split)
        #expect(ShellLayout.resolve(isRegularWidth: true, windowWidth: 799.5) == .stack)
    }

    @Test func aCompactWindowNeverSplitsHoweverWide() {
        #expect(ShellLayout.resolve(isRegularWidth: false, windowWidth: 1400) == .stack)
    }

    @Test func composeGoesTwoColumnAtAndroidsWidth() {
        #expect(ComposeView.twoColumnMinimumWidth == 600)
    }
}

// MARK: - When leaving the list commits held actions

@Suite struct InboxListPresenceTests {
    private func presence(
        tab: Bool = true, _ layout: ShellLayout, open: Bool = false
    ) -> InboxListPresence {
        InboxListPresence(onInboxTab: tab, layout: layout, messageOpen: open)
    }

    @Test func switchingTabsLeavesTheListInEitherLayout() {
        #expect(InboxListPresence.departure(from: presence(.stack), to: presence(tab: false, .stack)) == .left)
        #expect(InboxListPresence.departure(from: presence(.split), to: presence(tab: false, .split)) == .left)
    }

    @Test func openingAMessageLeavesTheListOnlyInTheStack() {
        #expect(InboxListPresence.departure(from: presence(.stack), to: presence(.stack, open: true)) == .left)
        #expect(InboxListPresence.departure(from: presence(.split), to: presence(.split, open: true)) == nil)
        #expect(presence(.split, open: true).isListOnScreen)
    }

    @Test func aLayoutSwitchThatHidesTheListIsNotLeavingIt() {
        // Reading in the split, then folding or rotating to the stack: the
        // reader now covers the list, but the user did not leave it.
        #expect(InboxListPresence.departure(
            from: presence(.split, open: true), to: presence(.stack, open: true)
        ) == .relaid)
    }

    @Test func theListComingBackIsNoDeparture() {
        #expect(InboxListPresence.departure(
            from: presence(.stack, open: true), to: presence(.split, open: true)
        ) == nil)
        #expect(InboxListPresence.departure(from: presence(.stack), to: presence(.split)) == nil)
        #expect(InboxListPresence.departure(from: presence(.split), to: presence(.stack)) == nil)
        #expect(InboxListPresence.departure(
            from: presence(tab: false, .stack), to: presence(.stack)
        ) == nil)
    }
}

// MARK: - What a layout switch keeps

@MainActor
@Suite struct MailShellStateTests {
    /// Everything the shell shows, set up as a user mid-task would have it.
    private func busyShell(_ layout: ShellLayout) -> MailShellState {
        let shell = MailShellState()
        shell.layout = layout
        shell.open(mail("7", in: "Archive"))
        shell.searchText = "invoice"
        shell.isSearchPresented = true
        shell.openContactID = UUID()
        shell.compose = .draft(ComposeDraft(to: "a@example.com", subject: "Hi"))
        return shell
    }

    @Test(arguments: [(.split, .stack), (.stack, .split)] as [(ShellLayout, ShellLayout)])
    func aLayoutSwitchKeepsEverything(from: ShellLayout, to: ShellLayout) {
        let shell = busyShell(from)
        let contact = shell.openContactID
        let compose = shell.compose
        shell.layout = to
        #expect(shell.openKey == key("7", in: "Archive"))
        #expect(shell.searchText == "invoice")
        #expect(shell.isSearchPresented)
        #expect(shell.openContactID == contact)
        #expect(shell.compose == compose)
    }

    @Test(arguments: [.split, .stack] as [ShellLayout])
    func selectModeAndItsRowsSurviveASwitch(from: ShellLayout) {
        let shell = MailShellState()
        shell.layout = from
        shell.beginSelection()
        shell.selection = [key("1"), key("2", in: "Junk")]
        shell.layout = from == .split ? .stack : .split
        #expect(shell.isSelecting)
        #expect(shell.selection == [key("1"), key("2", in: "Junk")])
    }

    @Test func theOpenMessageIsItsFolderAndId() {
        let shell = MailShellState()
        shell.layout = .split
        shell.open(mail("42", in: "Sent"))
        // The same id in INBOX is a different message: the reader closes.
        shell.listChanged(visible: [key("42", in: "INBOX")])
        #expect(shell.openEmail == nil)

        shell.open(mail("42", in: "Sent"))
        shell.listChanged(visible: [key("42", in: "Sent")])
        #expect(shell.openKey == key("42", in: "Sent"))
    }

    @Test func aRowTappedWhileSelectingDoesNotOpen() {
        let shell = MailShellState()
        shell.beginSelection()
        shell.open(mail("1"))
        #expect(shell.openEmail == nil)
    }

    @Test func theSplitsDetailFollowsTheListAndTheStacksReaderStays() {
        let split = MailShellState()
        split.layout = .split
        split.open(mail("1"))
        split.listChanged(visible: [key("2")])
        #expect(split.openEmail == nil)

        let stack = MailShellState()
        stack.open(mail("1"))
        stack.listChanged(visible: [key("2")])
        #expect(stack.openKey == key("1"))
    }

    @Test func rowsThatLeaveTheListLeaveTheSelection() {
        let shell = MailShellState()
        shell.beginSelection()
        shell.selection = [key("1"), key("2")]
        shell.listChanged(visible: [key("2"), key("3")])
        #expect(shell.selection == [key("2")])
        #expect(shell.isSelecting)
    }

    @Test func aFolderSwitchClosesTheMessageAndEndsTheSelection() {
        let shell = busyShell(.split)
        shell.beginSelection()
        shell.selection = [key("1")]
        shell.folderChanged()
        #expect(shell.openEmail == nil)
        #expect(!shell.isSelecting)
        #expect(shell.selection.isEmpty)
        // The compose being written is not the folder's.
        #expect(shell.compose != nil)
    }

    @Test func leavingTheAccountClearsWhatItShowed() {
        let shell = busyShell(.stack)
        shell.accountForgotten()
        #expect(shell.openEmail == nil)
        #expect(shell.searchText.isEmpty)
        #expect(!shell.isSearchPresented)
        #expect(shell.openContactID == nil)
    }

    @Test func theViewModelEndingTheSearchClearsTheField() {
        let shell = busyShell(.split)
        shell.searchDismissed()
        #expect(shell.searchText.isEmpty)
        #expect(!shell.isSearchPresented)
        #expect(shell.openKey == key("7", in: "Archive"))
    }

    @Test func aDeletedContactClosesSoTheStackPushesNothingForIt() {
        let shell = MailShellState()
        let kept = UUID()
        shell.openContactID = kept
        shell.contactsChanged(present: [kept, UUID()])
        #expect(shell.openContactID == kept)
        shell.contactsChanged(present: [UUID()])
        #expect(shell.openContactID == nil)
    }

    @Test func composeSheetsKeepTheirDraftAndIdentity() {
        let draft = ComposeDraft(to: "a@example.com")
        #expect(ComposeSheet.draft(draft).id == draft.id)
        #expect(ComposeSheet.draft(draft).draft == draft)
        #expect(ComposeSheet.blank(id: UUID()).draft == nil)
    }
}

// MARK: - The Undo window across a layout switch

@MainActor
@Suite struct LayoutSwitchUndoTests {
    private func makeInbox(relay: FakeInboxRelay, undoWindow: Duration) throws -> InboxViewModel {
        let db = try AppDatabase(inMemory: true)
        let repository = MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: relay.client
        )
        return InboxViewModel(
            mailRepository: repository,
            keywordRepository: KeywordRepository(settingsStore: KeywordSettingsStore(
                defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
            )),
            undoWindow: undoWindow
        )
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aRelayoutKeepsHeldActionsUndoableAndOnTheirTimer() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2"]]
        let viewModel = try makeInbox(relay: relay, undoWindow: .milliseconds(400))
        await viewModel.load()

        viewModel.archive(serverIds: ["1"])
        viewModel.leaveInbox(commitsHeldActions: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(relay.actionCount == 0)
        #expect(viewModel.undoMessage != nil)

        // Still the user's to take back after the switch...
        viewModel.undoHeldActions()
        #expect(viewModel.filteredEmails.map(\.serverId) == ["1", "2"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(relay.actionCount == 0)

        // ...and, left alone, sent once by the window's own timer.
        viewModel.delete(serverIds: ["2"])
        viewModel.leaveInbox(commitsHeldActions: false)
        #expect(await eventually { relay.actionCount == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(relay.actionCount == 1)
    }

    @Test func leavingTheListStillCommitsAtOnce() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1"]]
        let viewModel = try makeInbox(relay: relay, undoWindow: .seconds(5))
        await viewModel.load()

        viewModel.archive(serverIds: ["1"])
        viewModel.leaveInbox()
        #expect(await eventually { relay.actionCount == 1 })
        #expect(viewModel.undoMessage == nil)
    }

    @Test func forgettingTheAccountIsObservableToTheShell() throws {
        let viewModel = try makeInbox(relay: FakeInboxRelay(), undoWindow: .seconds(5))
        let before = viewModel.accountGeneration
        viewModel.forgetAccount()
        #expect(viewModel.accountGeneration == before + 1)
    }
}
