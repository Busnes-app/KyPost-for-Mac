//
//  PgpKeyFloorTests.swift
//  KyPost Tests
//
//  The OpenPGP key-size floor (PgpKeyFloor, docs/STRONG-CRYPTO.md). GopenPGP
//  alone accepts a 2047-bit RSA key (go-crypto's `MinimumRSABits` default),
//  so every refusal below is the floor's.
//
//  The RSA fixtures are disposable keys made with go-crypto v1.5.2
//  `openpgp.NewEntity` (gpg 2.4 rounds RSA sizes up to 2048, so it cannot make
//  one), then checked with gpg 2.4.9: `--list-packets` reports
//  `pkey[0]: [2047 bits]` (or 2048) for primary and subkey, `--verify` reports
//  a good signature over `signedBody`, and `--decrypt` opens the message.
//

import Foundation
import Testing
@testable import KyPost

private enum ShortRSAFixtures {
    static let signedBody = "Signed by a short RSA key.\n"
    static let messagePlaintext = "Mail sent to a short RSA key.\n"

    static let rsa2047Public = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xsBNBGlVuQABB/9nRmfWSVyJfYBJ+cv6WoEeO0ia4ke/NEnbzPqSLeb9i7n/DCDY
    qX374RW+6L5Cj+XeLHD4zg7S4Abq2nBAZw9jbi11p5TFlwzuB39ZD4xLsR/H8sSY
    sohGe7BxhKOdvGauXYokJaVGWOkK1gVeRfXP9yFBHtGJGau+j8LZ/5pyjX23PXG1
    t/Sb+K9IAWhtFWooZ4Iq1ZFciLWWAuOgbFFY7agjLP20Z4nBTPjVzBmMaO+Rvk6I
    ODr2uU+gLkbKwYETPsJLGGyJgsB+JD/h/4CsYdgL0KorkftOZQ0O2bb+Oow5U0fr
    KhPTzuPYeeLir5Hr3i9U3SFSNX7IjEVskKFhABEBAAHNHVJTQSAyMDQ3IDxyc2Ey
    MDQ3QHJlbGF5LnRlc3Q+wsC7BBMBCABvBYJpVbkAAgsHCRDAw2FtrQNVnTUUAAAA
    AAAcABBzYWx0QG5vdGF0aW9ucy5vcGVucGdwanMub3Jn8P4GG1L/B9BQd6885gNl
    YwIVCAIWAAIZAQKbAwIeARYhBH+UyLqsMVbKzRydIsDDYW2tA1WdAADB2Af9EAHN
    EE2rxX9ujK0GUE20VAIsw6C9YvuQ/z9nfMIMmTiyVuzUKimbx+ghfxkNFU9yoGV1
    Ux+YtCUJV4dT9fQ8U6J9kyXTfW/bUvk8xFILS4d3z7qgqC20kHMi6/3zQty7Z5TH
    SBEkX1I33Kj6b88H2QxsfgVWVf3BLR233QvZOG8cv7dhotCai5kO/5SshSabjkLL
    161XwkBegpPMLVQIncajePelHjf16qpZgwL26RC43i9KDojOFWomajUsJG195d4u
    8FTlCou8H4vcqCmtXPdxnnVKumHhA3wkrvTh8/ZUtPdWemUihaqvx/SzNYfWMmO+
    +uuXmXt2UQpDkk3qOc7ATQRpVbkAAQf/c6pJc3xCzYtZZWGX+5I8SumeCgPo81o1
    kF1RCHd1sLfg0ZDCC0EOYc0josfRHc23ofazlhzBGDy5urEitESCPu+j70ojy4nS
    W+Ab1gu/Rt2BIkVjes+qkTYfxUKjjGtZfhLJP+Jd6M1Si3IYalwiT7c752suLi8Q
    Iz5BPZMwAp2v6n9ucD6xOQep5P1cKCkxKhujOgjnD4XMLENk2qZebMjL/EcbaBvG
    mTtPjGUHzzz9y9y04HaYtR3rPZBEwQSwfgJ1RekxSl33JgVk6k5DB/ug4CKxroJD
    +3v8K42/fIZg4H1M86CZlP2Nzxo2K5A+0eNxj+rUqxVQ+IvtVTH7cQARAQABwsCs
    BBgBCABgBYJpVbkACRDAw2FtrQNVnTUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5v
    cGVucGdwanMub3Jnig5WovlrXpXCy/YzUuyoMwKbDBYhBH+UyLqsMVbKzRydIsDD
    YW2tA1WdAABzMQf6A480j0dCJ4b8CMDBQ0J9PM8YMWwsF5UevXNVzHB16XbusLHG
    n3HwElGCriAZZXxZuMOZ5/RiYFrhwR0Bquck+VFg+W/Geu/SDcJSvlALvyzRNaOf
    +YKA7xiXsKo7HKUxSqG7bCpryOTg+NYXz97lOQnTuNz1rPr0AoVRIyJ1AmDmUPcH
    MzQ+kQ3HvQEcne8tHgBRiWL3nZWcstzhPVqKMhIVD8ujswyLGGJ9eQEcqr3uXYNQ
    bnIknODoR2hkYunenqaqbFho5gt5IPme4Dd66EYmhmSKn3QQ97Rw1nmfYLh/LGgt
    0t1PJMUgaRBEBH1EFZzc4eD8IuhT2kddtdchLQ==
    =Y1ln
    -----END PGP PUBLIC KEY BLOCK-----
    """

    static let rsa2047Private = """
    -----BEGIN PGP PRIVATE KEY BLOCK-----

    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
    =TC/4
    -----END PGP PRIVATE KEY BLOCK-----
    """

    static let rsa2047Signature = """
    -----BEGIN PGP SIGNATURE-----

