//
//  MailTests.swift
//  KyPost Tests
//
//  Phase 3 tests: relay source mapping, comma-string send contract, keyword
//  tab computation, mode-aware repository, send use-case validation.
//

import Foundation
import SwiftData
import SwiftUI
import Testing
import WebKit
@testable import KyPost

// MARK: - Helpers


private let auth = RelayAuth(deviceId: "u1", deviceSecret: "h1")

private func makeEmail(serverId: String, keywords: Set<String>) -> Email {
    Email(
        serverId: serverId,
        folder: "INBOX",
        senderName: "S",
        senderEmail: "s@example.com",
        subject: "Subject",
        body: "Body",
        keywords: keywords,
        receivedAt: Date(),
        read: false,
        starred: false
    )
}

private func makeOutgoing(
    to: [String] = ["a@x.com", "b@x.com"],
    cc: [String] = ["c@x.com"],
    bcc: [String] = []
) -> OutgoingEmail {
    OutgoingEmail(to: to, cc: cc, bcc: bcc, subject: "Hi", body: "Hello there")
}

// MARK: - Comma-string send contract

@Suite struct RelaySendRequestTests {
    @Test func recipientsAreCommaJoinedStrings() throws {
        let request = RelaySendRequest(from: makeOutgoing())
        #expect(request.to == "a@x.com, b@x.com")
        #expect(request.cc == "c@x.com")
        #expect(request.bcc == "")
        #expect(request.mode == "plain")

        // Binding contract (Mobile_Mail_Relay.md Part 6): strings in the
        // JSON, not arrays, plus a "mode" field.
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["to"] as? String == "a@x.com, b@x.com")
        #expect(object["cc"] as? String == "c@x.com")
        #expect(object["mode"] as? String == "plain")
    }
}

// MARK: - RelayMailSource

@Suite struct RelayMailSourceTests {
    @Test func fetchEmailsMapsByTabResponse() async throws {
        // Shape from Mobile_Mail_Relay.md / Android RelayModels.kt.
        let json = """
        {
          "tabs": ["Work", "Personal"],
          "byTab": {
            "Work": [
              {
                "messageId": "e-1",
                "sender": "Ada Lovelace <ada@example.com>",
                "subject": "Report",
                "body": "The report",
                "label": "Important",
                "status": "read",
                "atUtc": "2025-06-15T15:06:40Z"
              }
            ],
            "Personal": [
              { "messageId": "e-2", "subject": "Bare minimum" }
            ]
          },
          "cursor": 1750000000,
          "delta": false,
          "removed": []
        }
        """
        let client = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/inbox?"))
            #expect(!url.contains("sub="))
            #expect(!url.contains("hash="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(url.contains("mailbox=INBOX"))
            #expect(url.contains("limit=50"))
            #expect(url.contains("since=0"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        let emails = try await source.fetchEmails(folder: "INBOX", from: 0, to: 50).emails

        #expect(emails.count == 2)
        let full = try #require(emails.first { $0.serverId == "e-1" })
        #expect(full.senderName == "Ada Lovelace")
        #expect(full.senderEmail == "ada@example.com")
        #expect(full.keywords == ["Important"]) // label wins over tab
        #expect(full.read) // any status but "unread"
        #expect(full.receivedAt == Date(timeIntervalSince1970: 1_750_000_000))

        let bare = try #require(emails.first { $0.serverId == "e-2" })
        #expect(bare.keywords == ["Personal"]) // falls back to its tab
        #expect(!bare.read) // status defaults to unread
    }

    @Test func fetchEmailsSortsNewestFirstAcrossTabs() async throws {
        // byTab is a dictionary with no stable iteration order; the flattened
        // list must come back sorted by date regardless of tab grouping.
        let json = """
        {
          "tabs": ["Work", "Personal"],
          "byTab": {
            "Work": [
              { "messageId": "old", "atUtc": "2025-01-01T00:00:00Z" },
              { "messageId": "newest", "atUtc": "2025-03-01T00:00:00Z" }
            ],
            "Personal": [
              { "messageId": "middle", "atUtc": "2025-02-01T00:00:00Z" }
            ]
          }
        }
        """
        let source = RelayMailSource(httpClient: stubClient(json: json), serverUrl: server, auth: auth)
        let emails = try await source.fetchEmails(folder: "INBOX", from: 0, to: 50).emails
        #expect(emails.map(\.serverId) == ["newest", "middle", "old"])
    }

    @Test func numericCursorDecodes() throws {
        // Some deployments emit cursor as a bare number, others as a string.
        let numeric = try JSONDecoder().decode(
            RelayInboxResponse.self,
            from: Data(#"{"cursor": 42}"#.utf8)
        )
        #expect(numeric.cursor == FlexibleCursor("42"))
        let string = try JSONDecoder().decode(
            RelayInboxResponse.self,
            from: Data(#"{"cursor": "42"}"#.utf8)
        )
        #expect(string.cursor == FlexibleCursor("42"))
    }

    @Test func listFoldersMapsPath() async throws {
        let json = #"{"parent": "", "folders": [{"path": "INBOX"}, {"path": "Archive", "deletable": true}]}"#
        let foldersClient = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url == "\(server)/api/inbox/folders")
            #expect(!url.contains("parent="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        }
        let folders = try await RelayMailSource(httpClient: foldersClient, serverUrl: server, auth: auth)
            .listFolders()
        #expect(folders.map(\.name) == ["INBOX", "Archive"])

        // Subfolder listing scopes the request with the parent param.
        let subJson = #"{"parent": "Archive", "folders": [{"path": "Archive/Receipts", "deletable": true}]}"#
        let subClient = stubClient(json: subJson) { request in
            #expect(request.url!.absoluteString.contains("parent=Archive"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
        }
        let subs = try await RelayMailSource(httpClient: subClient, serverUrl: server, auth: auth)
            .listFolders(parent: "Archive")
        #expect(subs.map(\.name) == ["Archive/Receipts"])
    }

    @Test func movePostsBulkActionBody() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/inbox/actions")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""action":"move""#))
            #expect(body.contains(#""messageIds":["e-1","e-2"]"#))
            #expect(body.contains(#""mailbox":"INBOX""#))
            #expect(body.contains(#""targetMailbox":"Archive\/2026""#))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.move(messageIds: ["e-1", "e-2"], from: "INBOX", to: "Archive/2026")
    }

