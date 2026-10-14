//
//  AccountTeardown.swift
//  KyPost
//
//  What leaving an account erases from this device. One list, run by an
//  unpair (SettingsViewModel.unpair) and by a registration that pairs another
//  account over this one (DeviceRegistrationService.onAccountReplaced), so the
//  two can never drift apart.
//

import Foundation
import os

@MainActor
struct AccountTeardown {
    var enrollmentVault: EnrollmentVault?
    var pushRepository: PushRepository?
    var recipientPinStore: RecipientPinStore?
    var mailSignatureStore: MailSignatureStore?
    var mailRepository: MailRepository?
    /// Account state held outside the stores — the inbox's held list
    /// actions, rows on screen and in-flight refreshes
    /// (`InboxViewModel.forgetAccount`).
    var forgetInbox: (() -> Void)?

    /// Runs every step; a failing step is logged and the rest still run.
    /// Returns false when any step failed, so the caller cannot report the
    /// account as gone while some of its data is still here.
    @discardableResult
    func run() async -> Bool {
        var complete = true
        // First, before any suspension: a list action still in its undo
        // window belongs to the account being left, and its timer could
        // otherwise commit it — with the credentials it was bound to —
        // while a later step awaits. Dropped, not sent.
        forgetInbox?()
        // The envelope is the account's private key sealed to *this* device;
        // left behind, it outlives the pairing that authorised putting it
        // here. The in-memory copy goes with it — destroying the sealed blob
        // while an unsealed one sits in this process would be theatre.
        enrollmentVault?.destroy()
        // No device row is left to correct, and a pending marker must not
        // speak for whatever device is paired next.
        enrollmentVault?.forgetPendingReports()
        EnrollmentSession.shared.clear()
        // Notification history is the account's sender and subject lines,
        // and the pull cursor is a position in the account's queue.
        do {
            try await pushRepository?.clearForUnpair()
        } catch {
            Log.push.error("Could not clear notification history on leaving the account: \(error)")
            complete = false
        }
        // Keys verified by QR belong to this account's address book.
        recipientPinStore?.clear()
        // The signature belongs to the account being left, not the next.
        mailSignatureStore?.clear()
        // The account's mail — every cached row and body, in or out of the
        // window, and the cursors. Mail older than the window is never pruned
        // by a refresh, so left here it would be listed under the next
        // account.
        do {
            try await mailRepository?.forgetAccount()
        } catch {
            Log.mail.error("Could not clear cached mail on leaving the account: \(error)")
            complete = false
        }
        // Relay responses an older build's `.default` session cached on disk,
        // and any cookies it kept. The relay session no longer writes either.
        PinnedSessionDelegate.purgeLegacySharedHTTPState()
        // Again, now the cache is empty: rows the inbox repainted from it
        // while a step above awaited are the account just left.
        forgetInbox?()
        return complete
    }
}