    wsCpBAABCABdBYJpVbkACRDAw2FtrQNVnTUUAAAAAAAcABBzYWx0QG5vdGF0aW9u
    cy5vcGVucGdwanMub3Jn+AskIl7EAFqMHZlMwCzoJRYhBH+UyLqsMVbKzRydIsDD
    YW2tA1WdAAChYwf/U+QrOaUR7JbO0uNAzHlAmr1lNh5uw9iGTxLIKlu2h3J94e54
    yuGTObnYjho2hexJI1FoXAzRW+l1ubDtIYqa2hMwblef/FpqK4vBBASkIP0nRjQ6
    ltVMlV3XvRXDP9UGGFkPrqWTh4uFpBnp4c+Ln8GFzLilZj54HZpqNyXc4evyQwHK
    DDW14zwvlppCmH9OLz2XnPhoX/cfRouRd/RlWGpdaxElq3PQuQCkKYTmKo9ZOTkW
    RuRH9BBNWQqInrnCokTpuBM2Ia/jIaN0wtcsrKoXxrSsWoV3Y5jAhJWf0Kx3+/sv
    9FaaAUCcyfqfYPsjkDY/LSx4tfQOlsz7WdHs2g==
    =5wir
    -----END PGP SIGNATURE-----
    """

    static let rsa2047Message = """
    -----BEGIN PGP MESSAGE-----