    @Test func deletePostsBulkActionBodyWithoutTarget() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/inbox/actions")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""action":"delete""#))
            #expect(body.contains(#""messageIds":["e-1","e-2"]"#))
            #expect(body.contains(#""mailbox":"Trash""#))
            // targetMailbox is move-only; nil must be omitted, not null.
            #expect(!body.contains("targetMailbox"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.delete(messageIds: ["e-1", "e-2"], mailbox: "Trash")
    }

    @Test(arguments: [
        ("archive", { try await $0.archive(messageIds: ["e-1"], mailbox: "INBOX") }),
        ("spam", { try await $0.markSpam(messageIds: ["e-1"], mailbox: "INBOX") }),
        ("read", { try await $0.markRead(messageIds: ["e-1"], mailbox: "INBOX") }),
    ] as [(String, @Sendable (RelayMailSource) async throws -> Void)])
    func actionVerbsPostBulkActionBody(
        verb: String,
        call: @Sendable (RelayMailSource) async throws -> Void
    ) async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/inbox/actions")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""action":"\#(verb)""#))
            #expect(body.contains(#""messageIds":["e-1"]"#))
            #expect(body.contains(#""mailbox":"INBOX""#))
            #expect(!body.contains("targetMailbox"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await call(source)
    }

    @Test func sendPostsCommaStringBody() async throws {
        let client = stubClient(json: #"{"ok": true, "sentSaved": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/mail/send")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""to":"a@x.com, b@x.com""#))
            #expect(body.contains(#""mode":"plain""#))
            // No attachments → the key is omitted entirely, not null/[].
            #expect(!body.contains("attachments"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.send(email: makeOutgoing())
    }

    @Test func sendEncodesModeAndBase64Attachments() throws {
        var email = makeOutgoing()
        email.mode = "html"
        email.attachments = [OutgoingAttachment(
            name: "a.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )]
        let request = RelaySendRequest(from: email)
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mode"] as? String == "html")
        let attachments = try #require(object["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["name"] as? String == "a.txt")
        #expect(attachments[0]["mimeType"] as? String == "text/plain")
        #expect(attachments[0]["dataBase64"] as? String == Data("hello".utf8).base64EncodedString())
    }

    @Test func plaintextSendOmitsThePgpFlagsEntirely() throws {
        let data = try JSONEncoder().encode(RelaySendRequest(from: makeOutgoing()))
        let body = String(decoding: data, as: UTF8.self)
        // A plaintext send must look exactly as it did before encryption
        // existed; the relay defaults all three to false.
        #expect(!body.contains("encrypt"))
        #expect(!body.contains("sign"))
        #expect(!body.contains("allowPickupFallback"))
    }

    @Test func encryptedSendCarriesTheFlagsItWasGiven() throws {
        var email = makeOutgoing()
        email.encrypt = true
        email.sign = true
        let object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(RelaySendRequest(from: email))
        ) as? [String: Any])
        #expect(object["encrypt"] as? Bool == true)
        #expect(object["sign"] as? Bool == true)
        // Not consented to yet: the first send always asks without it.
        #expect(object["allowPickupFallback"] == nil)
    }

    /// allowPickupFallback is meaningful only with encrypt, so it never travels
    /// on a plaintext send even if something set it.
    @Test func pickupFallbackNeedsEncrypt() throws {
        var email = makeOutgoing()
        email.allowPickupFallback = true
        let plain = String(decoding: try JSONEncoder().encode(RelaySendRequest(from: email)), as: UTF8.self)
        #expect(!plain.contains("allowPickupFallback"))

        email.encrypt = true
        let encrypted = String(decoding: try JSONEncoder().encode(RelaySendRequest(from: email)), as: UTF8.self)
        #expect(encrypted.contains(#""allowPickupFallback":true"#))
    }

    @Test func sendReturnsTheRelayWarning() async throws {
        let json = #"{"ok": true, "sentSaved": false, "warning": "failed to deliver a pickup link to 1 of 3 recipient(s)"}"#
        let source = RelayMailSource(httpClient: stubClient(json: json), serverUrl: server, auth: auth)
        let warning = try await source.send(email: makeOutgoing())
        #expect(warning == "failed to deliver a pickup link to 1 of 3 recipient(s)")
    }

    @Test func aCleanSendHasNoWarning() async throws {
        let source = RelayMailSource(
            httpClient: stubClient(json: #"{"ok": true, "sentSaved": true, "warning": ""}"#),
            serverUrl: server,
            auth: auth
        )
        #expect(try await source.send(email: makeOutgoing()) == "")
        // Absent, not just empty.
        let terse = RelayMailSource(
            httpClient: stubClient(json: #"{"ok": true}"#),
            serverUrl: server,
            auth: auth
        )
        #expect(try await terse.send(email: makeOutgoing()) == "")
    }

    @Test func listAttachmentsMapsMetadata() async throws {
        let json = #"{"ok": true, "attachments": [{"index": 0, "name": "report.pdf", "mimeType": "application/pdf", "size": 1234}, {"index": 1}]}"#
        let client = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/mail/attachments?"))
            #expect(url.contains("mailbox=INBOX"))
            #expect(url.contains("messageId=42"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        let attachments = try await source.listAttachments(folder: "INBOX", messageId: "42")

        #expect(attachments.count == 2)
        #expect(attachments[0] == EmailAttachment(
            index: 0, name: "report.pdf", mimeType: "application/pdf", size: 1234
        ))
        // Missing fields get safe fallbacks.
        #expect(attachments[1] == EmailAttachment(
            index: 1, name: "attachment", mimeType: "application/octet-stream", size: 0
        ))
    }

    @Test func downloadAttachmentReturnsRawBytes() async throws {
        let client = stubClient(json: "raw-bytes") { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/mail/attachment?"))
            #expect(url.contains("messageId=42"))
            #expect(url.contains("index=1"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        let data = try await source.downloadAttachment(folder: "INBOX", messageId: "42", index: 1)
        #expect(String(decoding: data, as: UTF8.self) == "raw-bytes")
    }

    @Test func saveDraftPostsTheSendShapeWithoutPgpFields() async throws {
        var email = makeOutgoing()
        email.encrypt = true
        email.sign = true
        email.allowPickupFallback = true
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/mail/draft")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""to":"a@x.com, b@x.com""#))
            #expect(body.contains(#""mode":"plain""#))
            // A draft has no PGP semantics; the server would ignore them and
            // sending them invites confusion.
            #expect(!body.contains("encrypt"))
            #expect(!body.contains("sign"))
            #expect(!body.contains("allowPickupFallback"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.saveDraft(email: email)
    }

    @Test func saveDraftSurfacesAPlainTextFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 500, json: "could not save draft"),
            serverUrl: server,
            auth: auth
        )
        await #expect(throws: NetworkError.server(statusCode: 500)) {
            try await source.saveDraft(email: makeOutgoing())
        }
    }
}

// MARK: - Rich text → HTML (compose mode:"html")

@Suite struct RichTextHTMLTests {
    /// Fake trait resolver so tests don't need a font resolution context.
    private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }
    private let allBold: RichTextHTML.FontTraits = { _ in (true, false) }

    @Test func escapesMarkupCharacters() {
        #expect(RichTextHTML.escape(#"<a href="x">&"#) == "&lt;a href=&quot;x&quot;&gt;&amp;")
    }

    @Test func plainTextHasNoFormatting() {
        let text = AttributedString("just words\ntwo lines")
        #expect(!RichTextHTML.hasFormatting(text, fontTraits: noTraits))
        // Fonts resolve to regular → still plain even with a font attribute.
        var fonted = AttributedString("styled?")
        fonted.font = .body
        #expect(!RichTextHTML.hasFormatting(fonted, fontTraits: noTraits))
    }

    @Test func underlineAndBoldCountAsFormatting() {
        var underlined = AttributedString("hello")
        underlined.underlineStyle = .single
        #expect(RichTextHTML.hasFormatting(underlined, fontTraits: noTraits))

        var fonted = AttributedString("hello")
        fonted.font = .body
        #expect(RichTextHTML.hasFormatting(fonted, fontTraits: allBold))
    }

    @Test func htmlDocumentWrapsAndTagsRuns() {
        var text = AttributedString("plain ")
        var bold = AttributedString("bold&co")
        bold.font = .body
        var underlined = AttributedString(" under\nline")
        underlined.underlineStyle = .single
        text += bold
        text += underlined

        let html = RichTextHTML.htmlDocument(from: text) { _ in (true, false) }
        #expect(html.hasPrefix("<html><body>"))
        #expect(html.hasSuffix("</body></html>"))
        // The unfonted runs also resolve bold here, so just check the tagged
        // pieces landed with escaping and <br> conversion intact.
        #expect(html.contains("<strong>bold&amp;co</strong>"))
        #expect(html.contains("<u>"))
        #expect(html.contains("<br>"))
    }

    @Test func linksBecomeAnchors() {
        var text = AttributedString("llama")
        text.link = URL(string: "https://mail.urlxl.com/x?a=1&b=2")
        let html = RichTextHTML.htmlDocument(from: text, fontTraits: noTraits)
        #expect(html.contains(#"<a href="https://mail.urlxl.com/x?a=1&amp;b=2">llama</a>"#))
    }
}

