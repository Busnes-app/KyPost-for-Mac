//
//  ComposeParityTests.swift
//  KyPost Tests
//
//  Compose rules ported from kypost-android: the discard confirmation (#118),
//  the plain-text signature (#177), and mailto: links (#105).
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Signature

@Suite struct MailSignatureTests {
    @Test func aBlankSignatureLeavesTheBodyUntouched() {
        #expect(withSignature("\n\nOn Monday, Bob wrote:\n> hi", signature: "  \n ") == "\n\nOn Monday, Bob wrote:\n> hi")
    }

    /// RFC 3676: "-- " (with the space) on its own line, then the signature,
    /// and the quote after it.
    @Test func theSignatureGoesAfterTheDelimiterAndAboveTheQuote() {
        let body = withSignature("\n\nOn Monday, Bob wrote:\n> hi", signature: "Ada\nKyPost")
        #expect(body == "\n\n-- \nAda\nKyPost\n\nOn Monday, Bob wrote:\n> hi")
        #expect(withSignature("", signature: "Ada") == "\n\n-- \nAda")
    }

    @Test func theStoreTrimsCapsAndClears() {
        let store = MailSignatureStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        store.save("  Ada  \n")
        #expect(store.signature == "Ada")
        store.save(String(repeating: "x", count: MailSignatureStore.maxCharacters + 50))
        #expect(store.signature.count == MailSignatureStore.maxCharacters)
        store.save("   ")
        #expect(store.signature.isEmpty)
        store.save("Ada")
        store.clear()
        #expect(store.signature.isEmpty)
    }

    @Test func newRepliesAndForwardsGetTheSignature() {
        #expect(ComposeDraft().initialBody(signature: "Ada") == "\n\n-- \nAda")
        let reply = ComposeDraft(body: "\n\nOn Monday, Bob wrote:\n> hi")
        #expect(reply.initialBody(signature: "Ada").hasPrefix("\n\n-- \nAda\n\nOn Monday"))
    }

    /// Text another app asked to send is the message, not a quote: nothing
    /// goes above it. A blank external compose still gets one.
    @Test func externallySuppliedTextGetsNoSignatureAboveIt() {
        let shared = ComposeDraft(body: "Please see the attached.", bodyIsExternal: true)
        #expect(shared.initialBody(signature: "Ada") == "Please see the attached.")
        let blank = ComposeDraft(to: "a@example.com", body: " ", bodyIsExternal: true)
        #expect(blank.initialBody(signature: "Ada").contains("-- \nAda"))
    }

    /// A scene value archived before the flag existed restores as internal.
    @Test func anOlderArchivedDraftDecodesAsInternal() throws {
        let draft = try JSONDecoder().decode(ComposeDraft.self, from: Data(#"{"to":"a@example.com"}"#.utf8))
        #expect(!draft.bodyIsExternal)
    }

    @MainActor
    @Test func theSignatureClearsWithTheWipe() async throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let graph = try SingletonGraph(
            userDefaults: defaults,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
        graph.mailSignatureStore.save("Ada")
        let step = try #require(
            SecurityWipeSteps.build(graph: graph, defaultsDomain: nil).first { $0.name == "mailSignature" }
        )
        try await step.run()
        #expect(graph.mailSignatureStore.signature.isEmpty)
    }

    /// Branch-1 rule, asserted at the wipe: forwarded attachments waiting for
    /// their compose window are in-memory plaintext.
    @MainActor
    @Test func theInMemoryStepDropsAForwardsAttachments() async throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let graph = try SingletonGraph(
            userDefaults: defaults,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
        ForwardAttachmentHandoff.shared.put(
            [OutgoingAttachment(name: "a", mimeType: "text/plain", data: Data("a".utf8))],
            notice: nil,
            for: UUID()
        )
        let step = try #require(
            SecurityWipeSteps.build(graph: graph, defaultsDomain: nil).first { $0.name == "inMemoryPlaintext" }
        )
        try await step.run()
        #expect(!ForwardAttachmentHandoff.shared.isHoldingAttachments)
    }
}

