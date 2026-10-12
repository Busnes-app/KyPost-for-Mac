//
//  SystemContactStoring.swift
//  KyPost
//
//  Thin seam over CNContactStore so SystemContactsExporter is unit-testable:
//  the real store is TCC-gated and can't run in tests.
//

import Contacts
import Foundation

protocol SystemContactStoring {
    var authorizationStatus: CNAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    /// Returns nil when the card no longer exists (deleted in Contacts.app).
    func fetch(identifier: String) async throws -> CNContact?
    /// Every card visible to the app, fetched with `SystemContactMapper.keysToFetch`.
    func listAll() async throws -> [CNContact]
    /// Caller reads `contact.identifier` afterwards to record the link.
    func add(_ contact: CNMutableContact) async throws
    func update(_ contact: CNMutableContact) async throws
    /// No-op when the card is already gone.
    func delete(identifier: String) async throws

    // MARK: - Groups

    /// Every group visible to the app.
    func listGroups() async throws -> [CNGroup]
    /// Caller reads `group.identifier` afterwards to record the link.
    func addGroup(_ group: CNMutableGroup) async throws
    func renameGroup(identifier: String, to name: String) async throws
    /// Membership of one group, as card identifiers.
    func memberIdentifiers(ofGroup identifier: String) async throws -> [String]
    func addMember(contactIdentifier: String, toGroup groupIdentifier: String) async throws
    func removeMember(contactIdentifier: String, fromGroup groupIdentifier: String) async throws
}

final class LiveSystemContactStore: SystemContactStoring {
    private let store = CNContactStore()
    /// All store traffic runs here, off the caller's thread. CNContactStore's
    /// synchronous calls block on XPC replies serviced by background-QoS
    /// threads, so calling them from a higher-QoS thread trips the
    /// priority-inversion runtime issue; the queue matches that QoS and the
    /// async callers suspend instead of blocking. Serial so save requests
    /// never interleave.
    private let queue = DispatchQueue(
        label: "LiveSystemContactStore",
        qos: .background
    )

    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    /// CNContactStore and CNContact are documented thread-safe but carry no
    /// Sendable annotation, hence the unsafe markers to cross the hop.
    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        nonisolated(unsafe) let work = work
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func fetch(identifier: String) async throws -> CNContact? {
        nonisolated(unsafe) let store = self.store
        return try await onQueue {
            do {
                return try store.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: SystemContactMapper.keysToFetch
                )
            } catch let error as CNError where error.code == .recordDoesNotExist {
                return nil
            }
        }
    }

    func listAll() async throws -> [CNContact] {
        nonisolated(unsafe) let store = self.store
        return try await onQueue {
            let request = CNContactFetchRequest(keysToFetch: SystemContactMapper.keysToFetch)
            var cards: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                cards.append(contact)
            }
            return cards
        }
    }

    func add(_ contact: CNMutableContact) async throws {
        nonisolated(unsafe) let store = self.store
        nonisolated(unsafe) let contact = contact
        try await onQueue {
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            try store.execute(request)
        }
    }

    func update(_ contact: CNMutableContact) async throws {
        nonisolated(unsafe) let store = self.store
        nonisolated(unsafe) let contact = contact
        try await onQueue {
            let request = CNSaveRequest()
            request.update(contact)
            try store.execute(request)
        }
    }

    func delete(identifier: String) async throws {
        guard let existing = try await fetch(identifier: identifier),
              let copy = existing.mutableCopy() as? CNMutableContact else { return }
        nonisolated(unsafe) let store = self.store
        nonisolated(unsafe) let mutable = copy
        try await onQueue {
            let request = CNSaveRequest()
            request.delete(mutable)
            try store.execute(request)
        }
    }
    // MARK: - Groups

    func listGroups() async throws -> [CNGroup] {
        nonisolated(unsafe) let store = self.store
        return try await onQueue {
            try store.groups(matching: nil)
        }
    }

    func addGroup(_ group: CNMutableGroup) async throws {
        nonisolated(unsafe) let store = self.store
        nonisolated(unsafe) let group = group
        try await onQueue {
            let request = CNSaveRequest()
            request.add(group, toContainerWithIdentifier: nil)
            try store.execute(request)
        }
    }

    func renameGroup(identifier: String, to name: String) async throws {
        nonisolated(unsafe) let store = self.store
        try await onQueue {
            let predicate = CNGroup.predicateForGroups(withIdentifiers: [identifier])
            guard let existing = try store.groups(matching: predicate).first,
                  let mutable = existing.mutableCopy() as? CNMutableGroup else { return }
            mutable.name = name
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
        }
    }

    func memberIdentifiers(ofGroup identifier: String) async throws -> [String] {
        nonisolated(unsafe) let store = self.store
        return try await onQueue {
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: identifier)
            // Only the identifier is needed, but keysToFetch cannot be empty.
            return try store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            ).map(\.identifier)
        }
    }

    func addMember(contactIdentifier: String, toGroup groupIdentifier: String) async throws {
        try await mutateMembership(contactIdentifier, groupIdentifier, add: true)
    }

    func removeMember(contactIdentifier: String, fromGroup groupIdentifier: String) async throws {
        try await mutateMembership(contactIdentifier, groupIdentifier, add: false)
    }

    private func mutateMembership(
        _ contactIdentifier: String,
        _ groupIdentifier: String,
        add: Bool
    ) async throws {
        nonisolated(unsafe) let store = self.store
        try await onQueue {
            let groupPredicate = CNGroup.predicateForGroups(withIdentifiers: [groupIdentifier])
            guard let group = try store.groups(matching: groupPredicate).first else { return }
            let contact = try store.unifiedContact(
                withIdentifier: contactIdentifier,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
            let request = CNSaveRequest()
            if add {
                request.addMember(contact, to: group)
            } else {
                request.removeMember(contact, from: group)
            }
            try store.execute(request)
        }
    }
}

/// A Contacts database that is never authorized and never changes. The demo
/// graph uses it so nothing it does can reach the real address book.
final class NoopSystemContactStore: SystemContactStoring {
    var authorizationStatus: CNAuthorizationStatus { .denied }
    func requestAccess() async throws -> Bool { false }
    func fetch(identifier: String) async throws -> CNContact? { nil }
    func listAll() async throws -> [CNContact] { [] }
    func add(_ contact: CNMutableContact) async throws {}
    func update(_ contact: CNMutableContact) async throws {}
    func delete(identifier: String) async throws {}
    func listGroups() async throws -> [CNGroup] { [] }
    func addGroup(_ group: CNMutableGroup) async throws {}
    func renameGroup(identifier: String, to name: String) async throws {}
    func memberIdentifiers(ofGroup identifier: String) async throws -> [String] { [] }
    func addMember(contactIdentifier: String, toGroup groupIdentifier: String) async throws {}
    func removeMember(contactIdentifier: String, fromGroup groupIdentifier: String) async throws {}
}