// MARK: - Email HTML rendering hardening (WebView JS / remote content)

@MainActor
@Suite struct EmailBodyWebViewConfigurationTests {
    @Test func javaScriptIsAlwaysDisabledRegardlessOfRemoteContentSetting() {
        #expect(
            EmailBodyWebView.makeConfiguration(allowsRemoteContent: false)
                .defaultNavigationPreferences.allowsContentJavaScript == false
        )
        #expect(
            EmailBodyWebView.makeConfiguration(allowsRemoteContent: true)
                .defaultNavigationPreferences.allowsContentJavaScript == false
        )
    }

    @Test func remoteContentIsBlockedByDefaultAndOnlyLoadsWhenExplicitlyAllowed() {
        #expect(EmailBodyWebView.makeConfiguration(allowsRemoteContent: false).loadsSubresources == false)
        #expect(EmailBodyWebView.makeConfiguration(allowsRemoteContent: true).loadsSubresources == true)
    }
}

// MARK: - Email body navigation policy (default-deny)

@MainActor
@Suite struct EmailBodyNavigationPolicyTests {
    private func policy(_ urlString: String, isLink: Bool = false) -> EmailBodyWebView.BodyNavigation {
        EmailBodyWebView.navigationPolicy(url: URL(string: urlString), isLinkActivation: isLink)
    }

    @Test func theMessageDocumentItselfLoads() {
        #expect(policy("about:blank") == .allow)
    }

    @Test func linkTapsOpenInTheBrowserAndNeverInTheReader() {
        let url = URL(string: "https://example.com/thread")!
        #expect(policy(url.absoluteString, isLink: true) == .openInBrowser(url))
    }

    /// The bypass this closes: a meta refresh is plain HTML and a main-frame
    /// navigation, so neither `allowsContentJavaScript = false` nor
    /// `loadsSubresources = false` touches it. Allowing everything that isn't
    /// a link tap would let a message beacon home on open, straight past the
    /// blocked-remote-content banner.
    @Test func aRedirectTheUserNeverClickedIsBlocked() {
        #expect(policy("https://tracker.example/beacon?id=victim") == .block)
    }

    @Test func aFormPostToAnArbitraryHostIsBlocked() {
        #expect(policy("https://tracker.example/collect") == .block)
    }

    @Test func aNavigationWithNoURLIsBlocked() {
        #expect(EmailBodyWebView.navigationPolicy(url: nil, isLinkActivation: false) == .block)
        #expect(EmailBodyWebView.navigationPolicy(url: nil, isLinkActivation: true) == .block)
    }
}

// MARK: - Attachment cache path sanitization

@MainActor
@Suite struct InboxViewModelAttachmentCachePathTests {
    @Test func acceptsAnOrdinaryServerId() {
        #expect(InboxViewModel.sanitizedCacheComponent("e-1") == "e-1")
    }

    @Test(arguments: [
        "",
        "../../Library/Preferences/evil",
        "..",
        "sub/dir",
        "null\0byte",
    ])
    func rejectsPathTraversalAndSeparators(value: String) {
        #expect(InboxViewModel.sanitizedCacheComponent(value) == nil)
    }
}

// MARK: - MailOutcome mapping

@Suite struct MailOutcomeTests {
    @Test func errorMapping() {
        #expect(MailOutcome.from(NetworkError.unauthorized) == .unauthorized)
        #expect(MailOutcome.from(MailSourceError.notPaired) == .notPaired)
        if case .failure = MailOutcome.from(NetworkError.serviceUnavailable) {} else {
            Issue.record("503 should map to failure")
        }
    }
}

// MARK: - The relay's two PGP 409s

@Suite struct RelayConflictTests {
    /// Discrimination is by field. The prose is user-facing copy and may be
    /// reworded at any time.
    @Test func clientSideNeededIsRecognisedByItsField() {
        #expect(RelayMailSource.conflictError(
            body: #"{"error":"end-to-end protected","clientSideNeeded":true}"#
        ) == .clientSideNeeded)
    }

    @Test func keylessRecipientsCarriesTheAddressesAndTheFallbackFlag() {
        let body = """
        {"error": "some recipients have no usable PGP key; sending them a one-time link stores this message's plaintext on the server for 7 days",
         "keylessRecipients": ["bob@example.com", "carol@example.com"],
         "pickupFallbackAvailable": true}
        """
        #expect(RelayMailSource.conflictError(body: body) == .keylessRecipients(
            addresses: ["bob@example.com", "carol@example.com"],
            pickupFallbackAvailable: true
        ))
    }

    /// A server with pickup links turned off refuses and offers nothing.
    @Test func aKeylessConflictWithoutTheFallbackFlagIsNotOfferable() {
        let body = #"{"keylessRecipients":["bob@example.com"]}"#
        #expect(RelayMailSource.conflictError(body: body) == .keylessRecipients(
            addresses: ["bob@example.com"],
            pickupFallbackAvailable: false
        ))
    }

    /// A 409 carrying neither field must not inherit PGP wording.
    @Test func anOrdinaryConflictMapsToNoPgpError() {
        #expect(RelayMailSource.conflictError(body: #"{"error":"duplicate"}"#) == nil)
        #expect(RelayMailSource.conflictError(body: #"{"clientSideNeeded":false}"#) == nil)
        #expect(RelayMailSource.conflictError(body: #"{"keylessRecipients":[]}"#) == nil)
    }

    /// Every non-409 error body is plain text, and a 409 body may still be
    /// malformed. Decoding must never trap.
    @Test func aMalformedConflictBodyDoesNotCrash() {
        #expect(RelayMailSource.conflictError(body: "") == nil)
        #expect(RelayMailSource.conflictError(body: "failed to send email: dial tcp") == nil)
        #expect(RelayMailSource.conflictError(body: #"{"keylessRecipients":"bob@example.com"}"#) == nil)
        #expect(RelayMailSource.conflictError(body: "[1,2,3]") == nil)
    }

    @Test func sendMapsTheClientSideConflictToItsOwnOutcome() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"clientSideNeeded":true}"#),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .clientSideNeeded)
    }

    @Test func sendMapsTheKeylessConflictToItsOwnOutcome() async {
        let json = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: json),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .keylessRecipients(
            addresses: ["bob@example.com"],
            pickupFallbackAvailable: true
        ))
    }

    @Test func anUnrelatedConflictStaysAGenericFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"error":"duplicate"}"#),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .clientSideNeeded          // must be overwritten
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should still throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        if case .failure = outcome {} else {
            Issue.record("an ordinary 409 should be a generic failure, got \(outcome)")
        }
    }
}

// MARK: - Keyword tabs

@Suite struct KeywordRepositoryTests {
    private let emails = [
        makeEmail(serverId: "1", keywords: ["Work", "Important"]),
        makeEmail(serverId: "2", keywords: ["work happens later alphabetically", "Work"]),
        makeEmail(serverId: "3", keywords: []),
    ]

    @Test func computeTabsIsUniqueSortedWithCounts() {
        let tabs = KeywordRepository.computeTabs(from: emails)
        #expect(tabs.map(\.name) == ["Important", "Work", "work happens later alphabetically"])
        #expect(tabs.first { $0.name == "Work" }?.count == 2)
        #expect(tabs.first { $0.name == "Important" }?.count == 1)
    }

    @Test func visibleTabsRespectsVisibilityStore() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let repository = KeywordRepository(settingsStore: KeywordSettingsStore(defaults: defaults))

