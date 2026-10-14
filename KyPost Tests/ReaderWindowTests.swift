//
//  ReaderWindowTests.swift
//  KyPost Tests
//
//  Reader windows that outlive the list (macOS pop-outs), reader failures
//  that reach the screen, and the Message menu's target.
//

import Foundation
import Testing
@testable import KyPost

@MainActor
private func makeViewModel(
    client: HTTPClient,
    windowGate: @escaping @MainActor () -> Bool = { true }
) throws -> InboxViewModel {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let db = try AppDatabase(inMemory: true)
    return InboxViewModel(
        mailRepository: MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        ),
        keywordRepository: KeywordRepository(settingsStore: KeywordSettingsStore(defaults: defaults)),
        windowGate: windowGate
    )
}

private func respond(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, URLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
}

/// INBOX holds message 1; every other folder is empty. Attachment downloads
/// and actions fail with a 500 when `failing` is set.
private func mailClient(failing: Bool = false, requests: Box<Int>? = nil) -> HTTPClient {
    HTTPClient { request in
        requests?.mutate { $0 += 1 }
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mailbox = query.first { $0.name == "mailbox" }?.value ?? "INBOX"
        if url.path.contains("api/mail/attachment") || url.path.contains("inbox/actions") || url.path.contains("folders") {
            return failing
                ? respond(request, 500, "imap unavailable")
                : respond(request, 200, #"{"ok": true, "processed": 1, "failed": []}"#)
        }
        if mailbox == "INBOX" {
            return respond(request, 200, #"{"byTab": {"": [{"messageId": "1", "subject": "Kept"}]}}"#)
        }
        return respond(request, 200, #"{"byTab": {}}"#)
    }
}

@Suite struct ReaderWindowTests {
    private let key = MailRowKey(folder: "INBOX", serverId: "1")

    /// The defect: the window read the main list, and a folder switch
    /// emptied the list, so every pop-out went blank.
    @Test @MainActor func aPopOutKeepsItsMessageAfterTheListSwitchesFolder() async throws {
        let viewModel = try makeViewModel(client: mailClient())
        await viewModel.load()
        let row = try #require(viewModel.email(for: key))
        viewModel.rememberForWindow(row)

        await viewModel.selectFolder("Archive")
        #expect(viewModel.email(for: key) == nil)

        let resolved = await viewModel.resolveEmail(for: key)
        #expect(resolved?.subject == "Kept")
    }

    /// A restored window (no list row, nothing remembered) finds its message
    /// in the cache.
    @Test @MainActor func aRestoredWindowResolvesFromTheCache() async throws {
        let viewModel = try makeViewModel(client: mailClient())
        await viewModel.load()
        await viewModel.selectFolder("Archive")

        let resolved = await viewModel.resolveEmail(for: key)
        #expect(resolved?.subject == "Kept")
        #expect(await viewModel.resolveEmail(for: MailRowKey(folder: "Archive", serverId: "1")) == nil)
    }

    /// A window macOS restores at launch must not show cached mail before
    /// the startup wipe check settles, or behind an abandoned wipe — the
    /// main window shows neither — and must not reach the relay meanwhile.
    @Test @MainActor func aShutGateResolvesNothingAndSendsNothing() async throws {
        let gateOpen = Box(true)
        let requests = Box(0)
        let viewModel = try makeViewModel(client: mailClient(requests: requests)) { gateOpen.value }
        await viewModel.load()
        let row = try #require(viewModel.email(for: key))
        viewModel.rememberForWindow(row)
        await viewModel.selectFolder("Archive")

        gateOpen.value = false
        let before = requests.value
        #expect(await viewModel.resolveEmail(for: key) == nil)
        #expect(requests.value == before)

        gateOpen.value = true
        #expect(await viewModel.resolveEmail(for: key)?.subject == "Kept")
    }

    /// A search result is never cached, so only the remembered row finds it —
    /// and forgetting the account forgets it.
    @Test @MainActor func rememberedRowsAreForgottenWithTheAccount() async throws {
        let viewModel = try makeViewModel(client: mailClient())
        let result = Email(
            serverId: "77", folder: "INBOX/Search", senderName: "S", senderEmail: "s@example.com",
            subject: "Found", body: "", keywords: [], receivedAt: Date(), read: false, starred: false
        )
        viewModel.rememberForWindow(result)
        #expect(await viewModel.resolveEmail(for: result.id)?.subject == "Found")

        viewModel.forgetAccount()
        #expect(await viewModel.resolveEmail(for: result.id) == nil)
    }
}

@Suite struct ReaderFailureTests {
    private let attachment = EmailAttachment(index: 1, name: "report.pdf", mimeType: "application/pdf", size: 10)

    private func row(_ viewModel: InboxViewModel) throws -> Email {
        try #require(viewModel.email(for: MailRowKey(folder: "INBOX", serverId: "1")))
    }

    /// A failed download used to land in `errorMessage`, which only renders
    /// over an empty list. It is now the reader's to say.
    @Test @MainActor func aFailedAttachmentIsASentenceForTheReader() async throws {
        let viewModel = try makeViewModel(client: mailClient())
        await viewModel.load()
        let email = try row(viewModel)
        let failing = try makeViewModel(client: mailClient(failing: true))

        await #expect(throws: ReaderFailure.self) {
            _ = try await failing.attachmentData(attachment, of: email)
        }
        do throws(ReaderFailure) {
            _ = try await failing.downloadAttachment(attachment, of: email)
            Issue.record("A failed download returned a file")
        } catch {
            #expect(error.message.hasPrefix("Couldn't download report.pdf."))
        }
        #expect(failing.errorMessage == nil)
    }

    @Test @MainActor func aFailedMarkReadIsSaidBothInTheReaderAndTheList() async throws {
        let viewModel = try makeViewModel(client: mailClient(failing: true))
        await viewModel.load()
        let email = try row(viewModel)

        await #expect(throws: ReaderFailure.self) { try await viewModel.markRead(email) }

        await viewModel.markRead(serverIds: ["1"])
        #expect(viewModel.notice?.hasPrefix("Couldn't mark as read.") == true)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func aRefusedFolderChangeIsAToast() async throws {
        let viewModel = try makeViewModel(client: mailClient(failing: true))
        await viewModel.load()
        await viewModel.createFolder(parent: "INBOX", name: "Receipts")
        #expect(viewModel.notice != nil)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.emails.isEmpty)
    }
}

@Suite struct MessageCommandsTests {
    /// Records which side ran.
    private final class Log { var entries: [String] = [] }

    private func commands(_ tag: String, _ log: Log) -> MessageCommands {
        MessageCommands(
            reply: { log.entries.append("\(tag).reply") },
            replyAll: { log.entries.append("\(tag).replyAll") },
            forward: { log.entries.append("\(tag).forward") },
            archive: { log.entries.append("\(tag).archive") },
            junk: { log.entries.append("\(tag).junk") },
            delete: { log.entries.append("\(tag).delete") },
            markRead: { log.entries.append("\(tag).markRead") }
        )
    }

    private func runAll(_ commands: MessageCommands) {
        for action in [
            commands.reply, commands.replyAll, commands.forward, commands.archive,
            commands.junk, commands.delete, commands.markRead,
        ] {
            action?()
        }
    }

    /// Composing from the reader (it knows the body and the quote rule);
    /// moving from the list, so it stays undoable.
    @Test func readerComposesAndTheListMoves() {
        let log = Log()
        let resolved = MessageCommands.resolve(
            reader: commands("reader", log), list: commands("list", log), isLocked: false, isPaired: true
        )
        runAll(resolved)
        #expect(log.entries == [
            "reader.reply", "reader.replyAll", "reader.forward",
            "list.archive", "list.junk", "list.delete", "list.markRead",
        ])
    }

    @Test func aPopOutActsOnItsOwnMessage() {
        let log = Log()
        let resolved = MessageCommands.resolve(
            reader: commands("reader", log), list: nil, isLocked: false, isPaired: true
        )
        runAll(resolved)
        #expect(log.entries.allSatisfy { $0.hasPrefix("reader.") })
        #expect(log.entries.count == 7)
    }

    @Test func everythingIsDisabledWhenLockedUnpairedOrWithNothingSelected() {
        let log = Log()
        for (locked, paired) in [(true, true), (false, false)] {
            let resolved = MessageCommands.resolve(
                reader: commands("reader", log), list: commands("list", log),
                isLocked: locked, isPaired: paired
            )
            runAll(resolved)
        }
        #expect(log.entries.isEmpty)
        let nothing = MessageCommands.resolve(reader: nil, list: nil, isLocked: false, isPaired: true)
        #expect(nothing.reply == nil && nothing.archive == nil && nothing.delete == nil && nothing.markRead == nil)
    }
}
