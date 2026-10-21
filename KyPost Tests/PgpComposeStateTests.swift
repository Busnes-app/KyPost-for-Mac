//
//  PgpComposeStateTests.swift
//  KyPost Tests
//

import Foundation
import Testing
@testable import KyPost

@Suite(.serialized) struct PgpComposeStateTests {

    /// Unknown hides everything: guessing "server" offers a toggle that 409s,
    /// and guessing "client" sends people to webmail for no reason.
    @Test func anUnreachableBootstrapOffersNothing() {
        let state = pgpComposeState(hasIdentity: nil, protection: nil)
        #expect(state == PgpComposeState(canEncrypt: false, canSign: false, handoffToWebmail: false))
    }

    @Test func noIdentityOffersNothing() {
        let state = pgpComposeState(hasIdentity: false, protection: "server")
        #expect(!state.canEncrypt)
        #expect(!state.handoffToWebmail)
    }

    @Test func serverCustodyEncryptsThroughTheRelay() {
        let state = pgpComposeState(hasIdentity: true, protection: "server")
        #expect(state.canEncrypt)
        #expect(state.canSign)
        #expect(!state.clientSide)
    }

    @Test func clientCustodyOnAnUnenrolledDeviceHandsOffToWebmail() {
        let state = pgpComposeState(hasIdentity: true, protection: "client", deviceEnrolled: false)
        #expect(state.handoffToWebmail)
        #expect(!state.clientSide)
    }

    @Test func clientCustodyOnAnEnrolledDeviceEncryptsHere() {
        let state = pgpComposeState(
            hasIdentity: true,
            protection: "client",
            deviceEnrolled: true,
            accountAddress: "me@example.com"
        )
        #expect(state.clientSide)
        #expect(state.canEncrypt)
        #expect(state.canSign)
        #expect(!state.handoffToWebmail)
    }

    /// No account address means no delivery `From` can be built, and the relay
    /// answers 403. Falling back to the handoff beats offering a Send that is
    /// certain to be refused.
    @Test func anEnrolledDeviceWithNoAccountAddressStillHandsOff() {
        let state = pgpComposeState(
            hasIdentity: true, protection: "client", deviceEnrolled: true, accountAddress: "   "
        )
        #expect(state.handoffToWebmail)
        #expect(!state.clientSide)
    }

    /// Degrade, never guess.
    @Test func anUnrecognisedProtectionOffersNothing() {
        let state = pgpComposeState(hasIdentity: true, protection: "something-new")
        #expect(!state.canEncrypt)
        #expect(!state.handoffToWebmail)
        #expect(!state.clientSide)
    }
}

@Suite(.serialized) struct RecipientFieldsTests {

    @Test func eachFieldStaysDistinct() {
        let fields = splitRecipientFields(to: "a@x, b@x", cc: "c@x", bcc: "d@x")
        #expect(fields.to == ["a@x", "b@x"])
        #expect(fields.cc == ["c@x"])
        #expect(fields.bcc == ["d@x"])
    }

    /// **The reason this is not the preflight's splitter.** Collapsing the
    /// three fields would put someone the sender marked blind into a header
    /// every other recipient reads.
    @Test func aBccRecipientIsNeverPromotedIntoTo() {
        let fields = splitRecipientFields(to: "", cc: "", bcc: "blind@x")
        #expect(fields.to.isEmpty)
        #expect(fields.bcc == ["blind@x"])
    }

    /// Overlap resolves by precedence rather than being kept: a duplicate
    /// would build a second redundant delivery *and* leave the sender
    /// believing the extra copy was blind while To already names them.
    @Test func overlapResolvesToFirstThenCcThenBcc() {
        let fields = splitRecipientFields(to: "a@x", cc: "a@x, b@x", bcc: "a@x, b@x, c@x")
        #expect(fields.to == ["a@x"])
        #expect(fields.cc == ["b@x"])
        #expect(fields.bcc == ["c@x"])
    }

    @Test func overlapIsCaseInsensitiveButKeepsTheTypedSpelling() {
        let fields = splitRecipientFields(to: "Alice@X", cc: "alice@x", bcc: "")
        #expect(fields.to == ["Alice@X"])
        #expect(fields.cc.isEmpty)
    }