// MARK: - Compose model

@MainActor
private func makeCompose(
    draft: ComposeDraft? = nil,
    signature: String = "",
    isLocked: @escaping () -> Bool = { false },
    bootstrap: String = "{}",
    onRequest: (@Sendable (URLRequest) -> Void)? = nil
) throws -> ComposeViewModel {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let pairingStore = try makePairedStore()
    let db = try AppDatabase(inMemory: true)
    let contacts = ContactsViewModel(repository: ContactSyncRepository(
        client: ContactSyncClient(httpClient: stubClient()),
        contactDAO: ContactDAO(modelContainer: db.container),
        cursorStore: ContactCursorStore(defaults: defaults),
        pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
        securePairingStore: pairingStore
    ), settingsStore: ContactsSettingsStore(defaults: defaults))
    return ComposeViewModel(
        sendEmail: SendEmailUseCase(repository: MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: #"{"ok": true}"#, onRequest: onRequest)
        )),
        contacts: contacts,
        pgp: PgpSendService(
            client: PgpSendClient(httpClient: stubClient(json: bootstrap, onRequest: onRequest)),
            securePairingStore: pairingStore
        ),
        draft: draft,
        signature: signature,
        isLocked: isLocked,
        debounceInterval: .zero
    )
}

@MainActor
@Suite struct ComposeDiscardTests {
    @Test func anUntouchedComposeClosesWithoutAsking() throws {
        #expect(try !makeCompose().closingNeedsConfirmation)
    }

    /// A signature-only body counts as content: a needless prompt costs one
    /// click, a wrong close costs the message.
    @Test func aSignatureOnlyBodyAsks() throws {
        #expect(try makeCompose(signature: "Ada").closingNeedsConfirmation)
    }

    @Test func anyTypedFieldAsks() throws {
        let subject = try makeCompose()
        subject.subject = "Hello"
        #expect(subject.closingNeedsConfirmation)

        let pending = try makeCompose()
        pending.ccInput = "half-typed@"
        #expect(pending.closingNeedsConfirmation)

        let recipients = try makeCompose(draft: ComposeDraft(to: "a@example.com"))
        #expect(recipients.closingNeedsConfirmation)

        let whitespace = try makeCompose()
        whitespace.body = AttributedString("  \n ")
        #expect(!whitespace.closingNeedsConfirmation)
    }

    /// A compose left open when the lock engaged sends nothing until unlock,
    /// and keeps the draft: the lock cover is not the control.
    @Test func nothingIsSentWhileLocked() async throws {
        let requests = Box<[URLRequest]>([])
        var locked = true
        let compose = try makeCompose(
            draft: ComposeDraft(to: "a@example.com", subject: "Hi", body: "Draft"),
            isLocked: { locked },
            onRequest: { request in requests.value = requests.value + [request] }
        )
        let traits: RichTextHTML.FontTraits = { _ in (false, false) }

        await compose.send(fontTraits: traits)
        await compose.handOffToWebmail(fontTraits: traits)
        await compose.saveDraft(fontTraits: traits)
        #expect(requests.value.isEmpty)
        #expect(!compose.didSend && !compose.isSent)
        #expect(compose.subject == "Hi")
        #expect(compose.closingNeedsConfirmation)

        locked = false
        await compose.send(fontTraits: traits)
        #expect(!requests.value.isEmpty)
        #expect(compose.didSend)
    }

