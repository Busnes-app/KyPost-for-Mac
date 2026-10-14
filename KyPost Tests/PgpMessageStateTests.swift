//
//  PgpMessageStateTests.swift
//  KyPost Tests
//
//  Truth tables for the PGP state rule, row markers, signature-pill
//  visibility, and the webmail deep link.
//

import Foundation
import Testing
@testable import KyPost

@Suite struct PgpMessageStateRuleTests {
    @Test func plainMessageIsNone() {
        #expect(pgpMessageState(pgpEncrypted: false, pgpDecryptError: "", body: "Hello") == .none)
    }

    @Test func notEncryptedWinsEvenWithAnError() {
        // Guards against reordering the guard clause: an error on a
        // non-encrypted message is not a PGP state.
        #expect(pgpMessageState(pgpEncrypted: false, pgpDecryptError: "boom", body: nil) == .none)
    }

    @Test func encryptedWithNoBodyAndNoErrorIsClientProtected() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: nil) == .clientProtected)
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: "") == .clientProtected)
    }

    @Test func encryptedWithErrorIsDecryptFailed() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "no key", body: nil) == .decryptFailed)
    }

    @Test func errorIsCheckedBeforeBody() {
        // The ordering is load-bearing. The server populates the error and
        // leaves the body empty; if a body is somehow present too, the error
        // still wins. Reading this as decryptedByServer would render content
        // while an unreported failure sits beside it.
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "bad mac", body: "partial") == .decryptFailed)
    }

    @Test func encryptedWithBodyIsDecryptedByServer() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: "Secret") == .decryptedByServer)
    }

    @Test func whitespaceOnlyErrorAndBodyCountAsBlank() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "   ", body: " \n ") == .clientProtected)
    }
}

@Suite struct PgpRowMarkerTests {
    @Test func onlyUnreadableStatesAreMarked() {
        #expect(pgpRowSymbol(.clientProtected) == "lock.fill")
        #expect(pgpRowSymbol(.decryptFailed) == "exclamationmark.triangle.fill")
        #expect(pgpRowSymbol(.none) == nil)
        // Deliberately unmarked: the row opens and reads normally, so in a
        // server-mode mailbox this would decorate nearly every row with
        // nothing the user can act on.
        #expect(pgpRowSymbol(.decryptedByServer) == nil)
    }

    @Test func accessibilityLabelsSpellOutTheState() {
        #expect(pgpRowAccessibilityLabel(state: .clientProtected, subject: "Invoice", deviceIsEnrolled: false)
            == "Encrypted, can't be read in this app: Invoice")
        #expect(pgpRowAccessibilityLabel(state: .decryptFailed, subject: "Invoice", deviceIsEnrolled: false)
            == "Encrypted, couldn't be decrypted: Invoice")
        #expect(pgpRowAccessibilityLabel(state: .none, subject: "Invoice", deviceIsEnrolled: false) == nil)
        #expect(pgpRowAccessibilityLabel(state: .decryptedByServer, subject: "Invoice", deviceIsEnrolled: false) == nil)
    }

    /// The lock on a client-protected row means different things on an
    /// enrolled device and an unenrolled one, and the user who cannot see the
    /// screen is the one who most needs the sentence to be true.
    @Test func anEnrolledDeviceIsToldItCanUnlockRatherThanThatItCannotRead() {
        #expect(
            pgpRowAccessibilityLabel(
                state: .clientProtected, subject: "Invoice", deviceIsEnrolled: true
            ) == "Encrypted, unlock to read: Invoice"
        )
        #expect(
            pgpRowAccessibilityLabel(
                state: .clientProtected, subject: "Invoice", deviceIsEnrolled: false
            ) == "Encrypted, can't be read in this app: Invoice"
        )
        // Enrollment changes nothing about a message the server failed to
        // decrypt: no local key helps with that.
        #expect(
            pgpRowAccessibilityLabel(
                state: .decryptFailed, subject: "Invoice", deviceIsEnrolled: true
            ) == "Encrypted, couldn't be decrypted: Invoice"
        )
    }
}

@Suite struct PgpSignaturePillTests {
    @Test func shownOnlyWhenTheServerActuallyVerifiedPlaintext() {
        #expect(showsSignaturePill(state: .decryptedByServer, signed: true))
    }

    @Test func hiddenForClientProtectedEvenWhenServerClaimsSigned() {
        // THE rule most likely to be "fixed" by a later well-meaning edit.
        // For a client-protected message the server never saw the plaintext,
        // so pgpSigned/pgpVerified are not a verdict about content anyone
        // verified. Rendering "signature not verified" here would assert
        // something we have no basis for. See the design spec §1.
        #expect(showsSignaturePill(state: .clientProtected, signed: true) == false)
    }

