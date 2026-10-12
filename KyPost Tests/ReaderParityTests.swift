//
//  ReaderParityTests.swift
//  KyPost Tests
//
//  Message-detail rules ported from kypost-android: the To/Cc line (#119),
//  decrypted attachments and inline images (#109), the reply/forward gate for
//  client-protected mail, and forwarding the original's attachments
//  (ForwardAttachmentHandoff).
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Header text

@Suite struct DisplayHeaderTextTests {
    /// A display name carrying CR/LF would otherwise forge its own labelled
    /// line under the real ones.
    @Test func lineBreaksCannotForgeALabelledLine() {
        #expect(displayHeaderText("Alice\r\nCc: ceo@example.com <a@example.com>")
            == "Alice Cc: ceo@example.com <a@example.com>")
        #expect(displayHeaderText("a\u{2028}b\u{2029}c\u{85}d") == "a b c d")
    }

    /// A bidi override reverses how the address that follows it is shown.
    @Test func formatCharactersAreFlattened() {
        #expect(displayHeaderText("\u{202E}moc.live@eve") == "moc.live@eve")
        #expect(displayHeaderText("bob\u{200B}\u{200D}@example.com") == "bob @example.com")
    }

    @Test func runsCollapseToOneSpaceAndTheEndsAreTrimmed() {
        #expect(displayHeaderText("\t\u{0}a\u{1}\u{2}\u{202A}b\n") == "a b")
        #expect(displayHeaderText("Plain Name <p@example.com>") == "Plain Name <p@example.com>")
    }

    /// No row recipients, no line: an empty "To:" reads as a bug.
    @Test func emptyFieldsAreHidden() {
        let none = detailRecipientLines(to: "", cc: "\u{200E}\r\n")
        #expect(none.to == nil)
        #expect(none.cc == nil)
        let both = detailRecipientLines(to: "a@example.com, B <b@example.com>", cc: "c@example.com")
        #expect(both.to == "a@example.com, B <b@example.com>")
        #expect(both.cc == "c@example.com")
    }
}

// MARK: - Client-protected gates

@Suite struct ClientProtectedReaderGateTests {
    /// Reply/Forward would quote decrypted plaintext into an archived scene
    /// value, or upload it as a server draft.
    @Test func replyAndForwardAreClosedOnlyForClientProtectedMail() {
        #expect(!mayReplyOrForward(.clientProtected))
        #expect(mayReplyOrForward(.none))
        #expect(mayReplyOrForward(.decryptedByServer))
        #expect(mayReplyOrForward(.decryptFailed))
    }

    @Test func messageLevelSignatureNoticesNeedNoSender() {
        #expect(signatureLabel(.unsigned) == "Encrypted, not signed")
        #expect(signatureLabel(.unchecked) == "Signature not checked")
        #expect(signatureIsMessageLevel(.unsigned))
        #expect(signatureIsMessageLevel(.unchecked))
        #expect(!signatureIsMessageLevel(.signerUnknown))
        // Neither is an accusation, and neither marks a row.
        #expect(signatureRowSymbol(.unsigned) == nil)
        #expect(signatureRowSymbol(.unchecked) == nil)
        #expect(!signatureIsAlarming(.unchecked))
    }
}

// MARK: - Inline images

@Suite struct InlineImagesTests {
    private let png = DecryptedAttachment(
        name: "logo.png", mimeType: "image/png", data: Data([1, 2, 3]), contentId: "logo@x"
    )

    @Test func aCidImageBecomesADataURI() {
        let html = InlineImages.inlineCidImages(
            html: #"<p>hi</p><img alt="x" src="cid:logo@x" width=3>"#, attachments: [png]
        )
        #expect(html == #"<p>hi</p><img alt="x" src="data:image/png;base64,AQID" width=3>"#)
    }

    @Test func quotingAndCaseVariantsResolve() {
        #expect(InlineImages.inlineCidImages(html: "<IMG SRC='CID:logo@x'>", attachments: [png])
            == #"<IMG SRC="data:image/png;base64,AQID">"#)
        #expect(InlineImages.inlineCidImages(html: "<img src=cid:logo@x>", attachments: [png])
            == #"<img src="data:image/png;base64,AQID">"#)
    }