    /// Save Draft checks the lock on entry and again right before upload, so
    /// a lock that engages in between still posts nothing.
    @Test func saveDraftPostsNothingWhileLocked() async throws {
        let posts = Box<[String]>([])
        let checks = Box(0)
        var lockAfter = 0
        let compose = try makeCompose(
            draft: ComposeDraft(to: "a@example.com", subject: "Hi", body: "Draft"),
            isLocked: {
                checks.mutate { $0 += 1 }
                return checks.value > lockAfter
            },
            bootstrap: #"{"hasIdentity":true,"protection":"server"}"#,
            onRequest: { request in
                let path = request.url?.path ?? ""
                if path == "/api/mail/draft" || path == "/api/mail/send" {
                    posts.mutate { $0.append(path) }
                }
            }
        )
        await compose.loadPgpIdentityIfNeeded()
        #expect(compose.draftSaveControls == .plain)
        let traits: RichTextHTML.FontTraits = { _ in (false, false) }

        // Locked on entry.
        await compose.saveDraft(fontTraits: traits)
        #expect(posts.value.isEmpty)

        // Unlocked on entry, locked by the re-check before upload.
        checks.value = 0
        lockAfter = 1
        await compose.saveDraft(fontTraits: traits)
        #expect(checks.value == 2)
        #expect(posts.value.isEmpty)
        #expect(!compose.didSaveDraft)
        #expect(compose.closingNeedsConfirmation)

        lockAfter = .max
        await compose.saveDraft(fontTraits: traits)
        #expect(posts.value == ["/api/mail/draft"])
        #expect(compose.didSaveDraft)
    }

    /// A saved draft is in Drafts: closing loses nothing.
    @Test func aSavedDraftClosesWithoutAsking() async throws {
        let compose = try makeCompose(
            draft: ComposeDraft(subject: "Hi"),
            bootstrap: #"{"hasIdentity":true,"protection":"server"}"#
        )
        await compose.loadPgpIdentityIfNeeded()
        #expect(compose.closingNeedsConfirmation)
        await compose.saveDraft(fontTraits: { _ in (false, false) })
        #expect(compose.didSaveDraft)
        #expect(!compose.closingNeedsConfirmation)
    }

    /// Markup in a signature reaches the editor as the characters typed.
    @Test func signatureMarkupIsShownNotInterpreted() throws {
        let compose = try makeCompose(signature: "<b>Ada</b> & co")
        #expect(String(compose.body.characters) == "\n\n-- \n<b>Ada</b> & co")
        #expect(compose.body.runs.count == 1)
    }
}

// MARK: - Blank subject

/// Send with no subject asks "Send without a subject?" instead of sending.
@MainActor
@Suite struct ComposeBlankSubjectTests {
    private let traits: RichTextHTML.FontTraits = { _ in (false, false) }

    /// `posts` collects the paths of every send or draft upload.
    private func makeBlankCompose(
        subject: String = "",
        posts: Box<[String]>,
        bootstrap: String = "{}"
    ) throws -> ComposeViewModel {
        try makeCompose(
            draft: ComposeDraft(to: "a@example.com", subject: subject, body: "Hello"),
            bootstrap: bootstrap,
            onRequest: { request in
                let path = request.url?.path ?? ""
                if path == "/api/mail/draft" || path == "/api/mail/send" {
                    posts.mutate { $0.append(path) }
                }
            }
        )
    }

    @Test(arguments: ["", "   ", " \n\t "])
    func aBlankSubjectAsksAndSendsNothing(subject: String) async throws {
        let posts = Box<[String]>([])
        let compose = try makeBlankCompose(subject: subject, posts: posts)

        await compose.send(fontTraits: traits)

        #expect(compose.confirmingBlankSubject)
        #expect(posts.value.isEmpty)
        #expect(!compose.didSend && !compose.isSending)
        #expect(compose.to.map(\.address) == ["a@example.com"])
    }

    @Test func aSubjectSendsWithoutAsking() async throws {
        let posts = Box<[String]>([])
        let compose = try makeBlankCompose(subject: "Hi", posts: posts)

        await compose.send(fontTraits: traits)

        #expect(!compose.confirmingBlankSubject)
        #expect(posts.value == ["/api/mail/send"])
        #expect(compose.didSend)
    }

    @Test func confirmingSendsItOnce() async throws {
        let posts = Box<[String]>([])
        let compose = try makeBlankCompose(posts: posts)

        await compose.send(fontTraits: traits)
        await compose.sendWithoutSubject(fontTraits: traits)

        #expect(!compose.confirmingBlankSubject)
        #expect(posts.value == ["/api/mail/send"])
        #expect(compose.didSend)
    }

