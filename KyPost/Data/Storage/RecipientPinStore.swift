//
//  RecipientPinStore.swift
//  KyPost
//
//  Keys verified **on this device** by QR, per address (Android #191,
//  `recipient_pins`). Per address, a pinned key is authoritative: the reader
//  checks signatures against it alone and the sender encrypts to it alone; a
//  synced contact key cannot stand in for it.
//
//  Writers, and there are only two:
//  - the QR flow (`ContactSyncRepository.saveContact(_:verifiedInPerson:)`),
//    which replaces the pins for that contact's addresses — re-scanning is how
//    a pin changes;
//  - revocation (`recordRevocations`), which may only add verified revocation
//    signatures to a pin's own bytes.
//  Sync never writes here otherwise, so a relay rewriting or deleting the
//  contact does not move the pin.
//
//  It also keeps the **first-seen signer history** (`SignerKeyHistory`): per
//  sender address, the fingerprint of the first key this device saw make a
//  valid signature for it. That is what "same key as last time" and "key
//  changed" are computed from, on the device — never from the relay. Its only
//  writer is the reader, and only for a key that names the address itself.
//  A pin outranks it.
//
//  Public keys are not secrets, but which addresses this user verified, and
//  who has written to them, is their address book: both are memory-only under
//  Hostile Location Protection, swept by the security wipe, cleared on unpair.
//

import Foundation
import os

nonisolated struct RecipientPin: Codable, Equatable, Sendable {
    var publicKey: String
    /// Computed from `publicKey` when pinned. A pin is trusted only while its
    /// bytes still fingerprint to this.
    var fingerprint: String
}

/// The first key this device saw sign for an address.
nonisolated struct FirstSeenSigner: Codable, Equatable, Sendable {
    var fingerprint: String
    var firstSeen: Date
}

/// The on-device signer history the reader computes continuity from.
protocol SignerKeyHistory: Sendable {
    func firstSeenFingerprint(for address: String) -> String?
    /// Advanced by every clear (unpair, the security wipe). A read takes it
    /// before it fetches and hands it back to `recordFirstSeen`.
    var generation: UInt64 { get }
    /// Records `fingerprint` for `address` unless one is already recorded, or
    /// the history was cleared since `generation` was read — a read that
    /// outlives the account's teardown must not write the erased history
    /// back. History is never overwritten: a different key later is
    /// `keyChanged`, and only a QR pin supersedes it.
    func recordFirstSeen(_ fingerprint: String, for address: String, ifGeneration generation: UInt64)
}

final class RecipientPinStore: @unchecked Sendable, SignerKeyHistory {
    private static let key = "contacts.recipientPins"
    private static let historyKey = "contacts.signerFirstSeen"

    private let defaults: UserDefaults
    private let hostileLocation: HostileLocationProtectionStore
    private let lock = NSLock()
    private var memoryPins: [String: RecipientPin] = [:]
    private var memoryHistory: [String: FirstSeenSigner] = [:]
    private var historyGeneration: UInt64 = 0

    init(defaults: UserDefaults, hostileLocation: HostileLocationProtectionStore) {
        self.defaults = defaults
        self.hostileLocation = hostileLocation
    }

    nonisolated static func normalized(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func pin(for address: String) -> RecipientPin? {
        all()[Self.normalized(address)]
    }

    func all() -> [String: RecipientPin] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked() ?? [:]
    }

