//
//  ComposeRecipientTests.swift
//  KyPost Tests
//
//  Compose's recipient tokens: draft parsing, duplicate rules, validation,
//  and the send-time flush (ContactAutocomplete.md §2, §4).
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Helpers




@MainActor
private struct Environment {
    var viewModel: ComposeViewModel
    var contacts: ContactsViewModel
}

/// A real graph on an in-memory store, seeded with `contacts`. `onSend`
/// captures the outgoing request body so tests can assert what actually went
/// out rather than what the model thinks it holds.
@MainActor
private func makeEnvironment(
    draft: ComposeDraft? = nil,
    contacts seed: [Contact] = [],
    onSend: (@Sendable (URLRequest) -> Void)? = nil
) async throws -> Environment {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let pairingStore = try makePairedStore()
    let db = try AppDatabase(inMemory: true)
    let dao = ContactDAO(modelContainer: db.container)
    if !seed.isEmpty {
        try await dao.upsert(contacts: seed)
    }
    let contactsViewModel = ContactsViewModel(repository: ContactSyncRepository(
        client: ContactSyncClient(httpClient: stubClient()),
        contactDAO: dao,
        cursorStore: ContactCursorStore(defaults: defaults),
        pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
        securePairingStore: pairingStore
    ), settingsStore: ContactsSettingsStore(defaults: defaults))
    await contactsViewModel.load()

    let sendEmail = SendEmailUseCase(repository: MailRepository(
        securePairingStore: pairingStore,
        emailDAO: EmailDAO(modelContainer: db.container),
        httpClient: stubClient(json: #"{"ok": true}"#, onRequest: onSend)
    ))
    return Environment(
        viewModel: ComposeViewModel(
            sendEmail: sendEmail,
            contacts: contactsViewModel,
            // Its own transport, never the send stub: `onSend` is a
            // last-write-wins capture, so sharing one would let a preflight
            // request overwrite the send these tests assert on.
            pgp: PgpSendService(
                client: PgpSendClient(httpClient: stubClient()),
                securePairingStore: pairingStore
            ),
            draft: draft,
            isLocked: { false },
            debounceInterval: .zero
        ),
        contacts: contactsViewModel
    )
}

/// Resolves bold/italic without a view environment; compose passes the real
/// one. Nothing here tests formatting.
private let plainTraits: RichTextHTML.FontTraits = { _ in (false, false) }

// MARK: - Draft parsing

@MainActor
@Suite("Compose draft to tokens")
struct ComposeDraftTokenTests {
    @Test func parsesEachFieldIntoTokens() async throws {
        let env = try await makeEnvironment(
            draft: ComposeDraft(to: "a@x.com", cc: "b@y.com", bcc: "c@z.com")
        )

        #expect(env.viewModel.to.map(\.address) == ["a@x.com"])
        #expect(env.viewModel.cc.map(\.address) == ["b@y.com"])
        #expect(env.viewModel.bcc.map(\.address) == ["c@z.com"])
    }

    @Test func resolvesKnownAddressesToContacts() async throws {
        let alice = makeContact("Alice Chen", "alice@x.com")
        let env = try await makeEnvironment(
            draft: ComposeDraft(to: "alice@x.com, stranger@y.com"),
            contacts: [alice]
        )

        #expect(env.viewModel.to[0].displayName == "Alice Chen")
        #expect(env.viewModel.to[0].contactId == alice.localId)
        #expect(env.viewModel.to[1].displayName == nil)
        #expect(env.viewModel.to[1].contactId == nil)
    }

    @Test func resolvesRegardlessOfAddressCase() async throws {
        let env = try await makeEnvironment(
            draft: ComposeDraft(to: "ALICE@X.com"),
            contacts: [makeContact("Alice Chen", "alice@x.com")]
        )

        #expect(env.viewModel.to[0].displayName == "Alice Chen")
    }

    @Test func keepsTheNameFromAHeaderWhenTheContactIsUnknown() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "Bob <bob@x.com>"))

        #expect(env.viewModel.to[0].displayName == "Bob")
        #expect(env.viewModel.to[0].contactId == nil)
    }

    /// ComposeDraft.reply falls back to the sender's name when an email
    /// carries no sender address. That isn't address-shaped, but dropping it
    /// would empty the To field with no sign anything was there.
    @Test func keepsUnparseableHeadersAsTokens() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "Bob Smith"))

        #expect(env.viewModel.to.map(\.address) == ["Bob Smith"])
    }

    @Test func ignoresEmptyHeaders() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "   "))

        #expect(env.viewModel.to.isEmpty)
    }
}