        #expect(repository.visibleTabs(from: emails).count == 3)
        repository.setVisible(false, for: "Work")
        #expect(repository.visibleTabs(from: emails).map(\.name)
                == ["Important", "work happens later alphabetically"])

        // Settings list still includes hidden keywords, flagged invisible.
        let settings = repository.allSettings(from: emails)
        #expect(settings.first { $0.name == "Work" }?.visible == false)
    }

    @Test func savedOrderDrivesTabsAndSettings() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let repository = KeywordRepository(settingsStore: KeywordSettingsStore(defaults: defaults))
        repository.setOrder(["Work", "Important"])

        #expect(repository.visibleTabs(from: emails).map(\.name)
                == ["Work", "Important", "work happens later alphabetically"])
        #expect(repository.allSettings(from: emails).map(\.name)
                == ["Work", "Important", "work happens later alphabetically"])
    }
}

// MARK: - MailRepository

@Suite struct MailRepositoryTests {
    private func makeRepository(
        client: HTTPClient,
        paired: Bool
    ) throws -> MailRepository {
        let pairingStore = try makePairedStore(paired: paired)
        let db = try AppDatabase(inMemory: true)
        return MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        )
    }

    @Test func withoutPairingIsNotPaired() throws {
        let repository = try makeRepository(client: stubClient(), paired: false)
        #expect(throws: MailSourceError.notPaired) {
            _ = try repository.makeSource()
        }
    }

    @Test func refreshFolderCachesSnapshot() async throws {
        let json = #"{"byTab": {"Work": [{"messageId": "e-1", "subject": "Cached"}]}}"#
        let repository = try makeRepository(client: stubClient(json: json), paired: true)

        let fetched = try await repository.refreshFolder("INBOX")
        #expect(fetched.count == 1)

        let cached = try await repository.cachedFolder("INBOX")
        #expect(cached.map(\.serverId) == ["e-1"])
        #expect(cached.first?.subject == "Cached")
    }

    @Test func sendWithoutPairingIsNotPaired() async throws {
        let repository = try makeRepository(client: stubClient(), paired: false)
        let outcome = await repository.send(makeOutgoing())
        #expect(outcome == .notPaired)
    }

    @Test func saveDraftIsSuccessAndNeedsAPairing() async throws {
        let paired = try makeRepository(client: stubClient(json: #"{"ok": true}"#), paired: true)
        #expect(await paired.saveDraft(makeOutgoing()) == .success)
        #expect(paired.pairedServerUrl == server)

        let unpaired = try makeRepository(client: stubClient(), paired: false)
        #expect(await unpaired.saveDraft(makeOutgoing()) == .notPaired)
        #expect(unpaired.pairedServerUrl == nil)
    }
}

// MARK: - SendEmailUseCase

@Suite struct SendEmailUseCaseTests {
    private func makeUseCase(client: HTTPClient) throws -> SendEmailUseCase {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        return SendEmailUseCase(repository: MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        ))
    }

    @Test func rejectsEmptyRecipients() async throws {
        let send = try makeUseCase(client: stubClient())
        let outcome = await send(makeOutgoing(to: [], cc: [], bcc: []))
        #expect(outcome == .invalid("Add at least one recipient"))
    }

    @Test func rejectsMalformedAddresses() async throws {
        let send = try makeUseCase(client: stubClient())
        let outcome = await send(makeOutgoing(to: ["not-an-address"], cc: [], bcc: []))
        #expect(outcome == .invalid("Check the recipient addresses"))
    }

    @Test func sendsValidEmail() async throws {
        let send = try makeUseCase(client: stubClient(json: #"{"ok": true}"#))
        let outcome = await send(makeOutgoing())
        #expect(outcome == .success)
    }

    @Test func rejectsOversizedAttachments() async throws {
        let send = try makeUseCase(client: stubClient(json: #"{"ok": true}"#))
        var email = makeOutgoing()
        // Two 13 MB files cross the 25 MB budget (backend maxMailAttachmentBytes).
        let big = Data(count: 13 << 20)
        email.attachments = [
            OutgoingAttachment(name: "one", mimeType: "application/octet-stream", data: big),
            OutgoingAttachment(name: "two", mimeType: "application/octet-stream", data: big),
        ]
        let outcome = await send(email)
        #expect(outcome == .invalid("Attachments too large (max 25 MB total)"))
    }

    @Test func addressShapeCheck() {
        #expect(SendEmailUseCase.looksLikeEmailAddress("a@b.co"))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("a@b"))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("@b.co"))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("a@b."))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("a@@b.co"))
    }
}

// MARK: - PGP field wire contract

@Suite struct RelayEmailPgpFieldTests {
    /// The server marks all five pgp* fields omitempty, so absent means "no
    /// OpenPGP content" — the decoded defaults ARE the contract, not an
    /// unknown state.
    @Test func absentPgpFieldsDecodeToFalseAndEmpty() throws {
        let json = """
        {"messageId":"1","sender":"a@x.com","subject":"Hi","body":"Hello"}
        """
        let dto = try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
        let email = dto.toDomain(folder: "INBOX", tab: "")

        #expect(email.pgpEncrypted == false)
        #expect(email.pgpSigned == false)
        #expect(email.pgpVerified == false)
        #expect(email.pgpSignerFingerprint == "")
        #expect(email.pgpDecryptError == "")
    }

    @Test func presentPgpFieldsAreCarriedIntoTheDomainModel() throws {
        let json = """
        {"messageId":"2","subject":"Secret","body":"",
         "pgpEncrypted":true,"pgpSigned":true,"pgpVerified":false,
         "pgpSignerFingerprint":"ABCD1234","pgpDecryptError":"no key"}
        """
        let dto = try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
        let email = dto.toDomain(folder: "INBOX", tab: "")

        #expect(email.pgpEncrypted)
        #expect(email.pgpSigned)
        #expect(email.pgpVerified == false)
        #expect(email.pgpSignerFingerprint == "ABCD1234")
        #expect(email.pgpDecryptError == "no key")
    }

    @Test func pgpFieldsSurviveTheRoundTripThroughPersistence() {
        let email = Email(
            serverId: "3",
            folder: "INBOX",
            senderName: "S",
            senderEmail: "s@example.com",
            subject: "Subject",
            body: "",
            keywords: [],
            receivedAt: Date(),
            read: false,
            starred: false,
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true,
            pgpSignerFingerprint: "FEED",
            pgpDecryptError: ""
        )
        let restored = EmailEntity(from: email).toDomain

        #expect(restored.pgpEncrypted)
        #expect(restored.pgpSigned)
        #expect(restored.pgpVerified)
        #expect(restored.pgpSignerFingerprint == "FEED")
        #expect(restored.pgpDecryptError == "")
    }
}

// MARK: - Partial-success warnings

@Suite struct SendWarningTests {
    /// A warning means the message *was* sent. It must never look like a
    /// failure, and must never offer a retry that would duplicate it.
    @Test func aWarningIsSuccessNotFailure() async throws {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let json = #"{"ok": true, "sentSaved": false, "warning": "sent copy not saved"}"#
        let repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: json)
        )

        let outcome = await repository.send(makeOutgoing())
        #expect(outcome == .sentWithWarning("sent copy not saved"))
    }

    @Test func noWarningIsPlainSuccess() async throws {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: #"{"ok": true, "sentSaved": true, "warning": ""}"#)
        )
        #expect(await repository.send(makeOutgoing()) == .success)
    }
}

// MARK: - Generated link schemes

/// Escaping the attribute value stops it breaking out of the quotes and does
/// nothing about the scheme. This app is the *sender* of the HTML it builds, so
/// a `javascript:` or `data:text/html` href would have been an active payload
/// shipped under the user's own address, left for the recipient's client to
/// clean up.
@Suite struct RichTextHTMLLinkSchemeTests {
    private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }

    private func linked(_ urlString: String) -> AttributedString {
        var text = AttributedString("click")
        text.link = URL(string: urlString)
        return text
    }

    @Test func safeSchemesKeepTheirAnchor() {
        for scheme in ["https://example.com/a", "http://example.com/a", "mailto:a@example.com"] {
            let html = RichTextHTML.htmlDocument(from: linked(scheme), fontTraits: noTraits)
            #expect(html.contains("<a href="), "expected an anchor for \(scheme)")
        }
    }

    @Test func activeSchemesLoseTheAnchorButKeepTheText() {
        for scheme in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "vbscript:msgbox(1)",
            "file:///etc/passwd",
        ] {
            let html = RichTextHTML.htmlDocument(from: linked(scheme), fontTraits: noTraits)
            #expect(!html.contains("<a href="), "expected no anchor for \(scheme)")
            #expect(html.contains("click"), "expected the text to survive for \(scheme)")
        }
    }

    /// A draft whose only "formatting" is a link the converter drops should
    /// still send as plain, not as an HTML document with nothing in it.
    @Test func aDroppedLinkDoesNotCountAsFormatting() {
        #expect(!RichTextHTML.hasFormatting(linked("javascript:alert(1)"), fontTraits: noTraits))
        #expect(RichTextHTML.hasFormatting(linked("https://example.com"), fontTraits: noTraits))
    }
}

