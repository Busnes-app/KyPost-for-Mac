//
//  CredentialGateService.swift
//  KyPost
//
//  Feature 3, "Require unlock for notifications & MFA" (security-hardening
//  plan, Task 6). While on, the device secret lives only in an access-
//  controlled Keychain item (user presence required) plus an in-memory copy
//  that exists solely while the app is unlocked. Background pull/push/MFA
//  while locked finds MailSourceError.credentialUnavailable and no-ops,
//  retrying after the next unlock.
//
//  When the gate is off (default), nothing here is wired and the pairing
//  store behaves exactly as before.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class CredentialGateService {
    private let appLockStore: AppLockStore
    private let securePairingStore: SecurePairingStore
    private let gatedStore: any GatedCredentialStoring
    private let lockManager: AppLockManager

    /// Observable mirror of AppLockStore.credentialGateEnabled.
    private(set) var isEnabled: Bool

    init(
        appLockStore: AppLockStore,
        securePairingStore: SecurePairingStore,
        gatedStore: any GatedCredentialStoring,
        lockManager: AppLockManager
    ) {
        self.appLockStore = appLockStore
        self.securePairingStore = securePairingStore
        self.gatedStore = gatedStore
        self.lockManager = lockManager
        isEnabled = appLockStore.credentialGateEnabled
    }

    /// Re-installs the gate hooks on launch when the flag was already on.
    /// Must run before the first poll (PushLifecycle.onLaunch).
    ///
    /// Also the repair point for the one state the gate cannot escape on its
    /// own: enabled *without* the app lock. The gate's toggle is disabled
    /// while the lock is off, and `AppLockManager.requestUnlock` returns early
    /// when `isLocked` is false, so the in-memory secret can never be
    /// repopulated — every relay call would throw `credentialUnavailable`
    /// forever. Settings refuses to create that state (see
    /// SecuritySettingsView), so reaching it means a write failed partway;
    /// relaunching resolves it with one presence prompt.
    /// The repair is driven by `lockState`, not `lockEnabled`: only a flag that
    /// was *successfully read as off* means the user turned the lock off. A
    /// Keychain read that failed must fail closed and leave the gate wired,
    /// because the repair's side effect is writing the device secret back into
    /// the plain, non-presence-gated item — a downgrade no transient error
    /// should be able to trigger.
    func wireAtLaunch() {
        guard isEnabled else { return }
        switch appLockStore.lockState {
        case .off:
            if disable() { return }
            wire()
        case .unreadable:
            Log.app.error("Could not read the app-lock flag at launch; keeping the credential gate wired")
            wire()
        case .on:
            wire()
        }
    }

    /// Moves the device secret behind user presence. The running session
    /// keeps its secret in memory, so nothing stops working until the next
    /// lock. Returns false when there is nothing to gate (unpaired or an
    /// empty pre-migration secret) or persistence fails.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard let pairing = try? securePairingStore.loadPairing(),
              !pairing.deviceSecret.isEmpty
        else { return false }
        do {
            try gatedStore.store(pairing.deviceSecret)
            try securePairingStore.setDeviceSecret("")
            try appLockStore.setCredentialGateEnabled(true)
        } catch {
            Log.app.error("Could not enable the credential gate: \(error.localizedDescription)")
            // The plain secret stays the source of truth until every step
            // lands — but restore it *before* giving up the gated copy, and
            // only give that copy up once the restore provably succeeded.
            // These failures are correlated, not independent: the step that
            // threw was a Keychain write, and so is the restore. Removing on
            // a failed restore leaves the device secret nowhere at all, with
            // re-pairing the only way back.
            do {
                try securePairingStore.setDeviceSecret(pairing.deviceSecret)
                try? gatedStore.remove()
            } catch {
                Log.app.error(
                    "Rollback could not restore the plain device secret; keeping the gated copy as the only surviving one: \(error.localizedDescription)"
                )
            }
            return false
        }
        isEnabled = true
        lockManager.cacheGatedSecret(pairing.deviceSecret)
        wire()
        return true
    }

    /// Restores the plain secret (one user-presence read when the in-memory
    /// copy is gone) and removes the gated item.
    @discardableResult
    func disable() -> Bool {
        guard isEnabled else { return true }
        let secret = lockManager.cachedGatedSecret ?? ((try? gatedStore.load()) ?? nil)
        guard let secret else { return false }
        do {
            try securePairingStore.setDeviceSecret(secret)
            try appLockStore.setCredentialGateEnabled(false)
        } catch {
            Log.app.error("Could not disable the credential gate: \(error.localizedDescription)")
            return false
        }
        // Past this point the gate is off no matter what: the plain secret is
        // back and the flag is cleared. A stranded gated copy holds the same
        // value the plain item now does — not a new exposure, and `store()`
        // overwrites it on the next enable — so it must not turn into a
        // reported failure that leaves the caller's UI disagreeing with the
        // state actually persisted.
        do {
            try gatedStore.remove()
        } catch {
            Log.app.error("Left the gated device-secret copy behind: \(error.localizedDescription)")
        }
        isEnabled = false
        lockManager.cacheGatedSecret(nil)
        unwire()
        return true
    }

    private func wire() {
        securePairingStore.secretGate = self
        lockManager.loadGatedSecret = { [gatedStore] in
            (try? gatedStore.load()) ?? nil
        }
    }

    private func unwire() {
        securePairingStore.secretGate = nil
        lockManager.loadGatedSecret = nil
    }
}

extension CredentialGateService: PairingSecretGate {
    func read() throws -> String {
        guard let secret = lockManager.cachedGatedSecret else {
            throw MailSourceError.credentialUnavailable
        }
        return secret
    }

    func write(_ secret: String) throws {
        try gatedStore.store(secret)
        // A re-registration can land after the lock engaged; the secret then
        // waits behind user presence like any other, never in memory.
        if !lockManager.isLocked {
            lockManager.cacheGatedSecret(secret)
        }
    }

    /// Unpair: the gated copy goes with the pairing.
    ///
    /// Returns the names of anything it could not remove, and keeps going past
    /// the first failure. `SecurityWipe` needs the names — a step that cannot
    /// fail cannot be reported, and the pairing credential surviving a wipe is
    /// exactly what an incomplete result exists to say. Callers that are simply
    /// tidying up may discard the result.
    @discardableResult
    func removeAll() -> [String] {
        var failures: [String] = []
        do { try gatedStore.remove() } catch { failures.append("deleteGatedSecret") }
        do { try appLockStore.setCredentialGateEnabled(false) } catch {
            failures.append("clearCredentialGateFlag")
        }
        isEnabled = false
        lockManager.cacheGatedSecret(nil)
        unwire()
        return failures
    }
}