    wcBMA9F7CspbXy32AQf+NblRceQ6zolSjSr0N2wfDwfU8kmdYTR/cJ69g3ARdS2f
    MlvplC5jKrKoOhJjJ4B2cqW9IY98oUakyk34gION3cf5trVnBNcKdqY2rzKuJ3z0
    N0kZ0GGcjXe27mjb+DCoNtdI6q4hUrcBq54bCw5eHHD1F8Ma20p7tLfhb+wQ1kf4
    MMTfS/yoFan6+24+3D+2k5Hdtsrey+QJ8WSgQGRqSpu/LaucfNbywzMi7CECafKH
    rWZpvE0hZd+fg+4wVwiH1/54O3B0lnfxlsstJhRSzh9O+flboEte+AGex71xMQi4
    lyRcgQ2fd9uHtbqIOoKF7K/L6h4htWLNs7DG4nfegdJPAWOVc4H4mOBfgQ44ufO4
    QNjb7M6uJFpwE4t78OCZBjfPyS3HIaoX1o95sVwHs0FlH6Ys7UbHx9KCppiEwC3I
    0nQSZn1hbzesq3TK4eg80Q==
    =nc9J
    -----END PGP MESSAGE-----
    """

    static let rsa2048Public = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xsBNBGlVuQABCADU0JkKRCH9feUhcgiMX4EixWEk7F05OgrkIaxsHTIXp2wfAgSc
    jI4q8Nny8fej/mMtFaxmg6IIGy43wixTydhS9ls6g5RcAmIAM8rQU4ijAVCirnrH
    h5xVa7uwGT+NRJiVDobNz8Q6ohuzrR9YmWTGKjWmhbHgGWK7VWwu4Qu/pNO5QFqn
    UypkhhsAdZ0O3fdZlmRncO+5n8bLiENPahPa9YP8y0qLGrk4vS9CPjpXBiW7sdId
    Qtg05gwvRb0TqcId5iwwuFdJK/ORh/sq2XkXDJ0xk7Bd32oEhhNIyEOTsRDjl+Wz
    eEdZblycPkINszmpxLAueemqw2WInYqmqTZxABEBAAHNHVJTQSAyMDQ4IDxyc2Ey
    MDQ4QHJlbGF5LnRlc3Q+wsC7BBMBCABvBYJpVbkAAgsHCRD7HKdSmVVA6jUUAAAA
    AAAcABBzYWx0QG5vdGF0aW9ucy5vcGVucGdwanMub3JnJjIj4d8Y7tODypVqCHi3
    DQIVCAIWAAIZAQKbAwIeARYhBPwIraRSUH72mCXBRfscp1KZVUDqAABLwwgAkZDE
    OnAtJ4ZF7jZSqu707p5JJH49xkTlQ1Ks0u/4t8vESwzzOIw6VFKfktlAE3m/Z43H
    3GnnYanPF2eL1mRYEYgotxX3zZKXZa/d2/fICSEMq0WXC2JaoifFMAINO8Ccrve7
    28+49GHBMee/oJhDQnqfDzyIhglSAdoyC5HJlYy2sN/oCAFX5cTBzXwtqgODQzmp
    1kLiMgiV1ICpc8iACTpXa7D4hSrqSNRLP218yy/Es2MtJtkfmz/WaTEe8MxIFhpO
    UN8nzjwFUNzTd8EMOwLO3WD/1QEldkiVgjszj2WryQZfA0ezCaurpIexVcJgtXWk
    tuQef31cysHaIRmews7ATQRpVbkAAQgAwUMMqIwS9BTDCCbiOnXki1Ox6DszES2c
    hH+CO4aeqo+aPY7lXsnocB+Lzr1ORX1sZWuoj/IfI95vH4TE3Llttsyf45Y7VlI4
    OrH+fxz/BOlPwRhDo7qX38JTvKB4d80+rms7i7Vka6+3EuOmK/7SStCSG8oNkKu1
    Q5nVyNvnH7nsKwXr6evLuiai2IfGKm99RCkxXrNFG2ubkfb6e/UPwFBnfykhllW7
    PmwJo/7ZPbOvr4GWup3wfWewfMEUQLrnAklNYaNIzLGyK2WQ8KVDc4kmA3gWYo5l
    jrNcTE0Q+C1Da/vDow5//5jEomaQtxsLqS20CbNy8azbdPhxrLLquQARAQABwsCs
    BBgBCABgBYJpVbkACRD7HKdSmVVA6jUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5v
    cGVucGdwanMub3JnRHiTs7956rnl+rqlQ2vt0QKbDBYhBPwIraRSUH72mCXBRfsc
    p1KZVUDqAACm+gf9HMdrdMnMKoD8vTnwMY3nPIwSiDdEXBthbleQeGP6YTdrkFcf
    sn7C8qdzxJp8l3q3Oz0U8EevrudkjFgEabnQuc1uChOA6bgrb77A8PKqt1ydv3/E
    RwA+B1mZFTQTED8lW7URcRxS5HqxmKZoguikyy3NPpqjoyA1tW674W9JbLl1GdRr
    kdtZe0NeTh0R0lJVno3th/q7y3MLazm6XPxIS8HpPaC0EaitAaHH4Th+Z7Ovt3Sp
    LWOzkHiKyF7Ht0HsItI4sJzQHqUsrfiu32GClQlrneRVpYGCMYMoO/VjTrfcxu5R
    N+0Can2E0YoEBkSaar2upboF3oMKFefc26GQHg==
    =NKo3
    -----END PGP PUBLIC KEY BLOCK-----
    """