// MARK: - Body rendering (bodyMode)

@Suite struct EmailBodyRenderingTests {
    @Test func honoursADeclaredPlainModeOverTheBodyContent() {
        // The point of carrying bodyMode: a plain-text message that happens to
        // contain angle brackets must not be rendered as markup.
        let body = "See <div> in the spec, and use <p> sparingly."
        #expect(isPlainTextBody(body, mode: "plain"))
        #expect(emailBodyToHTML(body, mode: "plain").contains("&lt;div&gt;"))
        #expect(!emailBodyToHTML(body, mode: "plain").contains("<div>"))
    }

    @Test func honoursADeclaredHtmlModeWithoutSniffing() {
        // A real HTML message that opens with text still converts verbatim.
        let body = "Hello there.<p>Second paragraph.</p>"
        #expect(emailBodyToHTML(body, mode: "html") == body)
    }

    @Test func sniffsOnlyWhenTheServerDidNotSayAnything() {
        let markup = "<p>Hi</p>"
        let text = "Just a sentence."
        #expect(emailBodyToHTML(markup, mode: "") == markup)
        #expect(emailBodyToHTML(text, mode: "").contains("kypost-plain-text"))
        #expect(!isPlainTextBody(markup, mode: ""))
        #expect(isPlainTextBody(text, mode: ""))
    }

    @Test func treatsAnUnrecognisedModeAsAbsent() {
        // A relay that invents a third value must degrade to sniffing, not to
        // one of the two branches by accident.
        #expect(normalizedBodyMode("HTML") == "html")
        #expect(normalizedBodyMode("  Plain ") == "plain")
        #expect(normalizedBodyMode("richtext") == "")
        #expect(normalizedBodyMode("") == "")
    }

    @Test func rendersMislabelledMarkdownNatively() {
        // Relay and cache rows do label Markdown as HTML. Rendering it in the
        // WebView shows the raw syntax behind a horizontal scrollbar.
        let markdown = "# Heading\n\nSee [the docs](https://example.com/x) for more."
        #expect(isPlainTextBody(markdown, mode: "html"))
        // The conversion still honours the declared mode — only the choice of
        // renderer reacts to the content.
        #expect(emailBodyToHTML(markdown, mode: "html") == markdown)
    }

    @Test func keepsRealMarkupInTheWebViewEvenWhenLabelledHtml() {
        #expect(!isPlainTextBody("<table><tr><td>x</td></tr></table>", mode: "html"))
    }

    @Test func escapesAmpersandsBeforeTheEscapesItIntroduces() {
        #expect(escapeHTMLText("a & b < c") == "a &amp; b &lt; c")
    }
}

// MARK: - Relay wire fields

@Suite struct RelayBodyModeDecodingTests {
    private func decode(_ json: String) throws -> RelayEmailDTO {
        try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
    }

    @Test func carriesBodyModeAndHasAttachmentsThrough() throws {
        let dto = try decode("""
        {"messageId": "m1", "bodyMode": "plain", "hasAttachments": true}
        """)
        let email = dto.toDomain(folder: "INBOX", tab: "")
        #expect(email.bodyMode == "plain")
        #expect(email.hasAttachments)
    }

    @Test func anOlderRelayOmittingThemDegradesToSniffing() throws {
        // Absent is a distinct state from "html"/"plain": "" is what puts the
        // reader back on content sniffing, and false is the safe direction for
        // a marker.
        let dto = try decode(#"{"messageId": "m1"}"#)
        let email = dto.toDomain(folder: "INBOX", tab: "")
        #expect(email.bodyMode == "")
        #expect(!email.hasAttachments)
    }
}

// MARK: - Relay error outcomes (parity brief C5)

@Suite struct RelayErrorOutcomeTests {
    @Test func aRateLimitCarriesItsRetryAfterSeconds() {
        let outcome = MailOutcome.from(NetworkError.rateLimited(retryAfter: 900))
        #expect(outcome == .rateLimited(retryAfter: 900))
    }

    @Test func aRateLimitWithoutAUsableHeaderStillBacksOff() {
        // nil is "we were not told", not "retry now" — the caller must back
        // off either way, so this stays a rateLimited outcome.
        #expect(MailOutcome.from(NetworkError.rateLimited(retryAfter: nil))
            == .rateLimited(retryAfter: nil))
    }

    @Test func retryAfterIsReadableRatherThanRaw() {
        // "900 seconds" is not something a user can act on.
        #expect(NetworkError.formatRetryAfter(30) == "30 seconds")
        #expect(NetworkError.formatRetryAfter(90) == "a minute")
        #expect(NetworkError.formatRetryAfter(900) == "15 minutes")
    }

    @Test func onlyDeltaSecondsCountAsARetryAfter() throws {
        let url = try #require(URL(string: "https://relay.test"))
        func header(_ value: String?) -> HTTPURLResponse? {
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: value.map { ["Retry-After": $0] }
            )
        }
        #expect(NetworkError.retryAfterSeconds(from: try #require(header("120"))) == 120)
        #expect(NetworkError.retryAfterSeconds(from: try #require(header(" 45 "))) == 45)
        #expect(NetworkError.retryAfterSeconds(from: try #require(header(nil))) == nil)
        // The HTTP-date form is legal but unhandled; it must read as absent
        // rather than as zero, since "retry immediately" is the one answer a
        // malformed header must not produce.
        let dated = try #require(header("Wed, 21 Oct 2026 07:28:00 GMT"))
        #expect(NetworkError.retryAfterSeconds(from: dated) == nil)
        #expect(NetworkError.retryAfterSeconds(from: try #require(header("-5"))) == nil)
    }

    @Test func anUnconfiguredAccountIsNotAGenericFailure() {
        // The relay answers plain text; the body is the only discriminator on
        // this path, since a 400 carries no JSON field like the two 409s do.
        let body = "imap configuration is required before mail can be fetched"
        #expect(RelayMailSource.notConfiguredMessage(body: body) == body)
        #expect(MailOutcome.from(NetworkError.badRequest(body: body)) == .notConfigured(body))
    }

    @Test func anOrdinaryBadRequestStaysAFailure() {
        let outcome = MailOutcome.from(NetworkError.badRequest(body: "missing subject"))
        #expect(outcome == .failure("missing subject"))
        #expect(RelayMailSource.notConfiguredMessage(body: "missing subject") == nil)
    }

    @Test func anUpstreamFailureIsDistinctFromAFlatServerError() {
        // 502 is retryable with backoff; the other 5xx are not, and telling
        // the user to retry is only honest for the one that is.
        guard case .upstreamFailure = MailOutcome.from(NetworkError.server(statusCode: 502)) else {
            Issue.record("expected .upstreamFailure for 502")
            return
        }
        guard case .failure = MailOutcome.from(NetworkError.server(statusCode: 500)) else {
            Issue.record("expected .failure for 500")
            return
        }
    }
}