    /// Only `src` on an `img`: `data-src`, other tags and unknown ids stay.
    @Test func onlyResolvableImgSourcesAreRewritten() {
        let untouched = [
            #"<img data-src="cid:logo@x">"#,
            #"<a href="cid:logo@x">x</a>"#,
            #"<img src="cid:other@x">"#,
            #"<img src="https://example.com/a.png">"#,
        ]
        for html in untouched {
            #expect(InlineImages.inlineCidImages(html: html, attachments: [png]) == html)
        }
    }

    /// The allowlist is declared raster types: an SVG is a document with its
    /// own script and fetch surface.
    @Test func nonRasterTypesAreNotInlined() {
        let svg = DecryptedAttachment(name: "a.svg", mimeType: "image/svg+xml", data: Data([1]), contentId: "s")
        let html = #"<img src="cid:s">"#
        #expect(InlineImages.inlineCidImages(html: html, attachments: [svg]) == html)
    }

    /// The sender chooses the size; the budget caps the total, and an image
    /// past it keeps its unresolvable `cid:`.
    @Test func theByteBudgetBoundsTheTotal() {
        let half = InlineImages.byteBudget / 2 + 1
        let a = DecryptedAttachment(name: "a", mimeType: "image/gif", data: Data(count: half), contentId: "a")
        let b = DecryptedAttachment(name: "b", mimeType: "image/gif", data: Data(count: half), contentId: "b")
        let html = InlineImages.inlineCidImages(
            html: #"<img src="cid:a"><img src="cid:b">"#, attachments: [a, b]
        )
        #expect(html.hasPrefix(#"<img src="data:image/gif;base64,"#))
        #expect(html.hasSuffix(#"<img src="cid:b">"#))
    }

    /// Text inside another attribute's quoted value is not a `src`.
    @Test func onlyTheRealSrcAttributeIsRewritten() {
        let html = InlineImages.inlineCidImages(
            html: #"<img alt='example src="cid:logo@x"' src="cid:logo@x">"#, attachments: [png]
        )
        #expect(html == #"<img alt='example src="cid:logo@x"' src="data:image/png;base64,AQID">"#)
    }
}

// MARK: - Staged previews

@Suite(.serialized) struct DecryptedAttachmentFilesTests {
    private func scratch() -> DecryptedAttachmentFiles {
        DecryptedAttachmentFiles(root: FileManager.default.temporaryDirectory
            .appending(path: "reader-parity-\(UUID().uuidString)/decrypted"))
    }

    /// The security wipe and the Hostile Location Protection purge delete the
    /// attachments root; a preview staged anywhere else would survive both.
    @MainActor
    @Test func previewsLiveUnderTheRootTheWipeDeletes() {
        let root = InboxViewModel.attachmentTempRoot.standardizedFileURL.path
        #expect(DecryptedAttachmentFiles.defaultRoot.standardizedFileURL.path.hasPrefix(root + "/"))
    }

