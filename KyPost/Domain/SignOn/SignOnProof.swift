//
//  SignOnProof.swift
//  KyPost
//
//  Proof of possession for the relay sign-on, v1. Each attempt makes a fresh
//  P-256 key in memory. KyAuth binds its thumbprint into the ID token as
//  `cnf`, and the relay accepts that token only with a signature by the key,
//  so a token read off the wire is useless without it.
//

import CryptoKit
import Foundation

nonisolated struct SignOnProof: Equatable, Sendable {
    static let domain = "kypost-signon-pop/1"

    /// Standard base64 of the SPKI DER.
    let proofKey: String
    /// Standard base64 of the DER ECDSA signature over `message`.
    let proof: String

    init(key: P256.Signing.PrivateKey, origin: String, idToken: String) throws {
        proofKey = key.publicKey.derRepresentation.base64EncodedString()
        proof = try key.signature(for: Self.message(origin: origin, idToken: idToken))
            .derRepresentation.base64EncodedString()
    }

    /// The handoff's `cnf`: base64url, no padding, of SHA-256 over the SPKI DER.
    static func thumb(_ key: P256.Signing.PublicKey) -> String {
        SignOnHandoff.base64url(Data(SHA256.hash(data: key.derRepresentation)))
    }

    /// `kypost-signon-pop/1\n<origin>\n<base64url sha256(idToken)>`, UTF-8.
    /// `origin` must be exactly the one sent in the handoff.
    static func message(origin: String, idToken: String) -> Data {
        let idt = SignOnHandoff.base64url(Data(SHA256.hash(data: Data(idToken.utf8))))
        return Data("\(domain)\n\(origin)\n\(idt)".utf8)
    }
}