// MARK: - Folder management

@Suite struct FolderCrudTests {
    private func source(_ client: HTTPClient) -> RelayMailSource {
        RelayMailSource(
            httpClient: client,
            serverUrl: "https://relay.test",
            auth: RelayAuth(deviceId: "d1", deviceSecret: "s1")
        )
    }

    @Test func listingCarriesTheServersDeletableFlag() async throws {
        // The server is the authority on what may be deleted. Re-deriving it
        // from the name is how a renamed or localised special folder ends up
        // with a Delete item that always fails.
        let client = stubClient(json: """
        {"parent": "", "folders": [
            {"path": "INBOX", "deletable": false},
            {"path": "INBOX/Receipts", "deletable": true},
            {"path": "INBOX/Legacy"}
        ]}
        """)
        let folders = try await source(client).listFolders(parent: nil)
        #expect(folders == [
            MailFolder(name: "INBOX", deletable: false),
            MailFolder(name: "INBOX/Receipts", deletable: true),
            // Absent reads as not deletable: the safe direction is refusing to
            // offer a destructive action we were not told is available.
            MailFolder(name: "INBOX/Legacy", deletable: false),
        ])
    }

    @Test func createPostsParentAndSegment() async throws {
        let seen = Box<URLRequest?>(nil)
        let client = stubClient(json: #"{"ok": true}"#) { seen.value = $0 }
        try await source(client).createFolder(parent: "INBOX", name: "Receipts")

        let request = try #require(seen.value)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/inbox/folders")
        let body = try #require(request.httpBody).map { $0 }
        let json = String(decoding: Data(body), as: UTF8.self)
        #expect(json.contains(#""parent":"INBOX""#))
        #expect(json.contains(#""name":"Receipts""#))
    }

    @Test func renameUsesPutWithTheFullPathAndNewSegment() async throws {
        let seen = Box<URLRequest?>(nil)
        let client = stubClient(json: #"{"ok": true}"#) { seen.value = $0 }
        try await source(client).renameFolder(folder: "INBOX/Old", name: "New")

        let request = try #require(seen.value)
        #expect(request.httpMethod == "PUT")
        let json = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(json.contains(#""folder":"INBOX\/Old""#) || json.contains(#""folder":"INBOX/Old""#))
        #expect(json.contains(#""name":"New""#))
    }

    @Test func deleteSendsTheTargetAsAQueryParameterNotABody() async throws {
        // The relay does not accept a DELETE payload here.
        let seen = Box<URLRequest?>(nil)
        let client = stubClient(json: #"{"ok": true}"#) { seen.value = $0 }
        try await source(client).deleteFolder(folder: "INBOX/Receipts")

        let request = try #require(seen.value)
        #expect(request.httpMethod == "DELETE")
        #expect(request.httpBody == nil)
        #expect(request.url?.query()?.contains("folder=INBOX") == true)
    }

    @Test func aFolderNameWithASlashStillTravelsAsOneSegment() async throws {
        // The relay joins parent and name; a segment containing the separator
        // must not be able to smuggle a second level in.
        let seen = Box<URLRequest?>(nil)
        let client = stubClient(json: #"{"ok": true}"#) { seen.value = $0 }
        try await source(client).createFolder(parent: "", name: "a/b")

        let request = try #require(seen.value)
        let json = String(decoding: try #require(request.httpBody), as: UTF8.self)
        // Encoded as a JSON string value, so the server sees one field and can
        // reject it — rather than this client silently building a path.
        #expect(json.contains("a") && json.contains("b"))
        #expect(request.url?.path() == "/api/inbox/folders")
    }
}

// MARK: - Delta sync (Phase 2)

@Suite struct MailDeltaReconcileTests {
    private func dao() throws -> EmailDAO {
        EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
    }

    private func email(
        _ id: String,
        body: String = "cached body",
        bodyMode: String = "html",
        subject: String = "Subject",
        bodyOmitted: Bool = false,
        pgpEncrypted: Bool = false
    ) -> Email {
        var email = Email(
            serverId: id, folder: "INBOX", senderName: "A", senderEmail: "a@x",
            subject: subject, body: body, keywords: [],
            receivedAt: Date(timeIntervalSince1970: 1_000), read: false, starred: false
        )
        email.bodyMode = bodyMode
        email.bodyOmitted = bodyOmitted
        email.pgpEncrypted = pgpEncrypted
        return email
    }

    /// The hazard RelayMailSource.swift documented before delta was switched
    /// on: an "updated" row carries no body, and writing "" over the cached
    /// one makes a server-decrypted message read as client-protected — so the
    /// reader sends the user to webmail for mail they can already open.
    @Test func anUpdatedRowKeepsTheBodyItAlreadyHas() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(
            folder: "INBOX",
            emails: [email("m1", body: "<p>real</p>", pgpEncrypted: true)]
        )

        try await dao.applyDelta(
            folder: "INBOX",
            emails: [email("m1", body: "", bodyMode: "", subject: "New subject",
                           bodyOmitted: true, pgpEncrypted: true)],
            updatedIds: ["m1"],
            removedIds: [],
            pruneAgainstEmails: false
        )

        let stored = try #require(try await dao.getEmail(folder: "INBOX", serverId: "m1"))
        #expect(stored.body == "<p>real</p>")
        #expect(stored.bodyMode == "html")   // a blank incoming mode never wins
        #expect(stored.subject == "New subject")
        #expect(pgpMessageState(
            pgpEncrypted: stored.pgpEncrypted,
            pgpDecryptError: stored.pgpDecryptError,
            body: stored.body
        ) == .decryptedByServer)
    }

    /// With no row to merge into, storing the metadata-only entry creates one
    /// whose empty body is indistinguishable from a client-protected message.
    /// We do not have this message; a metadata-only delta is not a delivery.
    @Test func anUpdatedRowWeNeverHadIsSkippedRatherThanInvented() async throws {
        let dao = try dao()
        try await dao.applyDelta(
            folder: "INBOX",
            emails: [email("ghost", body: "", bodyOmitted: true)],
            updatedIds: ["ghost"],
            removedIds: [],
            pruneAgainstEmails: false
        )
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "ghost") == nil)
    }

    @Test func newRowsAreInsertedAndRemovedIdsDeleted() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [email("old")])
        try await dao.applyDelta(
            folder: "INBOX",
            emails: [email("fresh", body: "<p>new</p>")],
            updatedIds: [],
            removedIds: ["old"],
            pruneAgainstEmails: false
        )
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "old") == nil)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "fresh")?.body == "<p>new</p>")
    }

    /// A partial delta describes only what changed. Everything it omits is
    /// still legitimately in the mailbox, so pruning against it would delete
    /// the whole folder bar the few rows that happened to change.
    @Test func aPartialDeltaNeverPrunesTheFolder() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(
            folder: "INBOX", emails: [email("keep1"), email("keep2")]
        )
        try await dao.applyDelta(
            folder: "INBOX",
            emails: [email("keep1", subject: "edited")],
            updatedIds: ["keep1"],
            removedIds: [],
            pruneAgainstEmails: false
        )
        #expect(try await dao.getFolder(folder: "INBOX", limit: 50).count == 2)
    }

    /// A full window can say what is *absent*, and pruning against it is the
    /// only self-heal for a removal this device was never told about.
    @Test func aFullWindowPrunesWhatItDoesNotMention() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(
            folder: "INBOX", emails: [email("stays"), email("deletedOnTheWeb")]
        )
        try await dao.applyDelta(
            folder: "INBOX",
            emails: [email("stays")],
            updatedIds: [],
            removedIds: [],
            pruneAgainstEmails: true
        )
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "deletedOnTheWeb") == nil)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "stays") != nil)
    }

    @Test func pruningIsScopedToItsOwnFolder() async throws {
        let dao = try dao()
        var other = email("elsewhere")
        other.folder = "Archive"
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [email("inboxRow")])
        try await dao.replaceFolderSnapshot(folder: "Archive", emails: [other])
        try await dao.applyDelta(
            folder: "INBOX", emails: [], updatedIds: [], removedIds: [],
            pruneAgainstEmails: true
        )
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "inboxRow") == nil)
        #expect(try await dao.getEmail(folder: "Archive", serverId: "elsewhere") != nil)
    }
}