    /// True when pins are stored but cannot be decoded (a corrupt or
    /// future-format defaults value). Every write is refused while this
    /// holds: writing would replace the whole map with the one or two pins
    /// being added, and every other verified key would be gone for good.
    var persistedPinsUnreadable: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked() == nil
    }

    /// The stored pins, or nil when they exist but will not decode. Caller
    /// holds `lock`.
    private func loadLocked() -> [String: RecipientPin]? {
        if hostileLocation.enabled { return memoryPins }
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return try? JSONDecoder().decode([String: RecipientPin].self, from: data)
    }

    /// Pins `publicKey` for every address in `addresses`, replacing whatever
    /// was pinned for them. Refuses a key whose fingerprint cannot be
    /// computed: a pin that cannot be checked is not a pin. False, too, when
    /// the stored pins cannot be read (`persistedPinsUnreadable`).
    @discardableResult
    func pin(addresses: [String], publicKey: String) -> Bool {
        guard let fingerprint = PgpFingerprint.compute(fromArmored: publicKey) else { return false }
        let targets = addresses.map(Self.normalized).filter { !$0.isEmpty }
        guard !targets.isEmpty else { return false }
        return update { pins in
            for address in targets {
                pins[address] = RecipientPin(publicKey: publicKey, fingerprint: fingerprint)
            }
        }
    }

    /// Replaces a pin's bytes with the same key carrying more revocations.
    /// Refused unless the new bytes fingerprint to the pinned fingerprint.
    func replaceRevoked(address: String, with publicKey: String) {
        let target = Self.normalized(address)
        update { pins in
            guard let current = pins[target],
                  PgpFingerprint.compute(fromArmored: publicKey) == current.fingerprint
            else { return }
            pins[target] = RecipientPin(publicKey: publicKey, fingerprint: current.fingerprint)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        historyGeneration &+= 1
        memoryPins = [:]
        memoryHistory = [:]
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.historyKey)
    }

    /// Erases the on-disk copies and keeps the in-memory ones. Under Hostile
    /// Location Protection reads switch to memory but nothing else removes
    /// what was written before, so this runs when the mode is turned on and
    /// at every launch while it is on (`AppEnvironment.eraseHostileLocationDefaults`).
    func clearPersisted() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.historyKey)
    }

    // MARK: - First-seen signer history

    func firstSeenFingerprint(for address: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return historyLocked()[Self.normalized(address)]?.fingerprint
    }

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return historyGeneration
    }

    func recordFirstSeen(_ fingerprint: String, for address: String, ifGeneration generation: UInt64) {
        let target = Self.normalized(address)
        let value = fingerprint.uppercased()
        guard !target.isEmpty, !value.isEmpty else { return }
        // The check and the write share the lock `clear()` takes, so a clear
        // cannot land between them.
        lock.lock(); defer { lock.unlock() }
        guard generation == historyGeneration else { return }
        var history = historyLocked()
        guard history[target] == nil else { return }
        history[target] = FirstSeenSigner(fingerprint: value, firstSeen: Date())
        if hostileLocation.enabled {
            memoryHistory = history
        } else if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }

    private func historyLocked() -> [String: FirstSeenSigner] {
        if hostileLocation.enabled { return memoryHistory }
        guard let data = defaults.data(forKey: Self.historyKey),
              let history = try? JSONDecoder().decode([String: FirstSeenSigner].self, from: data)
        else { return [:] }
        return history
    }

    /// What the reader and sender consume: each pin resolved once to intact,
    /// revoked or broken. A value, so they can carry it off the main actor.
    func snapshot(revocation: any PgpKeyRevocation) -> RecipientPinSnapshot {
        RecipientPinSnapshot(states: all().mapValues { pin in
            guard PgpFingerprint.compute(fromArmored: pin.publicKey) == pin.fingerprint else {
                return .broken
            }
            if revocation.isPrimaryRevoked(armoredPublicKey: pin.publicKey) { return .revoked }
            return .intact(publicKey: pin.publicKey, fingerprint: pin.fingerprint)
        })
    }

    /// Read, change and write under one lock. Refuses — and leaves the
    /// stored bytes exactly as they were — when they will not decode.
    @discardableResult
    private func update(_ body: (inout [String: RecipientPin]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var pins = loadLocked() else {
            Log.storage.error("Recipient pins are stored but unreadable; refusing to overwrite them")
            return false
        }
        body(&pins)
        if hostileLocation.enabled {
            memoryPins = pins
        } else if let data = try? JSONEncoder().encode(pins) {
            defaults.set(data, forKey: Self.key)
        } else {
            return false
        }
        return true
    }
}

nonisolated enum PinnedKeyState: Equatable, Sendable {
    case intact(publicKey: String, fingerprint: String)
    /// Its owner revoked the primary key, and the revocation verified.
    case revoked
    /// The stored bytes no longer fingerprint to what was pinned.
    case broken
}

nonisolated struct RecipientPinSnapshot: Equatable, Sendable {
    var states: [String: PinnedKeyState] = [:]

    static let none = RecipientPinSnapshot()

    func state(for address: String) -> PinnedKeyState? {
        states[RecipientPinStore.normalized(address)]
    }
}

/// A pin write refused because the stored pins cannot be read.
nonisolated enum RecipientPinStoreError: Error, LocalizedError, Equatable {
    case unreadable

    var errorDescription: String? {
        String(localized: """
        The contact was saved, but its verified key was not recorded on this device: the keys \
        already verified here can't be read, and recording this one would erase them.
        """)
    }
}