    @Test func hiddenWhenDecryptFailed() {
        #expect(showsSignaturePill(state: .decryptFailed, signed: true) == false)
    }

    @Test func hiddenWhenNotSigned() {
        #expect(showsSignaturePill(state: .decryptedByServer, signed: false) == false)
        #expect(showsSignaturePill(state: .none, signed: false) == false)
    }
}

@Suite struct WebmailMessageURLTests {
    @Test func inboxOmitsTheMailboxParam() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "INBOX",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func inboxMatchIsCaseInsensitive() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "inbox",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func blankMailboxOmitsTheParam() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func nonInboxMailboxIsIncluded() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "Junk",
            messageId: "7"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?mailbox=Junk&message=7")
    }

    @Test func subfolderPathKeepsItsSlash() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "Archive/Receipts",
            messageId: "7"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?mailbox=Archive/Receipts&message=7")
    }

    @Test func trailingSlashOnServerUrlIsNormalized() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com/",
            mailbox: "INBOX",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func blankMessageIdIsRejected() {
        #expect(webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: "") == nil)
    }

    @Test func unusableServerUrlIsRejected() {
        // Callers render "no button" rather than a dead one.
        #expect(webmailMessageURL(serverUrl: "", mailbox: "INBOX", messageId: "42") == nil)
        #expect(webmailMessageURL(serverUrl: "not a url", mailbox: "INBOX", messageId: "42") == nil)
    }
}

// MARK: - Webmail mailbox links (compose handoff)

@Suite struct WebmailMailboxURLTests {
    @Test func draftsGetsAnExplicitMailboxParam() {
        #expect(
            webmailMailboxURL(serverUrl: "https://mail.example.com", mailbox: StandardFolder.drafts)?
                .absoluteString == "https://mail.example.com/read?mailbox=Drafts"
        )
    }

    @Test func inboxIsSentAsAnAbsentMailboxParam() {
        #expect(
            webmailMailboxURL(serverUrl: "https://mail.example.com/", mailbox: "INBOX")?
                .absoluteString == "https://mail.example.com/read"
        )
    }

    @Test func aServerUrlThatIsNotAbsoluteHasNoLink() {
        #expect(webmailMailboxURL(serverUrl: "", mailbox: "Drafts") == nil)
        #expect(webmailMailboxURL(serverUrl: "not a url", mailbox: "Drafts") == nil)
    }

    /// The message link keeps working exactly as it did — mailbox first, then
    /// message — now that both share one components builder.
    @Test func messageLinksAreUnchanged() {
        #expect(
            webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "Archive", messageId: "42")?
                .absoluteString == "https://mail.example.com/read?mailbox=Archive&message=42"
        )
        #expect(
            webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: "42")?
                .absoluteString == "https://mail.example.com/read?message=42"
        )
        #expect(webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: " ") == nil)
    }
}

// MARK: - Signature trust model (Phase 6; trust decided on this device)

@Suite struct PgpSignatureStateTests {
    /// Stands in for the OpenPGP entity-fingerprint read the crypto core
    /// supplies: maps an armored key to its primary fingerprint, and nil for
    /// a key that does not parse.
    private func fingerprints(_ table: [String: String]) -> (String) -> String? {
        { table[$0] }
    }

    private func signature(
        present: Bool = true,
        valid: Bool = true,
        fingerprint: String = "FPR1"
    ) -> RawSignature {
        RawSignature(present: present, valid: valid, signerFingerprint: fingerprint)
    }

    private func state(
        _ signature: RawSignature,
        keys: [SignerKey] = [SignerKey(publicKey: "k")],
        trust: LocalSignerTrust = .firstSeen(nil),
        table: [String: String] = ["k": "FPR1"]
    ) -> PgpSignatureState {
        signatureState(signature: signature, signerKeys: keys, trust: trust, fingerprint: fingerprints(table))
    }

    @Test func anUnsignedMessageSaysNothing() {
        #expect(state(signature(present: false)) == .none)
        #expect(state(signature(present: false), trust: .pinUnusable) == .none)
    }

    /// Not an accusation: an ordinary correspondent not yet in the address
    /// book, a rotated key, and a forgery are locally indistinguishable.
    @Test func noBoundKeyIsUnknownRatherThanInvalid() {
        #expect(state(signature(), keys: [], table: [:]) == .signerUnknown)
        // Bound keys exist, but none of them made this signature.
        #expect(state(signature(fingerprint: "FPRZ")) == .signerUnknown)
    }