    static let rsa2048Signature = """
    -----BEGIN PGP SIGNATURE-----

    wsCpBAABCABdBYJpVbkACRD7HKdSmVVA6jUUAAAAAAAcABBzYWx0QG5vdGF0aW9u
    cy5vcGVucGdwanMub3JnvJliScum08KRDHsaYvKJ9BYhBPwIraRSUH72mCXBRfsc
    p1KZVUDqAACvxgf+NKM7/IfUECZZnDnIAveqpDdHIndo8Hxgzo7RRu7OXMJOVzIo
    N8BJZzp/R7Yxj95UNOC2fx+BvrHLy2/w1aCpj+sOaRQozu/SfnG2lDvjW60jzbji
    m6RnhViRwRPoo5lzdNO3bUFcC5OZAloBvo8Oh4usEXdkADHL27PXjQY3CSY0/nxP
    kYq6aZPiGYS+AiaDzDnCqk6r6ParigkydKm7F4nsEOanOpvUCv2wDWFNddEF1EjJ
    gqLwlFevzv6+opvX1jW7GhCy3blo7YoNAhwr2xGbhDxYFffSKBfCGCUOTneaAiy2
    VHsOuPSvEr3KoulQihC+hJWrcDnsgX+aPkpCTQ==
    =XvcR
    -----END PGP SIGNATURE-----
    """
}

// MARK: - Packet rule

@Suite struct PgpKeyFloorPacketTests {
    /// A v4 RSA key packet body whose modulus MPI declares `declared` bits
    /// and starts with `leading`.
    private func rsaV4(declared: Int, leading: UInt8, algorithm: UInt8 = 1) -> Data {
        let length = (declared + 7) / 8
        var body: [UInt8] = [4, 0x69, 0x55, 0xB9, 0x00, algorithm, UInt8(declared >> 8), UInt8(declared & 0xFF)]
        body.append(leading)
        body.append(contentsOf: [UInt8](repeating: 0xA5, count: length - 1))
        body.append(contentsOf: [0x00, 0x11, 0x01, 0x00, 0x01])
        return Data(body)
    }

    @Test func rsaIsJudgedOnItsActualModulusBits() {
        #expect(PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 2048, leading: 0x80)))
        #expect(PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 4096, leading: 0xC3)))
        #expect(!PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 2047, leading: 0x40)))
        #expect(!PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 1024, leading: 0x80)))
        // RSA encrypt-only and sign-only take the same rule.
        #expect(!PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 2047, leading: 0x40, algorithm: 2)))
        #expect(!PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 2047, leading: 0x40, algorithm: 3)))
    }

    /// A header claiming 2048 bits over a modulus with a zero top octet is
    /// at most 2040 bits, and the header does not get to say otherwise.
    @Test func aDeclaredLengthCannotInflateAShortModulus() {
        #expect(!PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 2048, leading: 0x00)))
        #expect(!PgpKeyFloor.meets(keyPacketBody: rsaV4(declared: 2048, leading: 0x7F)))
    }

    @Test func aV6RSAKeyIsReadPastItsMaterialLength() {
        let v4 = [UInt8](rsaV4(declared: 2048, leading: 0x80))
        let material = v4[6...]
        let count = material.count
        var v6: [UInt8] = [6]
        v6 += v4[1...5]
        v6 += [0, 0, UInt8(count >> 8), UInt8(count & 0xFF)]
        v6 += material
        #expect(PgpKeyFloor.meets(keyPacketBody: Data(v6)))
    }

    @Test func otherAlgorithmsAndVersionsAreDecidedByAllowList() {
        func key(version: UInt8, algorithm: UInt8) -> Data {
            Data([version, 0x69, 0x55, 0xB9, 0x00, algorithm, 0x09, 0x2B, 0x06, 0x01])
        }
        for strong: UInt8 in [18, 19, 22, 25, 26, 27, 28, 30, 35] {
            #expect(PgpKeyFloor.meets(keyPacketBody: key(version: 4, algorithm: strong)), "algorithm \(strong)")
        }
        // DSA, ElGamal (both encodings), and an unassigned id.
        for refused: UInt8 in [16, 17, 20, 99] {
            #expect(!PgpKeyFloor.meets(keyPacketBody: key(version: 4, algorithm: refused)), "algorithm \(refused)")
        }
        #expect(!PgpKeyFloor.meets(keyPacketBody: key(version: 3, algorithm: 22)))
        #expect(!PgpKeyFloor.meets(keyPacketBody: key(version: 5, algorithm: 22)))
        #expect(!PgpKeyFloor.meets(keyPacketBody: Data()))
        #expect(!PgpKeyFloor.meets(keyPacketBody: Data([4, 0x69, 0x55, 0xB9, 0x00, 1, 0x08, 0x00, 0x80])))
    }

