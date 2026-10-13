//
//  SecurityWipeSteps.swift
//  KyPost
//
//  What a security wipe actually destroys. `SecurityWipe` owns the marker, the
//  fault isolation and the resume ceiling; this file owns the list, and is the
//  only half that touches SwiftData, Contacts, the Keychain and the file
//  system.
//
//  **Order is the point: local plaintext first, network last.** An attacker
//  holding the machine can force-quit at any moment, so anything that blocks —
//  above all the relay round trip — has to come after the destruction, not
//  before it. The deregister is not in this list at all; see
//  `AppEnvironment.performSecurityWipe`.
//
//  Nothing here catches its own errors. A step that cannot fail is a step that
//  cannot be reported, and `WipeResult.complete` is the one claim in this app
//  that must never be made falsely.
//

import Foundation
import UserNotifications

@MainActor
enum SecurityWipeSteps {
    /// `defaultsDomain` is the persistent domain the sweep clears — the bundle
    /// identifier in the app, a scratch suite in tests. Everything under
    /// `WipeStateStore.retainedKeyPrefix` survives it, because the record of
    /// what a wipe still owes must outlive the wipe's own deletions.
    static func build(graph: SingletonGraph, defaultsDomain: String?) -> [WipeStep] {
        var steps: [WipeStep] = []

        // The in-memory plaintext leads: it needs no I/O and is the most
        // sensitive thing here. The unsealed OpenPGP key and an open draft (a
        // reply's body is the full quoted plaintext of the message it answers)
        // both live in this process, which the wipe does not kill — it rebuilds
        // the graph, so anything not dropped here is still readable in the
        // attacker's session.
        steps.append(WipeStep("inMemoryPlaintext") {
            EnrollmentSession.shared.clear()
            guard !EnrollmentSession.shared.isHeld else {
                throw WipeStepFailure("the opened private key is still held in memory")
            }
            // A forward's attachments waiting for their compose window.
            ForwardAttachmentHandoff.shared.clear()
            guard !ForwardAttachmentHandoff.shared.isHoldingAttachments else {
                throw WipeStepFailure("forwarded attachments are still held in memory")
            }
            NotificationCenter.default.post(name: .kyPostCloseComposeWindows, object: nil)
            // List actions still in their undo window are dropped, not sent:
            // the wipe's own steps await, and a window closing mid-wipe must
            // not act on an account the user is erasing from this machine.
            graph.inboxViewModel.forgetAccount()
        })

        // Message bodies, contacts and the push history. Deleted while the
        // container still has the file open: the unlink succeeds, and the
        // caller's graph rebuild is what closes the descriptor — which is why
        // `performSecurityWipe` rebuilds rather than leaving it to the UI.
        steps.append(WipeStep("database") { try AppDatabase.deleteStoreFiles() })
        steps.append(WipeStep("contactPhotos") { try ContactPhotoCache.deleteAll() })
        steps.append(WipeStep("attachmentTempFiles") { try InboxViewModel.deleteAttachmentTempFiles() })

        // Sender and subject of everything already delivered sit in
        // Notification Center, readable with no forensics at all.
        steps.append(WipeStep("deliveredNotifications") {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        })

        // Before the defaults sweep, which takes the link store the deletes are
        // driven from — the same ordering mistake Android made and fixed.
        //
        // This is the one thing a wipe destroys that lives **outside this app's
        // sandbox**: real names, phone numbers and addresses in the user's own
        // Contacts database. An unauthorised app cannot touch them, so with
        // links still on file that is a failure, not a no-op.
        steps.append(WipeStep("deviceContactCards") {
            let exporter = graph.systemContactsExporter
            guard exporter.hasExportedContacts() else { return }
            guard exporter.isAuthorized else {
                throw WipeStepFailure("Contacts access is not granted, so exported cards cannot be removed")
            }
            let summary = await exporter.removeAllExported()
            guard summary.failed == 0 else {
                throw WipeStepFailure("\(summary.failed) exported contact cards could not be deleted")
            }
        })

        // The account's OpenPGP private key. A named step with a real failure
        // list, because a key surviving a wipe nobody chose is exactly what an
        // incomplete result exists to report.
        steps.append(WipeStep("enrollmentVault") {
            // The wipe also removes the pairing, so a pending report marker
            // has no device row left to correct.
            let leftBehind = graph.enrollmentVault.destroyReportingFailures()
                + graph.enrollmentVault.forgetPendingReports()
            guard leftBehind.isEmpty else {
                throw WipeStepFailure("enrollment vault left \(leftBehind.joined(separator: ", "))")
            }
        })

        // The PIN verifier's device key. It seals nothing on its own, but a
        // Keychain entry outliving a wipe is worth reporting whatever it holds.
        steps.append(WipeStep("pinPepper") {
            let leftBehind = DevicePinPepper(keychain: graph.keychain).destroy()
            guard leftBehind.isEmpty else {
                throw WipeStepFailure("PIN pepper left \(leftBehind.joined(separator: ", "))")
            }
        })

        // The gated copy and the gate flag go before the pairing: `removeAll`
        // routes through the gate, and it must not be the only thing that
        // removes the gated secret.
        steps.append(WipeStep("credentialGate") {
            let leftBehind = graph.credentialGateService.removeAll()
            guard leftBehind.isEmpty else {
                throw WipeStepFailure("credential gate left \(leftBehind.joined(separator: ", "))")
            }
        })
        steps.append(WipeStep("pairing") {
            try graph.securePairingStore.clear()
            try graph.desktopSessionStore.clear()
        })

        // Explicit, and not left to the defaults sweep below: under Hostile
        // Location Protection this store is memory-only, so sweeping the
        // defaults domain would clear nothing at all in exactly the mode that
        // promises this machine holds nothing.
        steps.append(WipeStep("mailCursors") { graph.mailCursorStore.clear() })
        // Account data, cleared by name rather than left to the sweep, so the
        // wipe's claim does not depend on which defaults domain it lives in.
        steps.append(WipeStep("mailSignature") {
            graph.mailSignatureStore.clear()
            guard graph.mailSignatureStore.signature.isEmpty else {
                throw WipeStepFailure("the mail signature survived")
            }
        })

        steps.append(WipeStep("appLock") { try graph.appLockStore.reset() })

        // Last of the local steps, because several above read state that lives
        // here. Cursor keys are server folder *paths*, so they leak the folder
        // taxonomy the user has opened; the link stores map this app's contacts
        // to cards in the OS database; the keyword store holds every label the
        // server has ever applied.
        steps.append(WipeStep("userDefaults") {
            guard let defaultsDomain else { return }
            let defaults = graph.userDefaults
            guard let domain = defaults.persistentDomain(forName: defaultsDomain) else { return }
            for key in domain.keys where !key.hasPrefix(WipeStateStore.retainedKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
            let remaining = (defaults.persistentDomain(forName: defaultsDomain) ?? [:])
                .keys.filter { !$0.hasPrefix(WipeStateStore.retainedKeyPrefix) }
            guard remaining.isEmpty else {
                throw WipeStepFailure("preferences survived the sweep: \(remaining.sorted())")
            }
        })

        return steps
    }
}

/// What a wipe step throws when the thing it was asked to destroy is still
/// there. A distinct type so the message reaching the log says what survived,
/// rather than an `NSError` describing the API that reported it.
nonisolated struct WipeStepFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