// MARK: - ComposeDraft coding

@Suite("ComposeDraft coding")
struct ComposeDraftCodingTests {
    /// macOS hands ComposeDraft to a WindowGroup as a scene value, so a draft
    /// archived before `bcc` existed must still restore.
    @Test func decodesArchivesWrittenWithoutBcc() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","to":"a@x.com","cc":"","subject":"Hi","body":"B"}"#
        let draft = try JSONDecoder().decode(ComposeDraft.self, from: Data(legacy.utf8))

        #expect(draft.to == "a@x.com")
        #expect(draft.bcc == "")
        #expect(draft.subject == "Hi")
    }

    @Test func roundTripsThroughCoding() throws {
        let draft = ComposeDraft(to: "a@x.com", cc: "b@x.com", bcc: "c@x.com", subject: "S", body: "B")
        let decoded = try JSONDecoder().decode(
            ComposeDraft.self,
            from: JSONEncoder().encode(draft)
        )

        #expect(decoded == draft)
    }

    @Test func replyAllStillCollectsOtherRecipients() {
        var email = Email(
            serverId: "1",
            folder: "INBOX",
            senderName: "Sender",
            senderEmail: "sender@x.com",
            subject: "Hi",
            body: "Body",
            keywords: [],
            receivedAt: Date(),
            read: false,
            starred: false
        )
        email.sentTo = "me@x.com, Other <other@x.com>"
        email.cc = "third@x.com"
        let draft = ComposeDraft.replyAll(to: email, ownAddress: "me@x.com")

        #expect(draft.to == "sender@x.com")
        #expect(draft.cc == "other@x.com, third@x.com")
    }
}

// MARK: - Adding and removing

@MainActor
@Suite("Compose recipient editing")
struct ComposeRecipientEditingTests {
    @Test func ignoresDuplicatesAcrossFieldsAndToasts() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "a@x.com"))
        let added = env.viewModel.add(RecipientToken(address: "a@x.com"), to: .cc)

        #expect(!added)
        #expect(env.viewModel.cc.isEmpty)
        #expect(env.viewModel.toastMessage != nil)
    }

    @Test func duplicateDetectionIgnoresCase() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "a@x.com"))
        env.viewModel.add(RecipientToken(address: "A@X.com"), to: .to)

        #expect(env.viewModel.to.count == 1)
    }

    @Test func commitsTypedAddresses() async throws {
        let env = try await makeEnvironment()
        env.viewModel.toInput = "new@x.com"

        #expect(env.viewModel.commitPendingInput(for: .to))
        #expect(env.viewModel.to.map(\.address) == ["new@x.com"])
        #expect(env.viewModel.toInput.isEmpty)
    }

    @Test func commitsSeveralAddressesAtOnce() async throws {
        let env = try await makeEnvironment()
        env.viewModel.toInput = "a@x.com, b@y.com"
        env.viewModel.commitPendingInput(for: .to)

        #expect(env.viewModel.to.map(\.address) == ["a@x.com", "b@y.com"])
    }

    @Test func rejectsInvalidTypedText() async throws {
        let env = try await makeEnvironment()
        env.viewModel.toInput = "not-an-address"

        #expect(!env.viewModel.commitPendingInput(for: .to))
        #expect(env.viewModel.to.isEmpty)
        #expect(env.viewModel.errorMessage != nil)
        // The text stays put so the user can fix it rather than retype it.
        #expect(env.viewModel.toInput == "not-an-address")
    }

    /// Blur runs a commit, but a half-typed search term isn't a mistake worth
    /// an error — send() is where bad text gets called out.
    @Test func blurCommitStaysQuietOnPartialText() async throws {
        let env = try await makeEnvironment()
        env.viewModel.toInput = "al"

        #expect(!env.viewModel.commitPendingInput(for: .to, reportingErrors: false))
        #expect(env.viewModel.errorMessage == nil)
        #expect(env.viewModel.toInput == "al")
    }

    @Test func committingEmptyInputIsANoOp() async throws {
        let env = try await makeEnvironment()

        #expect(env.viewModel.commitPendingInput(for: .to))
        #expect(env.viewModel.to.isEmpty)
        #expect(env.viewModel.errorMessage == nil)
    }

    @Test func removesTokens() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "a@x.com, b@x.com"))
        env.viewModel.remove(env.viewModel.to[0], from: .to)

        #expect(env.viewModel.to.map(\.address) == ["b@x.com"])
    }

}