    // MARK: Local history — the transitions

    /// A key only the relay vouches for, never seen here: neither identity
    /// nor continuity.
    @Test func aFirstSightingIsNotConfirmedOnThisDevice() {
        #expect(state(signature(), trust: .firstSeen(nil)) == .signerNotConfirmed)
    }

    @Test func theSameKeyAsFirstSeenIsContinuity() {
        #expect(state(signature(), trust: .firstSeen("FPR1")) == .verifiedSeenBefore)
        #expect(state(signature(fingerprint: "fpr1"), trust: .firstSeen("FPR1")) == .verifiedSeenBefore)
    }

    /// Computed from this device's history, not from any relay `conflict`.
    @Test func aDifferentKeyFromFirstSeenIsAKeyChange() {
        #expect(state(signature(), trust: .firstSeen("FPR-OLD")) == .keyChanged)
    }

    @Test func aSignatureThatDoesNotVerifyIsInvalid() {
        #expect(state(signature(valid: false)) == .invalid)
        #expect(state(signature(valid: false), trust: .firstSeen("FPR-OLD")) == .invalid)
    }

    // MARK: Pins — the only identity

    @Test func onlyAKeyPinnedOnThisDeviceClaimsIdentity() {
        #expect(state(signature(), trust: .pinned(fingerprint: "FPR1")) == .verifiedConfirmed)
    }

    @Test func aPinnedSenderSignedByAnotherKeyIsAKeyChange() {
        #expect(state(signature(), trust: .pinned(fingerprint: "FPR-PINNED")) == .keyChanged)
    }

    @Test func aRevokedOrBrokenPinIsAKeyChange() {
        #expect(state(signature(), trust: .pinUnusable) == .keyChanged)
    }

    /// The pin is authoritative: the relay's conflict flag does not move it.
    @Test func aPinIgnoresTheRelaysConflict() {
        #expect(state(
            signature(),
            keys: [SignerKey(publicKey: "k"), SignerKey(conflict: true)],
            trust: .pinned(fingerprint: "FPR1")
        ) == .verifiedConfirmed)
    }

    // MARK: The relay cannot raise trust

    /// The relay's `conflict` only ever lowers the verdict. It outranks a good
    /// key and an invalid signature, because reporting the survivor as fine
    /// would hide exactly the event worth reporting.
    @Test func theRelaysConflictCanOnlyWarn() {
        let keys = [SignerKey(publicKey: "k"), SignerKey(conflict: true)]
        #expect(state(signature(), keys: keys, trust: .firstSeen("FPR1")) == .keyChanged)
        #expect(state(signature(), keys: keys, trust: .firstSeen(nil)) == .keyChanged)
        #expect(state(signature(valid: false), keys: [SignerKey(conflict: true)], table: [:]) == .keyChanged)
    }

    /// A hostile relay omitting `conflict` cannot hide a change this device saw.
    @Test func omittingConflictDoesNotHideALocalKeyChange() {
        #expect(state(signature(fingerprint: "FPR-EVE"), trust: .firstSeen("FPR1"),
                      table: ["k": "FPR-EVE"]) == .keyChanged)
    }

    /// A message signed by a signing subkey still resolves to its key: the
    /// entity fingerprint is the same whichever component signed.
    @Test func aSubkeySignatureStillMatchesItsBoundKey() {
        #expect(state(
            RawSignature(present: true, valid: true, signerKeyID: "SUBKEY-ISSUER-ID", signerFingerprint: "FPR1"),
            trust: .pinned(fingerprint: "FPR1")
        ) == .verifiedConfirmed)
    }

    /// Fingerprints are hex and the case is the producer's choice.
    @Test func fingerprintMatchingIgnoresCase() {
        #expect(state(
            signature(fingerprint: "abcdef01"),
            trust: .pinned(fingerprint: "ABCDEF01"),
            table: ["k": "ABCDEF01"]
        ) == .verifiedConfirmed)
    }

    /// Two absences must not agree with each other.
    @Test func anAbsentFingerprintNeverMatchesAnAbsentOne() {
        #expect(state(signature(fingerprint: ""), keys: [SignerKey(publicKey: "u")],
                      trust: .pinned(fingerprint: ""), table: ["u": ""]) == .signerUnknown)
        #expect(state(signature(fingerprint: ""), keys: [SignerKey(publicKey: "u")],
                      trust: .firstSeen(""), table: [:]) == .signerUnknown)
    }

    /// An unparseable bound key must only ever shrink the candidate set.
    @Test func anUnparseableKeyGrantsNothing() {
        #expect(state(signature(), keys: [SignerKey(publicKey: "garbage")],
                      trust: .pinned(fingerprint: "FPR1"), table: [:]) == .signerUnknown)
    }
}

