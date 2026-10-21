//
//  ClientEncryptedDraftClient.swift
//  KyPost
//
//  POST {srv}/api/mail/draft — saves a draft this device already encrypted
//  and signed. The body is `to` and `pgpDraft` only. The plaintext shape
//  (`RelayMailSource.savePlainDraft`) is for server-custody and no-PGP
//  accounts, and is never a fallback from here.
//
//  Swift port of the saveClientEncryptedDraft half of kypost-android's
//  RelayMailSource.
//

import Foundation

private struct RelayClientEncryptedDraftRequest: Encodable {
    var to: String
    var pgpDraft: String
}

final class ClientEncryptedDraftClient: ClientEncryptedDraftTransport {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    func save(_ draft: ClientEncryptedDraft) async -> MailOutcome {
        guard let base = URL(string: serverUrl) else {
            return .failure("the server address is not a valid URL")
        }
        do {
            // {"ok": true} — the bulk-action reply's shape. Any other 200 is
            // not an acknowledgement, and a draft the user believes saved but
            // is not would be lost when the window closes.
            let response = try await httpClient.post(
                RelayActionResponse.self,
                url: base.appending(path: "api/mail/draft"),
                headers: auth.headerFields,
                jsonBody: RelayClientEncryptedDraftRequest(to: draft.to, pgpDraft: draft.pgpDraft)
            )
            return response.ok == true ? .success : .failure("Draft save was not acknowledged")
        } catch {
            return MailOutcome.from(error)
        }
    }
}