// MARK: - Suggestions

@MainActor
@Suite("Compose suggestions")
struct ComposeSuggestionTests {
    /// The search runs in a detached Task, so even at a zero debounce the
    /// result lands a scheduling hop later. Poll rather than sleep a fixed
    /// span, which goes flaky the moment the machine is busy.
    private func waitForSuggestions(_ viewModel: ComposeViewModel) async throws {
        for _ in 0..<200 where viewModel.suggestions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func suggestsMatchingContacts() async throws {
        let env = try await makeEnvironment(contacts: [
            makeContact("Alice Chen", "alice@x.com"),
            makeContact("Bob Stone", "bob@x.com"),
        ])
        env.viewModel.toInput = "ali"
        env.viewModel.updateSuggestions(for: .to)
        try await waitForSuggestions(env.viewModel)

        #expect(env.viewModel.suggestions.map(\.entry.address) == ["alice@x.com"])
        #expect(env.viewModel.suggestionsField == .to)
    }

    @Test func emptyInputClosesTheDropdown() async throws {
        let env = try await makeEnvironment(contacts: [makeContact("Alice", "alice@x.com")])
        env.viewModel.toInput = ""
        env.viewModel.updateSuggestions(for: .to)

        #expect(env.viewModel.suggestions.isEmpty)
        #expect(env.viewModel.suggestionsField == nil)
    }

    @Test func selectingASuggestionTokenizesAndCloses() async throws {
        let alice = makeContact("Alice Chen", "alice@x.com")
        let env = try await makeEnvironment(contacts: [alice])
        env.viewModel.toInput = "ali"
        env.viewModel.updateSuggestions(for: .to)
        try await waitForSuggestions(env.viewModel)
        let match = try #require(env.viewModel.suggestions.first)
        env.viewModel.selectSuggestion(match, for: .to)

        #expect(env.viewModel.to.map(\.address) == ["alice@x.com"])
        #expect(env.viewModel.to[0].contactId == alice.localId)
        #expect(env.viewModel.toInput.isEmpty)
        #expect(env.viewModel.suggestions.isEmpty)
    }
}

// MARK: - Sending

@MainActor
@Suite("Compose send")
struct ComposeSendTests {
    /// The relay takes each header as one comma-joined string
    /// (RelaySendRequest), so this splits it back apart to assert on.
    private func sentRecipients(from request: URLRequest) throws -> [String: [String]] {
        let body = try #require(request.httpBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        func addresses(_ key: String) -> [String] {
            (json[key] as? String ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return ["to": addresses("to"), "cc": addresses("cc"), "bcc": addresses("bcc")]
    }

    /// The regression test for silent recipient loss: typing an address and
    /// hitting ⌘↩ without pressing Return first must still mail it.
    @Test func flushesTypedInputBeforeSending() async throws {
        let captured = Box<URLRequest?>(nil)
        let env = try await makeEnvironment(onSend: { captured.value = $0 })
        env.viewModel.toInput = "typed@x.com"
        env.viewModel.subject = "Hi"
        await env.viewModel.send(fontTraits: plainTraits)

        let request = try #require(captured.value)
        #expect(try sentRecipients(from: request)["to"] == ["typed@x.com"])
        #expect(env.viewModel.didSend)
    }

    @Test func sendsBareAddressesNotDisplayNames() async throws {
        let captured = Box<URLRequest?>(nil)
        let env = try await makeEnvironment(
            draft: ComposeDraft(to: "alice@x.com", cc: "b@y.com", bcc: "c@z.com", subject: "Hi"),
            contacts: [makeContact("Alice Chen", "alice@x.com")],
            onSend: { captured.value = $0 }
        )
        await env.viewModel.send(fontTraits: plainTraits)

        let sent = try sentRecipients(from: try #require(captured.value))
        #expect(sent["to"] == ["alice@x.com"])
        #expect(sent["cc"] == ["b@y.com"])
        #expect(sent["bcc"] == ["c@z.com"])
    }

    @Test func refusesToSendWithInvalidTypedText() async throws {
        let env = try await makeEnvironment(draft: ComposeDraft(to: "a@x.com", subject: "Hi"))
        env.viewModel.ccInput = "garbage"
        await env.viewModel.send(fontTraits: plainTraits)

        #expect(!env.viewModel.didSend)
        #expect(env.viewModel.errorMessage != nil)
    }
}