    @Test func blanksAndStrayCommasAreDropped() {
        let fields = splitRecipientFields(to: " a@x , , b@x ,", cc: "  ", bcc: "")
        #expect(fields.to == ["a@x", "b@x"])
        #expect(fields.cc.isEmpty)
    }
}

// MARK: - Re-derivation

/// **Cache the bootstrap, not the composed state.** Custody is fixed when the
/// key is created, so the bootstrap answer is worth keeping — but enrollment
/// can change while the app runs, and a state computed once at launch would
/// keep offering an on-device send after the key was wiped, or keep hiding it
/// after the user enrolled.
@Suite(.serialized) struct PgpComposeStateFreshnessTests {

    @Test func enrollingFlipsTheSameBootstrapToClientSide() {
        let before = pgpComposeState(
            hasIdentity: true,
            protection: "client",
            deviceEnrolled: false,
            accountAddress: "me@example.com"
        )
        let after = pgpComposeState(
            hasIdentity: true,
            protection: "client",
            deviceEnrolled: true,
            accountAddress: "me@example.com"
        )
        #expect(before.handoffToWebmail)
        #expect(!before.clientSide)
        #expect(after.clientSide)
        #expect(!after.handoffToWebmail)
    }

    /// The direction that matters more: a wipe must take the on-device send
    /// away again, not leave a Send that cannot work.
    @Test func aWipedKeyTakesTheOnDeviceSendAway() {
        let afterWipe = pgpComposeState(
            hasIdentity: true,
            protection: "client",
            deviceEnrolled: false,
            accountAddress: "me@example.com"
        )
        #expect(!afterWipe.clientSide)
        #expect(afterWipe.handoffToWebmail)
    }

    // MARK: - Draft handoff (Android draftHandoffMode)

    @Test func theDraftHandoffTable() {
        func mode(_ hasIdentity: Bool?, _ protection: String?, enrolled: Bool, _ address: String = "me@example.com") -> DraftHandoffMode {
            draftHandoffMode(hasIdentity: hasIdentity, protection: protection, enrolled: enrolled, accountAddress: address)
        }
        // No identity, or unknown: refuse, enrolled or not.
        for enrolled in [false, true] {
            #expect(mode(nil, "client", enrolled: enrolled) == .refuse)
            #expect(mode(false, "client", enrolled: enrolled) == .refuse)
            // Anything but client custody: refuse.
            #expect(mode(true, "server", enrolled: enrolled) == .refuse)
            #expect(mode(true, nil, enrolled: enrolled) == .refuse)
            #expect(mode(true, "hybrid", enrolled: enrolled) == .refuse)
        }
        #expect(mode(true, "client", enrolled: false) == .openWithoutSave)
        #expect(mode(true, "client", enrolled: false, "") == .openWithoutSave)
        #expect(mode(true, "client", enrolled: true, "  ") == .refuse)
        #expect(mode(true, "client", enrolled: true) == .encryptAndSave)
    }

    // MARK: - Save Draft (Linux trySaveDraft)

    @Test func theDraftSaveTable() {
        func mode(_ hasIdentity: Bool?, _ protection: String?, enrolled: Bool = true, _ address: String = "me@x") -> DraftSaveMode {
            draftSaveMode(hasIdentity: hasIdentity, protection: protection, enrolled: enrolled, accountAddress: address)
        }
        #expect(mode(true, "client") == .encrypted)
        #expect(mode(true, "client", enrolled: false) == .unavailable)
        #expect(mode(true, "client", "  ") == .unavailable)
        for enrolled in [false, true] {
            for address in ["", "me@x"] {
                #expect(mode(true, "server", enrolled: enrolled, address) == .plain)
            }
        }
        #expect(mode(false, nil) == .plain)
        #expect(mode(false, "") == .plain)
        #expect(mode(false, "client") == .unavailable)
        // Unknown never reads as plain: not loaded, failed, or unrecognised.
        #expect(mode(nil, nil) == .unavailable)
        #expect(mode(nil, "server") == .unavailable)
        #expect(mode(true, nil) == .unavailable)
        #expect(mode(true, "") == .unavailable)
        #expect(mode(true, "future") == .unavailable)
    }
}