    @Test func everyKeyPacketOfARealKeyIsChecked() throws {
        let short = try #require(PgpFingerprint.dearmor(ShortRSAFixtures.rsa2047Public))
        let long = try #require(PgpFingerprint.dearmor(ShortRSAFixtures.rsa2048Public))
        let curve = try #require(PgpFingerprint.dearmor(TestPgpFixtures.armoredPublic))
        #expect(!PgpKeyFloor.meets(keyPackets: short))
        #expect(PgpKeyFloor.meets(keyPackets: long))
        #expect(PgpKeyFloor.meets(keyPackets: curve))
        #expect(!PgpKeyFloor.meets(keyPackets: Data()))
        #expect(!PgpKeyFloor.meets(keyPackets: Data([0xFF, 0x00])))
    }
}

// MARK: - Through GopenPGP

@Suite(.serialized) struct PgpKeyFloorCryptoTests {
    private let crypto = GopenPGPCrypto()
    private var privateKey: Data { Data(TestPgpFixtures.armoredPrivate.utf8) }

    @Test func aShortRecipientKeyIsRefusedAndALongOneIsUsed() throws {
        #expect(throws: PgpCryptoError.self) {
            try crypto.encryptAndSign(
                plaintext: Data("x".utf8),
                recipientKeys: [ShortRSAFixtures.rsa2047Public],
                privateKey: privateKey
            )
        }
        let armored = try crypto.encryptAndSign(
            plaintext: Data("x".utf8),
            recipientKeys: [ShortRSAFixtures.rsa2048Public],
            privateKey: privateKey
        )
        #expect(armored.hasPrefix("-----BEGIN PGP MESSAGE-----"))
    }

    /// Never skipped: that would send mail the short-key recipient cannot open.
    @Test func oneShortRecipientRefusesTheWholeMessage() {
        #expect(throws: PgpCryptoError.self) {
            try crypto.encryptAndSign(
                plaintext: Data("x".utf8),
                recipientKeys: [ShortRSAFixtures.rsa2048Public, ShortRSAFixtures.rsa2047Public],
                privateKey: privateKey
            )
        }
    }

    @Test func aShortSignerKeyVerifiesNothing() {
        let short = crypto.verifyDetached(
            signedBytes: Data(ShortRSAFixtures.signedBody.utf8),
            armoredSignature: ShortRSAFixtures.rsa2047Signature,
            signerKeys: [ShortRSAFixtures.rsa2047Public]
        )
        let long = crypto.verifyDetached(
            signedBytes: Data(ShortRSAFixtures.signedBody.utf8),
            armoredSignature: ShortRSAFixtures.rsa2048Signature,
            signerKeys: [ShortRSAFixtures.rsa2048Public]
        )
        #expect(short.present)
        #expect(!short.valid)
        #expect(long.valid)
    }

    @Test func aShortOwnKeyNeitherSignsNorExports() {
        let shortOwn = Data(ShortRSAFixtures.rsa2047Private.utf8)
        #expect(throws: PgpCryptoError.unusableKey) {
            try crypto.ownPublicKey(privateKey: shortOwn)
        }
        #expect(throws: PgpCryptoError.unusableKey) {
            try crypto.encryptAndSign(
                plaintext: Data("x".utf8),
                recipientKeys: [TestPgpFixtures.armoredPublic],
                privateKey: shortOwn
            )
        }
    }

    /// Mail already sent to a short key stays readable.
    @Test func mailSentToAShortKeyStillDecrypts() throws {
        let result = try crypto.decrypt(
            armoredCiphertext: ShortRSAFixtures.rsa2047Message,
            privateKey: Data(ShortRSAFixtures.rsa2047Private.utf8),
            signerKeys: []
        )
        #expect(String(decoding: result.body, as: UTF8.self) == ShortRSAFixtures.messagePlaintext)
    }
}
