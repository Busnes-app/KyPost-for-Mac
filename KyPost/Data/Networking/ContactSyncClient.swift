//
//  ContactSyncClient.swift
//  KyPost
//
//  Contact sync, matching the Android reference ContactSyncClient.kt /
//  ContactSyncModels.kt (Mobile_Contact_Sync.md) and verified against the
//  live backend 2026-07-10:
//    Pull: GET  {srv}/api/contacts/sync?since=N  (pairing auth via headers)
//    Push: POST {srv}/api/contacts/sync  body {baseCursor, changes}  (pairing auth via headers)
//  Both return {cursor, tooOld, changed: [...], deleted: [...]}.
//
//  DTO field names mirror the backend contactPayload
//  (llama-labels backend/internal/api/contacts_handlers.go) exactly.
//

import Foundation

/// A labeled value (email address or phone number) on a contact.
struct ContactFieldDTO: Codable, Equatable, Sendable {
    var label: String?
    var value: String
}

struct ContactAddressDTO: Codable, Equatable, Sendable {
    var label: String?
    var street: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?
}

struct ContactIMDTO: Codable, Equatable, Sendable {
    var service: String?
    var label: String?
    var value: String
}

struct ContactRelationDTO: Codable, Equatable, Sendable {
    var label: String?
    var name: String
}

struct ContactEventDTO: Codable, Equatable, Sendable {
    var label: String?
    var date: String
}

struct ContactCustomFieldDTO: Codable, Equatable, Sendable {
    var label: String
    var value: String
}

/// Matches the backend's contactPayload. Every field is optional: the server
/// omits empty ones (Go omitempty), and older servers may not send the
/// extended set at all. `mergedUIDs`/`mergedInto` are deliberately not
/// modeled — decoding ignores unknown keys.
struct ContactDTO: Codable, Equatable, Sendable {
    /// At most one synced contact has this true. Read-only: the app never
    /// sets it, so it is decoded but never sent on a push.
    var isSelf: Bool?
    /// Empty string marks a create on push (Android contract); server-assigned
    /// on responses.
    var uid: String?
    var rev: Int?
    var deleted: Bool?
    /// Full display name.
    var fn: String?
    var givenName: String?
    var familyName: String?
    var middleName: String?
    var prefix: String?
    var suffix: String?
    var nickname: String?
    var org: String?
    var title: String?
    var emails: [ContactFieldDTO]?
    var phones: [ContactFieldDTO]?
    var addresses: [ContactAddressDTO]?
    var notes: String?
    var birthday: String?
    var photoRef: String?
    var groupIDs: [String]?
    var pgpKey: String?
    var ims: [ContactIMDTO]?
    var websites: [ContactFieldDTO]?
    var relations: [ContactRelationDTO]?
    var events: [ContactEventDTO]?
    var phoneticGivenName: String?
    var phoneticFamilyName: String?
    var department: String?
    var customFields: [ContactCustomFieldDTO]?
    var pronouns: String?
    /// Client correlation id: the local contact's `localId`, sent on a create
    /// only. A relay that stores it and echoes it on the created contact lets
    /// a create whose response was lost be matched exactly instead of by
    /// content (`ContactSyncReconciliation`). The relay (KyPost-Server
    /// `contactSyncChange`) ignores unknown fields today and echoes nothing,
    /// so this is forward-compatible and inert until the server stores it.
    var clientRef: String?

    var primaryEmail: String { emails?.first?.value ?? "" }
    var primaryPhone: String { phones?.first?.value ?? "" }
}

/// One merge the server performed: `absorbed` uids were folded into
/// `survivor` and now carry tombstones.
struct ContactDedupeGroup: Decodable, Equatable, Sendable {
    var survivor: String
    var absorbed: [String]
}

/// Result of POST /api/contacts/dedupe. The server is the sole authority on
/// matching and merging — the client only reports what it did.
struct ContactDedupeReport: Decodable, Equatable, Sendable {
    var mergedCount: Int
    var groups: [ContactDedupeGroup]?
}

/// The dedupe endpoint takes no parameters, but the backend still expects a
/// JSON body; it never reads it.
private struct EmptyJSONBody: Encodable {}

struct ContactSyncPushRequest: Encodable, Sendable {
    var baseCursor: Int
    var changes: [ContactDTO]
}

struct ContactSyncPullResponse: Decodable, Equatable, Sendable {
    var cursor: Int
    /// True when `since` predates the server's history window — discard the
    /// cursor and local cache, then re-pull from 0.
    var tooOld: Bool?
    var changed: [ContactDTO]?
    var deleted: [ContactDTO]?
}

final class ContactSyncClient: Sendable {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    /// Pulls server changes after `since`; used when no local changes are queued.
    func pull(
        serverUrl: String,
        auth: RelayAuth,
        since: Int
    ) async throws -> ContactSyncPullResponse {
        try await httpClient.get(
            ContactSyncPullResponse.self,
            url: try endpoint(serverUrl),
            query: [URLQueryItem(name: "since", value: String(max(since, 0)))],
            headers: auth.headerFields
        )
    }

    /// Pushes queued local changes; the response carries the same delta shape
    /// as a pull, including the server's copy of the pushed contacts.
    func push(
        serverUrl: String,
        auth: RelayAuth,
        baseCursor: Int,
        changes: [ContactDTO]
    ) async throws -> ContactSyncPullResponse {
        try await httpClient.post(
            ContactSyncPullResponse.self,
            url: try endpoint(serverUrl),
            headers: auth.headerFields,
            jsonBody: ContactSyncPushRequest(baseCursor: baseCursor, changes: changes)
        )
    }

    /// POST {srv}/api/contacts/dedupe — asks the server to merge
    /// duplicate contacts and report what it merged. The merges land in the
    /// sync delta, so callers sync afterwards to pick them up. Pairing auth
    /// (sub/hash) is sent as headers.
    ///
    /// Takes pairing auth (backend withMailAuth), same as sync: 401 means the
    /// credentials were rejected, 503 that mail pairing isn't configured.
    func dedupe(
        serverUrl: String,
        auth: RelayAuth
    ) async throws -> ContactDedupeReport {
        guard let base = URL(string: serverUrl) else {
            throw NetworkError.invalidURL
        }
        return try await httpClient.post(
            ContactDedupeReport.self,
            url: base.appending(path: "api/contacts/dedupe"),
            headers: auth.headerFields,
            jsonBody: EmptyJSONBody()
        )
    }

    /// GET {srv}/api/contacts/{uid}/photo — raw image bytes for a
    /// contact's photoRef. Pairing auth (sub/hash) is sent as headers. The
    /// backend currently gates this behind a web session (llama-labels
    /// Part 0 gap), so callers treat NetworkError.unauthorized as "not
    /// available yet", not a pairing failure.
    func fetchPhoto(
        serverUrl: String,
        auth: RelayAuth,
        uid: String
    ) async throws -> Data {
        guard let base = URL(string: serverUrl) else {
            throw NetworkError.invalidURL
        }
        return try await httpClient.getData(
            url: base.appending(path: "api/contacts/\(uid)/photo"),
            headers: auth.headerFields
        )
    }

    private func endpoint(_ serverUrl: String) throws -> URL {
        guard let url = URL(string: serverUrl) else {
            throw NetworkError.invalidURL
        }
        return url.appending(path: "api/contacts/sync")
    }
}