    @Test func stagingWritesASanitisedNameAndRemovalDeletesItsDirectory() throws {
        let files = scratch()
        let url = try files.stage(DecryptedAttachment(
            name: "../\u{202E}fdp.exe", mimeType: "application/pdf", data: Data("pdf".utf8), contentId: nil
        ))
        #expect(url.lastPathComponent == "_fdp.exe")
        #expect(try Data(contentsOf: url) == Data("pdf".utf8))
        files.remove(url)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    /// Removal only ever deletes a directory directly under the root.
    @Test func removalRefusesPathsOutsideTheRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        scratch().remove(outside.appending(path: "file"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func fileNamesAreSafePathComponents() {
        #expect(safeAttachmentFileName("a/b:c\\d.txt") == "a_b_c_d.txt")
        #expect(safeAttachmentFileName("...hidden") == "hidden")
        #expect(safeAttachmentFileName("\u{0}\u{200B}") == "attachment")
        #expect(safeAttachmentFileName(String(repeating: "é", count: 300)).utf8.count <= 200)
    }
}

// MARK: - Read view model

private struct OpenedVault: VaultOpening {
    func open() async -> VaultOpenOutcome { .opened(privateKey: Data("KEY".utf8)) }
}

private struct OnePayload: PgpPayloadSource {
    var resolvedSender = ""
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult {
        .success(PgpPayload(encryptedPayload: "CIPHERTEXT", resolvedSender: resolvedSender))
    }
}

private struct PlaintextCrypto: PgpDecrypting {
    var mime: String
    func decrypt(armoredCiphertext: String, privateKeys: [Data], signerKeys: [String]) throws -> DecryptedMessage {
        DecryptedMessage(body: Data(mime.utf8), signature: RawSignature())
    }
    func verifyDetached(signedBytes: Data, armoredSignature: String, signerKeys: [String]) -> RawSignature {
        RawSignature()
    }
    func fingerprint(ofArmoredPublicKey key: String) -> String? { nil }
}

private let mixedMime = """
Content-Type: multipart/mixed; boundary="m"\r
\r
--m\r
Content-Type: multipart/related; boundary="r"\r
\r
--r\r
Content-Type: text/html\r
\r
<p>see <img src="cid:dot@x"></p>\r
--r\r
Content-Type: image/png\r
Content-ID: <dot@x>\r
Content-Transfer-Encoding: base64\r
\r
AQID\r
--r--\r
--m\r
Content-Type: application/pdf; name="report.pdf"\r
Content-Disposition: attachment; filename="report.pdf"\r
Content-Transfer-Encoding: base64\r
\r
JVBERg==\r
--m--\r
"""

@MainActor
@Suite(.serialized) struct EncryptedReadAttachmentTests {
    private func model(mime: String = mixedMime, resolvedSender: String = "") -> EncryptedReadViewModel {
        EncryptedReadViewModel(
            reader: EncryptedMessageReader(
                opener: OpenedVault(),
                payloads: OnePayload(resolvedSender: resolvedSender),
                crypto: PlaintextCrypto(mime: mime),
                pins: .none,
                session: EnrollmentSession()
            ),
            mailbox: "INBOX",
            messageId: "1",
            sender: "a@example.com",
            files: DecryptedAttachmentFiles(root: FileManager.default.temporaryDirectory
                .appending(path: "reader-vm-\(UUID().uuidString)/decrypted"))
        )
    }

    @Test func attachmentsAndInlineImagesComeFromTheDecryptedMime() async throws {
        let subject = model()
        await subject.decrypt()
        let body = try #require(subject.body)
        #expect(body.attachments.map(\.name) == ["attachment", "report.pdf"])
        #expect(subject.renderedHTML?.contains(#"src="data:image/png;base64,AQID""#) == true)
        #expect(subject.attachmentsOmittedMessage == nil)
    }

    /// The preview file is plaintext on disk: closed previews and a screen
    /// going away both delete it.
    @Test func stagedPreviewsAreDeletedOnCloseAndOnForget() async throws {
        let subject = model()
        await subject.decrypt()
        let parts = try #require(subject.body?.attachments)
        let first = try #require(subject.stageForPreview(parts[0]))
        let second = try #require(subject.stageForPreview(parts[1]))
        subject.discardPreview(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        subject.forget()
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(subject.body == nil)
    }

    /// Only this message's own parts can be staged.
    @Test func aForeignAttachmentIsNotStaged() async {
        let subject = model()
        await subject.decrypt()
        let stranger = DecryptedAttachment(name: "x", mimeType: "text/plain", data: Data(), contentId: nil)
        #expect(subject.stageForPreview(stranger) == nil)
    }

    /// "Encrypted, not signed" is about the message, so it shows even when
    /// the server resolved no sender; a sender verdict never does.
    @Test func theSignatureLineFollowsItsKind() async {
        let unsigned = model(mime: "Content-Type: text/plain\r\n\r\nhi\r\n")
        await unsigned.decrypt()
        #expect(unsigned.signature == .unsigned)
        #expect(unsigned.signatureLine == "Encrypted, not signed")

        let nested = model(mime: """
        Content-Type: multipart/mixed; boundary="o"\r
        \r
        --o\r
        Content-Type: multipart/signed; protocol="application/pgp-signature"; boundary="s"\r
        \r
        --s\r
        Content-Type: text/plain\r
        \r
        signed text\r
        --s\r
        Content-Type: application/pgp-signature\r
        \r
        -----BEGIN PGP SIGNATURE-----\r
        --s--\r
        --o--\r
        """, resolvedSender: "")
        await nested.decrypt()
        #expect(nested.signature == .unchecked)
        #expect(nested.signatureLine == "Signature not checked")
        // The detached signature is transport, not a file for the reader.
        #expect(nested.body?.attachments.isEmpty == true)
    }
}

// MARK: - Forward

@MainActor
@Suite(.serialized) struct ForwardAttachmentHandoffTests {
    private let file = OutgoingAttachment(name: "a.txt", mimeType: "text/plain", data: Data("a".utf8))

    @Test func aHandoffIsClaimedOnceAndOnlyByItsDraft() {
        let handoff = ForwardAttachmentHandoff(center: NotificationCenter())
        let id = UUID()
        handoff.put([file], notice: nil, for: id)
        #expect(handoff.take(for: UUID()) == nil)
        #expect(handoff.take(for: id)?.attachments == [file])
        // A restored window with the same draft gets nothing: never archived.
        #expect(handoff.take(for: id) == nil)
    }

    /// Every session boundary drops held bytes: wipe, reset, unpair, and the
    /// Hostile Location Protection switch that closes compose windows.
    @Test func sessionBoundariesDropTheHandoff() {
        for name in [Notification.Name.kyPostSessionReset, .kyPostCloseComposeWindows] {
            let center = NotificationCenter()
            let handoff = ForwardAttachmentHandoff(center: center)
            handoff.put([file], notice: nil, for: UUID())
            center.post(name: name, object: nil)
            #expect(!handoff.isHoldingAttachments)
        }
    }

    /// Refuses rather than evicts, keeps the sender's order, and does not
    /// download what its listed size already rules out.
    @Test func collectionStaysWithinBudgetWithoutEviction() async {
        let listing = [
            EmailAttachment(index: 2, name: "c", mimeType: "a/b", size: 4),
            EmailAttachment(index: 0, name: "a", mimeType: "a/b", size: 6),
            EmailAttachment(index: 1, name: "b", mimeType: "a/b", size: 100),
            EmailAttachment(index: 3, name: "d", mimeType: "a/b", size: 1),
        ]
        var fetched: [Int] = []
        let result = await collectForwardAttachments(listing, budget: 11) { item in
            fetched.append(item.index)
            return item.index == 3 ? nil : Data(count: item.size)
        }
        #expect(result.attachments.map(\.name) == ["a", "c"])
        #expect(result.tooLarge == 1)
        #expect(result.failed == 1)
        #expect(!fetched.contains(1))
        #expect(forwardAttachmentNotice(failed: 0, tooLarge: 0) == nil)
        #expect(forwardAttachmentNotice(failed: 1, tooLarge: 2)?.contains("2 attachments are too large") == true)
    }

    private let listed = [EmailAttachment(index: 0, name: "a.txt", mimeType: "text/plain", size: 1)]

    /// A forward overtaken by a session boundary stores nothing and opens
    /// nothing, whichever boundary it was.
    @Test func aSessionBoundaryDuringTheFetchVoidsTheForward() async {
        for name in [Notification.Name.kyPostSessionReset, .kyPostCloseComposeWindows] {
            let center = NotificationCenter()
            let handoff = ForwardAttachmentHandoff(center: center)
            let gate = AsyncGate()
            let opened = Flag()
            let forward = Task { @MainActor in
                await runForward(
                    draftID: UUID(), handoff: handoff,
                    listing: { listed },
                    fetch: { _ in await gate.wait(); return Data("a".utf8) },
                    open: { opened.value = true }
                )
            }
            await gate.waitUntilWaiting()
            center.post(name: name, object: nil)
            await gate.open()
            #expect(await forward.value == false)
            #expect(!handoff.isHoldingAttachments)
            #expect(!opened.value)
        }
    }

    /// Forward pressed before the listing lands waits for it and carries the
    /// original's file.
    @Test func forwardWaitsForTheAttachmentListing() async {
        let handoff = ForwardAttachmentHandoff(center: NotificationCenter())
        let gate = AsyncGate()
        let draftID = UUID()
        let opened = Flag()
        let forward = Task { @MainActor in
            await runForward(
                draftID: draftID, handoff: handoff,
                listing: { await gate.wait(); return listed },
                fetch: { _ in Data("a".utf8) },
                open: { opened.value = true }
            )
        }
        await gate.waitUntilWaiting()
        #expect(!opened.value)
        await gate.open()
        #expect(await forward.value)
        #expect(opened.value)
        #expect(handoff.take(for: draftID)?.attachments == [file])
    }

    /// A listing that failed is said in compose, not read as "no files".
    @Test func aFailedListingIsSurfaced() async {
        let handoff = ForwardAttachmentHandoff(center: NotificationCenter())
        let draftID = UUID()
        let opened = await runForward(
            draftID: draftID, handoff: handoff,
            listing: { nil }, fetch: { _ in nil }, open: {}
        )
        #expect(opened)
        #expect(handoff.take(for: draftID)?.notice == forwardListingFailedNotice)
    }

    /// The screen going away cancels its forward.
    @Test func aCancelledForwardOpensNothing() async {
        let handoff = ForwardAttachmentHandoff(center: NotificationCenter())
        let gate = AsyncGate()
        let opened = Flag()
        let forward = Task { @MainActor in
            await runForward(
                draftID: UUID(), handoff: handoff,
                listing: { await gate.wait(); return [] },
                fetch: { _ in nil },
                open: { opened.value = true }
            )
        }
        await gate.waitUntilWaiting()
        forward.cancel()
        await gate.open()
        #expect(await forward.value == false)
        #expect(!opened.value)
    }

    @Test func composeAdoptsTheForwardedFilesAndNotice() throws {
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
        let draft = ComposeDraft.forward(Email(
            serverId: "1", folder: "INBOX", senderName: "", senderEmail: "s@example.com",
            subject: "Hi", body: "body", keywords: [], receivedAt: Date(), read: true, starred: false
        ))
        let compose = ComposeViewModel(
            sendEmail: SendEmailUseCase(repository: MailRepository(
                securePairingStore: pairingStore,
                emailDAO: EmailDAO(modelContainer: db.container),
                httpClient: stubClient()
            )),
            contacts: contacts,
            pgp: PgpSendService(client: PgpSendClient(httpClient: stubClient()), securePairingStore: pairingStore),
            draft: draft,
            debounceInterval: .zero
        )
        let handoff = ForwardAttachmentHandoff(center: NotificationCenter())
        handoff.put([file], notice: "1 attachment couldn't be downloaded and isn't included.", for: draft.id)
        compose.adoptForwardedAttachments(from: handoff)
        #expect(compose.attachments.map(\.name) == ["a.txt"])
        #expect(compose.noticeMessage?.contains("couldn't be downloaded") == true)
        compose.adoptForwardedAttachments(from: handoff)
        #expect(compose.attachments.count == 1)
    }
}

// MARK: - MIME attachments

@Suite struct PgpMimeAttachmentTests {
    private func read(_ text: String) -> DecryptedBody? { PgpMimeReader.read(Data(text.utf8)) }

    private func mixed(_ parts: [String]) -> String {
        "Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n"
            + parts.map { "--m\r\n\($0)\r\n" }.joined() + "--m--\r\n"
    }

    /// Many mailers stamp `name=` and a Content-ID on every part, the body
    /// included; neither makes a text part a file.
    @Test func aNamedTextPartIsStillTheBody() throws {
        let body = try #require(read(mixed([
            "Content-Type: text/plain; name=\"body.txt\"\r\nContent-ID: <b@x>\r\n\r\nthe body",
            "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=notes.txt\r\n\r\nfile",
        ])))
        #expect(body.plain == "the body")
        #expect(body.attachments.map(\.name) == ["notes.txt"])
        #expect(body.attachments.first?.data == Data("file".utf8))
    }

