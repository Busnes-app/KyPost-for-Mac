//
//  Contact.swift
//  KyPost
//
//  Domain model for a synced contact (spec §4, §8 contacts table), carrying
//  the backend's full contactPayload field set (Client_Contact_Update.md).
//  The server replaces the whole contact on push, so every payload field must
//  round-trip through this model or an edit here wipes it server-side.
//

import Foundation

// The composite types below are stored as SwiftData codable-collection
// attributes and written from ContactDAO, a @ModelActor. The target defaults
// to MainActor isolation (SWIFT_DEFAULT_ACTOR_ISOLATION) and infers isolated
// conformances, which would make their Codable conformance MainActor-only;
// SwiftData's encoder casts the array at runtime off the main actor, and an
// isolated conformance fails that cast — a fatalError in ModelCoders, not a
// compile error. `nonisolated` keeps the conformances usable from any actor.

/// A labeled value (email address, phone number, or website) on a contact.
nonisolated struct ContactLabeledValue: Codable, Hashable, Sendable {
    var label: String?
    var value: String
}

nonisolated struct ContactPostalAddress: Codable, Hashable, Sendable {
    var label: String?
    var street: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?
}

/// An IM / social handle. `service` is the backend's fixed vocabulary
/// (whatsapp|signal|telegram|instagram|x|linkedin|facebook|mastodon|matrix);
/// empty/nil means "other" with `label` holding the free-text service name.
nonisolated struct ContactIM: Codable, Hashable, Sendable {
    var service: String?
    var label: String?
    var value: String
}

/// A named relationship. `label` is one of the backend's fixed vocabulary
/// (spouse|child|parent|partner|manager|assistant|friend|relative|other);
/// `name` is free text, not a link to another contact.
nonisolated struct ContactRelation: Codable, Hashable, Sendable {
    var label: String?
    var name: String
}

/// A date beyond birthday (anniversary or custom label), YYYY-MM-DD.
nonisolated struct ContactEvent: Codable, Hashable, Sendable {
    var label: String?
    var date: String
}

/// Free-form label/value pair for anything without a typed field.
nonisolated struct ContactCustomField: Codable, Hashable, Sendable {
    var label: String
    var value: String
}

nonisolated struct Contact: Identifiable, Hashable, Sendable {
    /// Stable local identity; contacts created locally have no server `uid`
    /// until ContactSyncReconciliation assigns one (spec §4).
    var localId: UUID = UUID()
    /// Server-assigned UID from sync; nil for locally-created, not-yet-reconciled contacts.
    var uid: String?
    /// Server revision, echoed back on pushes for conflict detection
    /// (Mobile_Contact_Sync.md); 0 until the first sync assigns one.
    var rev: Int = 0
    /// Full display name (backend `fn`).
    var name: String
    var givenName = ""
    var familyName = ""
    var middleName = ""
    var prefix = ""
    var suffix = ""
    var nickname = ""
    var org = ""
    var title = ""
    var emails: [ContactLabeledValue] = []
    var phones: [ContactLabeledValue] = []
    var addresses: [ContactPostalAddress] = []
    var notes = ""
    /// YYYY-MM-DD; empty = unset.
    var birthday = ""
    /// Content-hashed photo filename on the server; bytes fetched separately
    /// and cached by ContactPhotoCache.
    var photoRef: String?
    /// Backend group UUIDs, resolved to names via GroupDAO and materialized
    /// as CNGroups by SystemContactGroupLinker.
    var groupIDs: [String] = []
    /// The one contact the user flagged as "this is me", in the web app.
    ///
    /// **Read-only here.** Setting it stays a web-only action, matching the
    /// server spec's scope, so nothing in this app writes it and the push
    /// payload never carries it.
    var isSelf = false
    /// Armored ASCII PGP public key; app-only, never exported to Contacts.app.
    var pgpKey: String?
    /// A key received via sync that differs from the currently-stored
    /// `pgpKey` and hasn't been reviewed yet. Sync never silently replaces a
    /// fingerprint-verified key — see ContactSyncRepository.applyServerContact.
    var pendingPgpKey: String?
    var ims: [ContactIM] = []
    var websites: [ContactLabeledValue] = []
    var relations: [ContactRelation] = []
    var events: [ContactEvent] = []
    var phoneticGivenName = ""
    var phoneticFamilyName = ""
    var department = ""
    /// App-only, never exported to Contacts.app.
    var customFields: [ContactCustomField] = []
    /// App-only; no public CNContact pronouns API.
    var pronouns = ""
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date
    /// True for local creates/edits not yet pushed to the server (spec §4).
    var needsSync: Bool = false
    /// Set on a card imported from Apple Contacts: the consent it was
    /// imported under (`ContactsSettingsStore.importConsentStamp`). Until the
    /// server has the contact, it uploads only while that same consent
    /// stands (`SystemContactsExporter.mayUpload`). Nil for everything else,
    /// and once the server assigns a uid. Kept on the row, not the Apple
    /// Contacts link, so no export cleanup can drop it.
    var importConsent: String?

    var id: UUID { localId }

    /// Compatibility shims for single-value call sites (list rows, match keys).
    var primaryEmail: String { emails.first?.value ?? "" }
    var primaryPhone: String { phones.first?.value ?? "" }

    /// Display-name fallback for contacts without one (company-only cards
    /// imported from Contacts.app): org, then the primary email's local part,
    /// then the primary phone. The server rejects creates without an fn, so a
    /// nameless contact can never sync. Empty when there's nothing to derive.
    var derivedDisplayName: String {
        if !org.isEmpty { return org }
        if let localPart = emails.first?.value.split(separator: "@").first {
            return String(localPart)
        }
        return primaryPhone
    }
}