// MARK: - Snooze pin (wokenAt)

@Suite struct SnoozePinTests {
    private func dao() throws -> EmailDAO {
        EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
    }

    private func email(_ id: String, receivedAt: TimeInterval, wokenAt: TimeInterval? = nil) -> Email {
        Email(
            serverId: id, folder: "INBOX", senderName: "A", senderEmail: "a@x",
            subject: "S", body: "B", keywords: [],
            receivedAt: Date(timeIntervalSince1970: receivedAt),
            wokenAt: wokenAt.map(Date.init(timeIntervalSince1970:)),
            read: false, starred: false
        )
    }

    @Test func wokenAtDecodesAndTheDisplayedDateStaysAtUtc() throws {
        let email = try JSONDecoder().decode(RelayEmailDTO.self, from: Data("""
        {"messageId": "m1", "atUtc": "2025-01-01T00:00:00Z", "wokenAt": "2025-06-01T00:00:00Z"}
        """.utf8)).toDomain(folder: "INBOX", tab: "")
        #expect(email.receivedAt == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(email.wokenAt == Date(timeIntervalSince1970: 1_748_736_000))
    }

    @Test func anAbsentWokenAtIsNil() throws {
        let email = try JSONDecoder().decode(RelayEmailDTO.self, from: Data("""
        {"messageId": "m1", "atUtc": "2025-01-01T00:00:00Z"}
        """.utf8)).toDomain(folder: "INBOX", tab: "")
        #expect(email.wokenAt == nil)
    }

    @Test func aWokenOlderEmailSortsAboveANewerOne() async throws {
        let response = try JSONDecoder().decode(RelayInboxResponse.self, from: Data("""
        {"byTab": {"Inbox": [
          {"messageId": "newer", "atUtc": "2025-03-01T00:00:00Z"},
          {"messageId": "woken", "atUtc": "2025-01-01T00:00:00Z", "wokenAt": "2025-06-01T00:00:00Z"}
        ]}}
        """.utf8))
        let emails = response.allEmails(folder: "INBOX")
        #expect(emails.map(\.serverId) == ["woken", "newer"])

        let dao = try dao()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: emails)
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).map(\.serverId) == ["woken", "newer"])
    }

    @Test func anUpdatedRowWithoutWokenAtClearsThePin() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(
            folder: "INBOX",
            emails: [email("m1", receivedAt: 1_000, wokenAt: 5_000), email("m2", receivedAt: 2_000)]
        )
        var unpinned = email("m1", receivedAt: 1_000)
        unpinned.bodyOmitted = true
        try await dao.applyDelta(
            folder: "INBOX", emails: [unpinned], updatedIds: ["m1"], removedIds: [],
            pruneAgainstEmails: false
        )
        let stored = try #require(try await dao.getEmail(folder: "INBOX", serverId: "m1"))
        #expect(stored.wokenAt == nil)
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).map(\.serverId) == ["m2", "m1"])
    }

    /// Older mail paged in (or walked past a delta's overflow) is inserted
    /// out of the window; a woken row there still sorts by its wake time.
    @Test func aPagedInWokenRowSortsByItsWakeTime() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [email("window", receivedAt: 3_000)])
        try await dao.storeOlderMail(
            folder: "INBOX",
            emails: [email("old", receivedAt: 1_000), email("woken", receivedAt: 500, wokenAt: 9_000)]
        )
        #expect(try await dao.getFolder(folder: "INBOX").map(\.serverId) == ["woken", "window", "old"])
    }

    /// V9 added columns to a live @Model; a store written at V8 must still
    /// open, and its rows must sort by receivedAt once backfilled.
    @Test func aV8StoreMigratesAndBackfillsSortDate() async throws {
        let url = URL.temporaryDirectory
            .appending(path: "snooze-migration-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }

        do {
            let v8Schema = Schema(versionedSchema: AppSchemaV8.self)
            let container = try ModelContainer(
                for: v8Schema,
                configurations: [ModelConfiguration(schema: v8Schema, url: url)]
            )
            let context = ModelContext(container)
            for (id, at) in [("older", 1_000.0), ("newer", 2_000.0)] {
                context.insert(AppSchemaV8.EmailEntity(
                    serverId: id, folder: "INBOX", senderName: "A", senderEmail: "a@x",
                    subject: "S", body: "B", keywords: [],
                    receivedAt: Date(timeIntervalSince1970: at), read: false, starred: false
                ))
            }
            try context.save()
        }

        let container = try ModelContainer(
            for: AppDatabase.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: AppDatabase.schema, url: url)]
        )
        let dao = EmailDAO(modelContainer: container)
        try await dao.backfillSortDates()

        let rows = try ModelContext(container).fetch(FetchDescriptor<EmailEntity>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.sortDate == $0.receivedAt && $0.wokenAt == nil })
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).map(\.serverId) == ["newer", "older"])
    }
}