    /// Add Subject sends nothing, and the confirmation is not remembered: a
    /// later Send with the subject still blank asks again.
    @Test func addSubjectSendsNothingAndTheNextSendAsksAgain() async throws {
        let posts = Box<[String]>([])
        let compose = try makeBlankCompose(posts: posts)

        await compose.send(fontTraits: traits)
        compose.cancelSendWithoutSubject()
        #expect(!compose.confirmingBlankSubject)
        #expect(posts.value.isEmpty)
        #expect(compose.closingNeedsConfirmation)

        await compose.send(fontTraits: traits)
        #expect(compose.confirmingBlankSubject)
        #expect(posts.value.isEmpty)

        compose.cancelSendWithoutSubject()
        compose.subject = "Hi"
        await compose.send(fontTraits: traits)
        #expect(posts.value == ["/api/mail/send"])
    }

    @Test func saveDraftNeverAsks() async throws {
        let posts = Box<[String]>([])
        let compose = try makeBlankCompose(
            posts: posts,
            bootstrap: #"{"hasIdentity":true,"protection":"server"}"#
        )
        await compose.loadPgpIdentityIfNeeded()

        await compose.saveDraft(fontTraits: traits)

        #expect(!compose.confirmingBlankSubject)
        #expect(posts.value == ["/api/mail/draft"])
        #expect(compose.didSaveDraft)
    }

    /// The dialog's Send is still a send: refused while locked.
    @Test func confirmingWhileLockedSendsNothing() async throws {
        let posts = Box<[String]>([])
        var locked = false
        let compose = try makeCompose(
            draft: ComposeDraft(to: "a@example.com", body: "Hello"),
            isLocked: { locked },
            onRequest: { request in
                if request.url?.path == "/api/mail/send" {
                    posts.mutate { $0.append("/api/mail/send") }
                }
            }
        )

        await compose.send(fontTraits: traits)
        #expect(compose.confirmingBlankSubject)
        locked = true
        await compose.sendWithoutSubject(fontTraits: traits)

        #expect(posts.value.isEmpty)
        #expect(!compose.didSend)
    }
}

// MARK: - mailto

@Suite struct MailtoLinkParserTests {
    private func parse(_ string: String) -> ComposeDraft? {
        URL(string: string).flatMap(MailtoLinkParser.parse)
    }

    @Test func everyFieldIsRead() throws {
        let draft = try #require(parse(
            "mailto:a@example.com,b@example.com?cc=c@example.com&bcc=d@example.com&subject=Hi%20there&body=Line%201%0D%0ALine%202&to=e@example.com"
        ))
        #expect(draft.to == "a@example.com,b@example.com, e@example.com")
        #expect(draft.cc == "c@example.com")
        #expect(draft.bcc == "d@example.com")
        #expect(draft.subject == "Hi there")
        #expect(draft.body == "Line 1\nLine 2")
        #expect(draft.bodyIsExternal)
    }

    /// Split before decoding: an encoded `&` or `=` inside a value is part of
    /// the value, not a separator.
    @Test func encodedSeparatorsStayInTheirValue() throws {
        let draft = try #require(parse("mailto:a@example.com?subject=Q%26A%3D1&body=x%3Dy%26z"))
        #expect(draft.subject == "Q&A=1")
        #expect(draft.body == "x=y&z")
    }

    @Test func keysAndSchemeAreCaseInsensitive() throws {
        let draft = try #require(parse("MAILTO:a@example.com?SUBJECT=Hi&Body=b"))
        #expect(draft.subject == "Hi")
        #expect(draft.body == "b")
    }

    /// RFC 6068 calls other headers unsafe; a web page does not get to set
    /// threading or the sender.
    @Test func unsafeHeadersAreIgnored() throws {
        let draft = try #require(parse("mailto:a@example.com?from=evil@example.com&in-reply-to=%3Cx%3E&subject=s"))
        #expect(draft.to == "a@example.com")
        #expect(draft.subject == "s")
    }

    /// One line per header field: a link cannot smuggle a line break or bidi
    /// override into the subject or an address.
    @Test func headerFieldsAreFlattened() throws {
        let draft = try #require(parse("mailto:a@example.com%0D%0ABcc:x@example.com?subject=a%0D%0Ab%E2%80%AEc"))
        #expect(draft.to == "a@example.com Bcc:x@example.com")
        #expect(draft.subject == "a b c")
    }

    @Test func markupInTheBodyStaysText() throws {
        let draft = try #require(parse("mailto:?body=%3Cscript%3Ealert(1)%3C/script%3E"))
        #expect(draft.to.isEmpty)
        #expect(draft.body == "<script>alert(1)</script>")
        #expect(draft.initialBody(signature: "Ada") == "<script>alert(1)</script>")
    }

    @Test func theBodyIsBounded() throws {
        let long = String(repeating: "a", count: MailtoLinkParser.maxBodyCharacters + 10)
        #expect(try #require(parse("mailto:?body=\(long)")).body.count == MailtoLinkParser.maxBodyCharacters)
    }

    @Test func otherSchemesAreNotMailto() {
        #expect(parse("https://example.com/?to=a@example.com") == nil)
        #expect(parse("kypost://native-pair?sub=a") == nil)
    }
}

