//
//  DeviceVaultOpener.swift
//  KyPost
//
//  The real `VaultOpening`: opens the sealed record with the Secure Enclave
//  device key, which is where the user-presence prompt happens — at most once
//  per app unlock (`PresenceContext`). A plaintext record from an earlier
//  build is re-sealed on this first presence-checked open.
//
//  Separate from EnrollmentVault so EncryptedMessageReader stays free of
//  platform imports — the reader talks to the protocol, and this is the only
//  place the Security framework's failure modes get turned into exit-table
//  rows.
//

import Foundation

nonisolated struct DeviceVaultOpener: VaultOpening {
    private let vault: EnrollmentVault
    private let inspector: any PgpKeyInspecting

    init(vault: EnrollmentVault, inspector: any PgpKeyInspecting) {
        self.vault = vault
        self.inspector = inspector
    }

    func open() async -> VaultOpenOutcome {
        // Off the calling actor: the Secure Enclave operation blocks until the
        // user answers the presence prompt, and doing that on the main actor
        // freezes the window the prompt is attached to.
        await Task.detached(priority: .userInitiated) {
            do {
                guard let record = try vault.openRecord() else { return .notEnrolled }
                switch record.kind {
                case .legacyArmor:
                    return VaultOpenOutcome.opened(.legacyArmor(record.material))
                case .keyring:
                    // The record's kind decides how its bytes are read; the
                    // bytes are never sniffed. A keyring record that no longer
                    // reopens as one is a broken record, not legacy armor.
                    guard let ring = reopenPgpKeyring(record.material, inspector: inspector) else {
                        return .failed("the keys stored on this device could not be read")
                    }
                    return .opened(.keyring(ring))
                }
            } catch EnrollmentVaultError.notEnrolled {
                return .notEnrolled
            } catch EnrollmentVaultError.noDeviceCredential {
                return .noSecureLockScreen
            } catch EnrollmentVaultError.cancelled {
                // Dismissing the prompt is a decision, not a failure.
                return .cancelled
            } catch EnrollmentVaultError.unavailable {
                return .failed("this device's secure hardware is unavailable")
            } catch let EnrollmentVaultError.keychain(status) {
                // `errSecUserCanceled` reaches here when the prompt is
                // dismissed by the system rather than by the vault's own
                // mapping. Treated as cancellation for the same reason: the
                // screen goes back to offering Decrypt rather than accusing
                // the device of a fault.
                if status == errSecUserCanceled { return .cancelled }
                return .failed("the key on this device could not be opened (\(status))")
            } catch {
                return .failed("the key on this device could not be opened")
            }
        }.value
    }
}