@Suite struct MailCursorStoreTests {
    private func store(
        hostileLocation: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> (MailCursorStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let hlp = HostileLocationProtectionStore(defaults: defaults)
        hlp.enabled = hostileLocation
        return (MailCursorStore(defaults: defaults, hostileLocation: hlp, now: now), defaults)
    }

    @Test func roundTripsACursorPerFolder() {
        let (store, _) = store()
        store.saveCursor(pairingId: "sub1", folder: "INBOX", cursor: "c-1")
        store.saveCursor(pairingId: "sub1", folder: "Archive", cursor: "c-2")
        #expect(store.cursor(pairingId: "sub1", folder: "INBOX") == "c-1")
        #expect(store.cursor(pairingId: "sub1", folder: "Archive") == "c-2")
    }

    /// Re-pairing must not put the previous relay's token on the wire to a
    /// server that never issued it.
    @Test func adifferentPairingDoesNotSeeTheOldCursor() {
        let (store, _) = store()
        store.saveCursor(pairingId: "sub1", folder: "INBOX", cursor: "c-1")
        #expect(store.cursor(pairingId: "sub2", folder: "INBOX") == "")
    }

    /// Android's bug: recording a resync shared the cursor's scope key, so the
    /// stamp re-authorised a stale cursor for the new pairing.
    @Test func recordingAResyncDoesNotReauthoriseAStaleCursor() {
        let (store, _) = store()
        store.saveCursor(pairingId: "sub1", folder: "INBOX", cursor: "c-1")
        store.recordFullResync(pairingId: "sub2", folder: "INBOX")
        #expect(store.cursor(pairingId: "sub2", folder: "INBOX") == "")
        #expect(store.cursor(pairingId: "sub1", folder: "INBOX") == "c-1")
    }

    @Test func aFolderNamedLikeAnotherFoldersKeyCannotCollide() {
        // The folder name is an unvalidated server string. Hashing the key
        // means no name can be crafted to land on another folder's slot.
        let (store, _) = store()
        store.saveCursor(pairingId: "s", folder: "INBOX", cursor: "inbox-cursor")
        store.saveCursor(pairingId: "s", folder: "scope_INBOX", cursor: "other-cursor")
        #expect(store.cursor(pairingId: "s", folder: "INBOX") == "inbox-cursor")
        #expect(store.cursor(pairingId: "s", folder: "scope_INBOX") == "other-cursor")
    }

    @Test func theFolderTaxonomyNeverReachesTheDefaultsKeys() {
        let (store, defaults) = store()
        store.saveCursor(pairingId: "s", folder: "Archive/Legal/Asylum-Case", cursor: "c")
        let keys = defaults.dictionaryRepresentation().keys.joined(separator: " ")
        #expect(!keys.contains("Asylum"))
        #expect(!keys.contains("Legal"))
    }

    @Test func aFullResyncIsForcedWhenNoneWasEverRecorded() {
        let (store, _) = store()
        #expect(store.shouldForceFullResync(pairingId: "s", folder: "INBOX"))
        store.recordFullResync(pairingId: "s", folder: "INBOX")
        #expect(!store.shouldForceFullResync(pairingId: "s", folder: "INBOX"))
    }

    @Test func aFullResyncIsForcedAgainADayLater() {
        let clock = Box(Date(timeIntervalSince1970: 0))
        let (store, _) = store(now: { clock.value })
        store.recordFullResync(pairingId: "s", folder: "INBOX")
        clock.value = Date(timeIntervalSince1970: 23 * 3_600)
        #expect(!store.shouldForceFullResync(pairingId: "s", folder: "INBOX"))
        clock.value = Date(timeIntervalSince1970: 24 * 3_600)
        #expect(store.shouldForceFullResync(pairingId: "s", folder: "INBOX"))
    }

    /// Under Hostile Location Protection these keys would spell out which
    /// folders exist and when each was last read.
    @Test func hostileLocationProtectionKeepsEverythingOffDisk() {
        let (store, defaults) = store(hostileLocation: true)
        store.saveCursor(pairingId: "s", folder: "INBOX", cursor: "c-1")
        store.recordFullResync(pairingId: "s", folder: "INBOX")
        #expect(store.cursor(pairingId: "s", folder: "INBOX") == "c-1")
        let keys = defaults.dictionaryRepresentation().keys.joined(separator: " ")
        #expect(!keys.contains("mail.cursorValue"))
        #expect(!keys.contains("mail.resyncStamp"))
    }

    @Test func aBlankCursorIsNeverStored() {
        // A relay may answer with no cursor; that must not clear a good one.
        let (store, _) = store()
        store.saveCursor(pairingId: "s", folder: "INBOX", cursor: "c-1")
        store.saveCursor(pairingId: "s", folder: "INBOX", cursor: "")
        #expect(store.cursor(pairingId: "s", folder: "INBOX") == "c-1")
    }
}

// MARK: - Phishing flag (Phase 3)

@Suite struct PhishingFlagTests {
    @Test func recognisesTheReservedKeyword() {
        #expect(isFlaggedPhishing(["Primary", phishingKeyword]))
        #expect(phishingKeyword == "$Phishing")
    }

    /// IMAP keywords are case-insensitive. A server may echo back `$phishing`
    /// for a keyword the poller set as `$Phishing`, and a case-sensitive check
    /// would drop the warning on precisely the mail it exists for.
    @Test func matchesRegardlessOfCaseOrSurroundingSpace() {
        #expect(isFlaggedPhishing(["$phishing"]))
        #expect(isFlaggedPhishing(["$PHISHING"]))
        #expect(isFlaggedPhishing(["$PhIsHiNg"]))
        #expect(isFlaggedPhishing(["  $Phishing  "]))
    }

    @Test func doesNotMatchANeighbouringKeyword() {
        // Exact match, not a prefix or a substring.
        #expect(!isFlaggedPhishing(["$PhishingReport"]))
        #expect(!isFlaggedPhishing(["NotPhishing"]))
        #expect(!isFlaggedPhishing(["Primary", "Receipts"]))
        #expect(!isFlaggedPhishing([String]()))
    }

    @Test func systemKeywordsAreTheDollarPrefixedNamespace() {
        #expect(isSystemKeyword("$Phishing"))
        #expect(isSystemKeyword("$Junk"))
        #expect(isSystemKeyword(" $Forwarded"))
        #expect(!isSystemKeyword("Work"))
        #expect(!isSystemKeyword("Receipts"))
    }
}

@Suite struct PhishingKeywordWireTests {
    private func decode(_ json: String) throws -> RelayEmailDTO {
        try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
    }

    /// The regression this closes: `keywords` was not decoded at all, so the
    /// server could set $Phishing and this client would never see it.
    @Test func theWireKeywordsReachTheDomainModel() throws {
        let dto = try decode("""
        {"messageId": "m1", "label": "Work", "keywords": ["Work", "$Phishing"]}
        """)
        let email = dto.toDomain(folder: "INBOX", tab: "Primary")
        #expect(email.keywords.contains("$Phishing"))
        #expect(isFlaggedPhishing(email.keywords))
    }

    /// Union, not replacement: the label drives the tab strip and the wire
    /// list carries protocol keywords. Dropping either loses something.
    @Test func theTabDerivedLabelSurvivesAlongsideTheWireKeywords() throws {
        let dto = try decode("""
        {"messageId": "m1", "label": "Important", "keywords": ["$Phishing"]}
        """)
        let email = dto.toDomain(folder: "INBOX", tab: "Primary")
        #expect(email.keywords == ["Important", "$Phishing"])
    }

    @Test func anOlderRelayWithoutTheFieldStillGetsItsTab() throws {
        let dto = try decode(#"{"messageId": "m1", "label": "Work"}"#)
        let email = dto.toDomain(folder: "INBOX", tab: "Primary")
        #expect(email.keywords == ["Work"])
        #expect(!isFlaggedPhishing(email.keywords))
    }
}

@Suite struct MessageBodyNavigationTests {
    private func policy(_ urlString: String, tapped: Bool = true)
        -> EmailBodyWebView.BodyNavigation {
        EmailBodyWebView.navigationPolicy(url: URL(string: urlString), isLinkActivation: tapped)
    }

    /// Handing a tap to the system routes this app's own scheme back into this
    /// app, so a kypost://native-pair link in a message would raise the
    /// pairing confirmation on top of the sender's pretext.
    @Test func theMessageBodyCannotReachTheAppsOwnScheme() {
        #expect(policy("kypost://native-pair?sub=a&srv=https://evil.test&pt=x") == .block)
        #expect(policy("kypost://native-pair", tapped: false) == .block)
    }

    /// An allowlist, not a denylist: a mail body has no business opening any
    /// other scheme either, and a denylist needs updating whenever one appears.
    @Test func onlyHttpAndHttpsLeaveTheMessage() {
        #expect(policy("https://example.com") == .openInBrowser(URL(string: "https://example.com")!))
        #expect(policy("http://example.com") == .openInBrowser(URL(string: "http://example.com")!))
        #expect(policy("file:///etc/passwd") == .block)
        #expect(policy("tel:+15550100") == .block)
        #expect(policy("javascript:alert(1)") == .block)
    }

    @Test func theMessageDocumentItselfStillLoads() {
        #expect(policy("about:blank", tapped: false) == .allow)
    }

    /// A <meta http-equiv="refresh"> is plain HTML and a main-frame
    /// navigation — neither script nor subresource — so it must still be
    /// dropped even for an allowed scheme.
    @Test func anUngesturedNavigationIsStillDropped() {
        #expect(policy("https://example.com", tapped: false) == .block)
    }
}