@MainActor
@Suite struct MailtoRoutingTests {
    @Test func aMailtoLinkBecomesACompose() throws {
        let action = DeepLinkHandler().handle(try #require(URL(string: "mailto:a@example.com?subject=Hi")))
        guard case .composeMail(let draft) = action else {
            Issue.record("expected composeMail, got \(String(describing: action))")
            return
        }
        #expect(draft.to == "a@example.com")
    }

    /// The pairing scheme is untouched by the mailto route.
    @Test func pairingLinksStillPair() throws {
        let url = try #require(URL(string: "kypost://native-pair?sub=s&srv=https://relay.example.com&pt=t"))
        guard case .openPairingFlow = DeepLinkHandler().handle(url) else {
            Issue.record("pairing link no longer pairs")
            return
        }
    }

    /// Deferred while locked, like every other route; replayed on unlock.
    @Test func aComposeWaitsForTheLock() throws {
        var locked = true
        let router = NavigationRouter(notificationCenter: NotificationCenter())
        router.isLocked = { locked }
        router.handleURL(try #require(URL(string: "mailto:a@example.com")))
        #expect(router.composeRequest == nil)
        locked = false
        router.resumeDeferredAction()
        #expect(router.takeComposeRequest()?.to == "a@example.com")
        #expect(router.takeComposeRequest() == nil)
    }

    /// A link that arrives while a compose is on screen waits rather than
    /// replacing it, and opens once that compose closes.
    @Test func aSecondLinkWaitsForTheOpenCompose() throws {
        let router = NavigationRouter(notificationCenter: NotificationCenter())
        router.isLocked = { false }
        router.handleURL(try #require(URL(string: "mailto:first@example.com")))
        let first = try #require(router.takeComposeRequest(composeIsOpen: false))
        #expect(first.to == "first@example.com")

        router.handleURL(try #require(URL(string: "mailto:second@example.com")))
        #expect(router.takeComposeRequest(composeIsOpen: true) == nil)
        #expect(router.composeRequest?.to == "second@example.com")
        #expect(router.takeComposeRequest(composeIsOpen: false)?.to == "second@example.com")
        #expect(router.composeRequest == nil)
    }

    /// A wipe or unpair drops a compose deferred behind the lock.
    @Test func aSessionResetDropsADeferredCompose() throws {
        let center = NotificationCenter()
        let router = NavigationRouter(notificationCenter: center)
        router.isLocked = { true }
        router.handleURL(try #require(URL(string: "mailto:a@example.com")))
        center.post(name: .kyPostSessionReset, object: nil)
        router.isLocked = { false }
        router.resumeDeferredAction()
        #expect(router.composeRequest == nil)
    }
}
