//
//  ContactSyncReconciliation.swift
//  KyPost
//
//  Reconciles locally-created contacts with server-assigned uids after a sync
//  (spec §4, Android ContactSyncReconciliation.kt). Each create carries its
//  localId as `clientRef`; a response entry echoing a pending create's
//  `clientRef` is that create, exactly. The relay does not echo it yet, so the
//  fallback is content — fn, org, and the full email/phone value lists —
//  claiming the first unclaimed exact match per pending create, like the
//  Android reference. An entry echoing a *different* `clientRef` belongs to
//  another create and is never a content match. There is deliberately NO
//  positional fallback: a push response carries every change since
//  baseCursor (other devices' edits included), so pairing leftovers by order
//  stamps an unrelated contact's uid onto a local create and duplicates that
//  contact locally.
//

import Foundation

enum ContactSyncReconciliation {
    struct Assignment: Equatable, Sendable {
        var localId: UUID
        var uid: String
    }

    /// Matches locally-created contacts (`uid == nil`) against `changed`
    /// entries that carry a server uid. Each response entry is claimed at
    /// most once; unmatched local contacts stay pending for the next sync.
    static func reconcile(
        localPending: [Contact],
        responseChanged: [ContactDTO]
    ) -> [Assignment] {
        let creates = localPending.filter { $0.uid == nil }
        let candidates = responseChanged.indices.filter {
            responseChanged[$0].uid?.isEmpty == false && responseChanged[$0].deleted != true
        }
        var assignments: [Assignment] = []
        var claimed = Set<Int>()
        var assigned = Set<UUID>()

        // Exact matches first, so a content match can never take an entry
        // that names its create.
        for contact in creates {
            let ref = clientRef(for: contact)
            guard let match = candidates.first(where: {
                !claimed.contains($0) && responseChanged[$0].clientRef == ref
            }) else { continue }
            claimed.insert(match)
            assigned.insert(contact.localId)
            assignments.append(Assignment(localId: contact.localId, uid: responseChanged[match].uid!))
        }

        for contact in creates where !assigned.contains(contact.localId) {
            let match = candidates.first { index in
                guard !claimed.contains(index) else { return false }
                let candidate = responseChanged[index]
                let refersElsewhere = !(candidate.clientRef ?? "").isEmpty
                return !refersElsewhere && contentMatches(contact, candidate)
            }
            guard let match else { continue }
            claimed.insert(match)
            assignments.append(Assignment(localId: contact.localId, uid: responseChanged[match].uid!))
        }
        return assignments
    }

    /// The correlation id a create carries on the wire.
    static func clientRef(for contact: Contact) -> String {
        contact.localId.uuidString.lowercased()
    }

    /// Exact equality on the fields a create round-trips verbatim (Android
    /// contentMatches): fn, org, and the ordered email/phone values.
    private static func contentMatches(_ contact: Contact, _ candidate: ContactDTO) -> Bool {
        (candidate.fn ?? "") == contact.name
            && (candidate.org ?? "") == contact.org
            && (candidate.emails ?? []).map(\.value) == contact.emails.map(\.value)
            && (candidate.phones ?? []).map(\.value) == contact.phones.map(\.value)
    }
}