    /// Files are content: an attachment-only message is not unreadable.
    @Test func aFilesOnlyMessageHasAnEmptyBody() throws {
        let body = try #require(read(mixed([
            "Content-Type: application/zip\r\nContent-Transfer-Encoding: base64\r\n\r\nUEsD",
        ])))
        #expect(body.plain == "")
        #expect(body.attachments.first?.mimeType == "application/zip")
        #expect(body.attachments.first?.data == Data([0x50, 0x4B, 0x03]))
    }

    @Test func filenamesDecodeRfc2231AndEncodedWords() throws {
        let body = try #require(read(mixed([
            "Content-Type: text/plain\r\n\r\nx",
            "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf\r\n\r\n%",
            "Content-Type: application/pdf; name=\"=?UTF-8?B?w6kucGRm?=\"\r\n\r\n%",
        ])))
        #expect(body.attachments.map(\.name) == ["résumé.pdf", "é.pdf"])
    }

    /// A sender chooses the part count; past the cap parts are dropped and
    /// the drop is reported.
    @Test func thePartCountIsCapped() throws {
        let files = (0...PgpMimeReader.attachmentPartCap).map {
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=f\($0)\r\n\r\nx"
        }
        let body = try #require(read(mixed(["Content-Type: text/plain\r\n\r\nbody"] + files)))
        #expect(body.attachments.count == PgpMimeReader.attachmentPartCap)
        #expect(body.attachmentsOmitted)
    }

    /// A part that would cross the byte cap is dropped whole, not truncated,
    /// and a later part that fits is still kept.
    @Test func theByteCapDropsWholeParts() throws {
        let big = String(repeating: "a", count: PgpMimeReader.attachmentByteCap + 1)
        let body = try #require(read(mixed([
            "Content-Type: text/plain\r\n\r\nbody",
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=big\r\n\r\n\(big)",
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=small\r\n\r\nok",
        ])))
        #expect(body.attachments.map(\.name) == ["small"])
        #expect(body.attachmentsOmitted)
    }

    /// A files-only message whose every file was dropped still opens, so the
    /// screen can say what was left out.
    @Test func aFilesOnlyMessageKeepsItsOmissionWhenEveryFileIsDropped() throws {
        let big = String(repeating: "a", count: PgpMimeReader.attachmentByteCap + 1)
        let body = try #require(read(mixed([
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=big\r\n\r\n\(big)",
        ])))
        #expect(body.plain == "")
        #expect(body.attachments.isEmpty)
        #expect(body.attachmentsOmitted)
    }

    /// An unwrapped text part marked as an attachment is a file, not the body.
    @Test func aSinglePartTextAttachmentIsAFile() throws {
        let body = try #require(read(
            "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=notes.txt\r\n\r\nfile"
        ))
        #expect(body.plain == "")
        #expect(body.html == nil)
        #expect(body.attachments.map(\.name) == ["notes.txt"])
        #expect(body.attachments.first?.data == Data("file".utf8))
    }

    /// A Q-encoded word whose payload starts with an escaped byte.
    @Test func aQEncodedFilenameStartingWithAnEscapeDecodes() throws {
        let body = try #require(read(mixed([
            "Content-Type: text/plain\r\n\r\nx",
            "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"=?UTF-8?Q?=C3=A9t=C3=A9_1.pdf?=\"\r\n\r\n%",
        ])))
        #expect(body.attachments.map(\.name) == ["été 1.pdf"])
        #expect(PgpMimeReader.decodeEncodedWords("=?utf-8?q?=C3=A9?= and =?UTF-8?Q??=") == "é and ")
        // Malformed words are kept verbatim rather than trapping.
        #expect(PgpMimeReader.decodeEncodedWords("=?UTF-8?Q?=") == "=?UTF-8?Q?=")
    }

    @Test func aRootSignedWrapperIsDetected() throws {
        let signed = """
        Content-Type: multipart/signed; micalg=pgp-sha256; protocol="application/pgp-signature"; boundary="s"\r
        \r
        --s\r
        Content-Type: text/plain\r
        \r
        hello\r
        --s\r
        Content-Type: application/pgp-signature\r
        \r
        not even a signature\r
        --s--\r
        """
        let body = try #require(read(signed))
        #expect(body.hasDetachedSignature)
        #expect(body.plain == "hello")
        #expect(body.attachments.isEmpty)
    }

    /// Only a PGP/MIME declaration counts; S/MIME is not this app's to claim.
    @Test func anotherSignatureProtocolIsNotDetected() throws {
        let body = try #require(read(
            "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; boundary=\"s\"\r\n\r\n"
                + "--s\r\nContent-Type: text/plain\r\n\r\nhello\r\n--s--\r\n"
        ))
        #expect(!body.hasDetachedSignature)
        #expect(String(describing: body) == "DecryptedBody(redacted)")
    }
}

@MainActor private final class Flag {
    var value = false
}

/// Holds one waiter until `open()`, so a test can act while work is suspended.
private actor AsyncGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilWaiting() async {
        while waiter == nil { await Task.yield() }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