@Suite struct SignatureIdentityTests {
    /// The resolved sender is an identity only beside a key pinned here.
    @Test func onlyAPinnedKeyIsShownUnderTheResolvedSender() {
        let confirmed = SignatureVerdict(state: .verifiedConfirmed, resolvedSender: "bob@x.example")
        #expect(signatureIdentity(confirmed) == "bob@x.example")

        let notConfirmed = SignatureVerdict(
            state: .signerNotConfirmed, resolvedSender: "bob@x.example", keyAddresses: ["eve@evil.example"]
        )
        #expect(signatureIdentity(notConfirmed) == "key for eve@evil.example")
        #expect(signatureIdentity(SignatureVerdict(state: .verifiedSeenBefore, resolvedSender: "bob@x.example")) == nil)
    }

    @Test func aFromTheKeyDoesNotNameIsFlagged() {
        let verdict = SignatureVerdict(
            state: .verifiedSeenBefore, resolvedSender: "bob@x.example", keyAddresses: ["eve@evil.example"]
        )
        #expect(signatureIdentityMismatch(verdict, displayedFrom: "bob@x.example")?
            .contains("eve@evil.example") == true)
        #expect(signatureIdentityMismatch(verdict, displayedFrom: "Eve@Evil.example") == nil)
    }

    @Test func aConfirmedKeyIsBoundToItsPinnedAddress() {
        let verdict = SignatureVerdict(state: .verifiedConfirmed, resolvedSender: "bob@x.example")
        #expect(signatureIdentityMismatch(verdict, displayedFrom: "bob@x.example") == nil)
        #expect(signatureIdentityMismatch(verdict, displayedFrom: "alice@y.example") != nil)
    }

    @Test func noWarningWithoutAnAttributedKey() {
        #expect(signatureIdentityMismatch(SignatureVerdict(state: .signerUnknown), displayedFrom: "a@b.example") == nil)
        #expect(signatureIdentityMismatch(SignatureVerdict(state: .keyChanged), displayedFrom: "a@b.example") == nil)
        #expect(signatureIdentityMismatch(SignatureVerdict(state: .unsigned), displayedFrom: "a@b.example") == nil)
    }
}

@Suite struct SignatureRowMarkerTests {
    /// Only the two alarms mark. `signerUnknown` is the ordinary state for a
    /// correspondent not in the address book; a glyph on most rows carries
    /// nothing actionable.
    @Test func onlyTheAlarmsMarkARow() {
        #expect(signatureRowSymbol(.keyChanged) != nil)
        #expect(signatureRowSymbol(.invalid) != nil)
        #expect(signatureRowSymbol(.signerUnknown) == nil)
        #expect(signatureRowSymbol(.verifiedSeenBefore) == nil)
        #expect(signatureRowSymbol(.verifiedConfirmed) == nil)
        #expect(signatureRowSymbol(.none) == nil)
    }

    /// "The key this sender signs with is not the one you pinned" outranks
    /// "we couldn't read this".
    @Test func aSignatureAlarmOutranksTheContentState() {
        #expect(pgpRowSymbol(content: .clientProtected, signature: .keyChanged)
            == signatureRowSymbol(.keyChanged))
        #expect(pgpRowSymbol(content: .clientProtected, signature: .none)
            == pgpRowSymbol(.clientProtected))
        #expect(pgpRowSymbol(content: .none, signature: .signerUnknown) == nil)
    }

    /// Wording is the contract: continuity must not read as identity, and an
    /// unsaved key must not read as an accusation.
    @Test func theLabelsDoNotOverclaim() {
        #expect(signatureLabel(.verifiedConfirmed)?.contains("confirmed") == true)
        #expect(signatureLabel(.signerNotConfirmed)?.contains("not confirmed on this device") == true)
        #expect(!signatureIsAlarming(.signerNotConfirmed))
        #expect(signatureRowSymbol(.signerNotConfirmed) == nil)
        #expect(signatureLabel(.verifiedSeenBefore)?.contains("same key") == true)
        #expect(signatureLabel(.verifiedSeenBefore)?.lowercased().contains("verified") == false)
        #expect(signatureLabel(.none) == nil)
        #expect(signatureIsAlarming(.keyChanged))
        #expect(signatureIsAlarming(.invalid))
        #expect(!signatureIsAlarming(.signerUnknown))
    }
}
