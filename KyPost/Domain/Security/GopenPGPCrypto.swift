//
//  GopenPGPCrypto.swift
//  KyPost
//
//  The one file in this app that may `import Gopenpgp`. Everything else talks
//  to `PgpDecrypting` / `PgpEncrypting`; see PgpCrypto.swift for why.
//
//  Swift port of kypost-android's pgp/PgpDecryptor.kt and pgp/PgpEncryptor.kt.
//  Android used Bouncy Castle and had to assemble the guarantees by hand — walk
//  to the literal packet, bound the decompressed stream before allocating,
//  check the integrity packet, refuse to let a message verify itself. GopenPGP
//  expresses all four as configuration, so the port is mostly a matter of not
//  switching them off.
//

import Foundation
import Gopenpgp

/// Bridges the OpenPGP implementation to this app's protocols.
///
/// Every entry point returns a value or throws a `PgpCryptoError`; nothing
/// leaks a `Gopenpgp` type. Errors from the library are deliberately not
/// forwarded verbatim — the caller renders an exit-table row, and a Go error
/// string is not that.
nonisolated struct GopenPGPCrypto: PgpDecrypting, PgpEncrypting, PgpKeyInspecting {

    /// gomobile's encoding selector. 0 is "detect", which accepts both the
    /// armored and the binary form; mail carries armored, and a stored draft
    /// or an attachment may not.
    private static let autoDetectEncoding: Int8 = 0

    private var pgp: CryptoPGPHandle {
        get throws {
            guard let handle = CryptoPGP() else { throw PgpCryptoError.unavailable }
            return handle
        }
    }

    // MARK: - Reading

    func decrypt(
        armoredCiphertext: String,
        privateKeys: [Data],
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        // Every key held, current and retired, in one decryption ring: mail
        // encrypted to a retired key, or to a hidden recipient whose key id is
        // zeroed, can only be opened by trying them all. The library selects
        // by key id and tries every key for a wildcard.
        let decryptionKeys = try decryptionRing(fromArmored: privateKeys)
        defer { decryptionKeys.clearPrivateParams() }

        // Only keys the address book bound to the displayed sender may verify.
        // The signer's public key travels inside signed mail often enough to
        // be tempting, and a message that vouches for itself proves only that
        // whoever wrote it owned a key.
        //
        // One measured caveat, because it is surprising: GopenPGP will also
        // verify a signature against the **decryption key**, offered or not.
        // Self-sent mail therefore reports as verified. That is not a forgery
        // route — signing still needs the private half only this device holds
        // — but it does mean a test built on a self-signed message proves
        // nothing about which keys are trusted. See
        // `onlyAnOfferedKeyValidatesASignature`, which arranges a signer
        // distinct from the decryption key for exactly that reason.
        let verificationKeys = try? keyRing(fromArmored: signerKeys)

        let handle: any CryptoPGPDecryptionProtocol
        do {
            guard let builder = try pgp.decryption() else { throw PgpCryptoError.unavailable }
            builder.decryptionKeys(decryptionKeys)
            if let verificationKeys { builder.verificationKeys(verificationKeys) }
            // The zip-bomb bound, enforced by the library during decompression
            // rather than after it. Android had to hand-roll this over the
            // decompressed stream; here it is a setting, and the reason it is
            // set explicitly is that the default is not this app's cap.
            builder.maxDecompressedMessageSize(Int64(maxDecompressedPlaintextBytes))
            handle = try builder.new()
        } catch let error as PgpCryptoError {
            throw error
        } catch {
            throw PgpCryptoError.cannotDecrypt
        }
        defer { handle.clearPrivateParams() }

        // Note what is *not* called on that builder:
        //
        //   insecureDisableUnauthenticatedMessagesCheck — integrity protection
        //     is mandatory. An unprotected message is malleable, and accepting
        //     one lets a tampered ciphertext render as ordinary mail.
        //   insecureAllowDecryptionWithSigningKeys — a signing key is not a
        //     decryption key.
        //   disableIntendedRecipients / disableVerifyTimeCheck — both weaken
        //     what a signature means.
        //
        // Each is an opt-out, so the secure behaviour is what happens by
        // leaving them alone. They are listed because "we never call these" is
        // otherwise invisible to a reader, and a future edit adding one would
        // look like a fix for a decryption failure.

        let result: CryptoVerifiedDataResult
        do {
            result = try handle.decrypt(
                Data(armoredCiphertext.utf8),
                encoding: Self.autoDetectEncoding
            )
        } catch {
            // The library reports the size cap as an ordinary decryption
            // error. Distinguishing it matters: "too large" is a different row
            // in the exit table from "not encrypted to a key on this device".
            throw Self.describesSizeLimit(error)
                ? PgpCryptoError.tooLarge
                : PgpCryptoError.cannotDecrypt
        }

        return DecryptedMessage(
            body: result.bytes() ?? Data(),
            signature: Self.rawSignature(from: result)
        )
    }

    func verifyDetached(
        signedBytes: Data,
        armoredSignature: String,
        signerKeys: [String]
    ) -> RawSignature {
        // The caller only reaches here with a non-empty detached signature, so
        // a signature IS present; the only question is whether an offered key
        // verifies it. With no offered key nothing can, which `signatureState`
        // renders as "signed by a key you haven't saved" — present, not valid,
        // and not an accusation.
        guard !signerKeys.isEmpty,
              let verificationKeys = try? keyRing(fromArmored: signerKeys),
              verificationKeys.countEntities() > 0 else {
            return RawSignature(present: true)
        }

        do {
            guard let builder = try pgp.verify() else { return RawSignature() }
            builder.verificationKeys(verificationKeys)
            // Note what is NOT called: `utf8()` would canonicalise line endings
            // before the check, and a detached signature covers the transmitted
            // bytes exactly. The server ships those exact bytes in
            // signedPartBase64, so the input is already what was signed.
            let handle = try builder.new()
            let result = try handle.verifyDetached(
                signedBytes,
                signature: Data(armoredSignature.utf8),
                encoding: Self.autoDetectEncoding
            )

            var verified = true
            do { try result.signatureError() } catch { verified = false }

            // A VerifyResult came back, so the signature parsed: it is present
            // regardless of whether an offered key matched. Attribution stays
            // entity-level, exactly as on the decrypt path — see rawSignature.
            let fingerprint = result.signedByKey()?.getFingerprint() ?? ""
            return RawSignature(
                present: true,
                valid: verified && !fingerprint.isEmpty,
                signerKeyID: result.signedByKeyIdHex(),
                signerFingerprint: fingerprint
            )
        } catch {
            // A signature that will not parse is absent, not invalid — matching
            // the encrypted path and Android's verifyDetached.
            return RawSignature()
        }
    }

    func fingerprint(ofArmoredPublicKey key: String) -> String? {
        guard let parsed = CryptoKey(fromArmored: key) else { return nil }
        let value = parsed.getFingerprint()
        return value.isEmpty ? nil : value
    }

    // MARK: - Writing

    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String {
        let signingKey = try Self.signingKey(fromArmored: privateKey)
        let recipients = try keyRing(fromArmored: recipientKeys)
        guard recipients.countEntities() > 0 else {
            throw PgpCryptoError.cannotEncrypt("no usable recipient key")
        }

        do {
            guard let builder = try pgp.encryption() else { throw PgpCryptoError.unavailable }
            builder.recipients(recipients)
            builder.signing(signingKey)
            let handle = try builder.new()
            defer { handle.clearPrivateParams() }
            let message = try handle.encrypt(plaintext)
            // Non-throwing in Swift because it returns a non-optional String,
            // so the error has to be read out by hand rather than caught.
            var armorError: NSError?
            let armored = message.armor(&armorError)
            if let armorError {
                throw PgpCryptoError.cannotEncrypt(armorError.localizedDescription)
            }
            return armored
        } catch let error as PgpCryptoError {
            throw error
        } catch {
            throw PgpCryptoError.cannotEncrypt(error.localizedDescription)
        }
    }

    func ownPublicKey(privateKey: Data) throws -> String {
        let key = try Self.signingKey(fromArmored: privateKey)
        var error: NSError?
        let armored = key.getArmoredPublicKey(&error)
        guard error == nil, !armored.isEmpty else { throw PgpCryptoError.unusableKey }
        return armored
    }

    // MARK: - Inspecting

    /// Armor type for a transferable secret key, as gopenpgp's constants name it.
    private static let privateKeyBlock = "PGP PRIVATE KEY BLOCK"

    /// The most keys one legacy collection may grow to by merging. Matches the
    /// keyring's own primary-member cap, so history cannot grow unbounded
    /// across re-enrollments.
    static let maxLegacyKeys = 16

    func inspectPrivateKey(armored: Data) -> PrivateKeyInventory? {
        guard let text = String(data: armored, encoding: .utf8),
              let binary = PgpFingerprint.dearmorSingleBlock(text, blockType: Self.privateKeyBlock),
              let packets = PgpFingerprint.packets(in: binary),
              packets.first?.tag == 5
        else { return nil }

        // One secret primary, then only its own subkeys and the packets a
        // transferable key may carry. A public key or public subkey packet is
        // material this device could not use, and a second primary is a
        // second key in one member.
        let allowedAfterPrimary: Set<UInt8> = [7, 2, 13, 17, 12, 21, 61]
        guard packets.dropFirst().allSatisfy({ allowedAfterPrimary.contains($0.tag) }) else {
            return nil
        }
        let secretBodies = packets.filter { $0.tag == 5 || $0.tag == 7 }.map(\.body)

        var parseError: NSError?
        guard let ring = CryptoNewKeyRingFromBinary(binary, &parseError), parseError == nil,
              ring.countEntities() == 1,
              let key = try? ring.getKey(0), key.isPrivate()
        else { return nil }
        defer { ring.clearPrivateParams() }

        // The library's own public view of what it accepted. A subkey it
        // dropped, or one it could not parse, leaves the counts unequal.
        guard let publicBinary = try? key.getPublicKey(),
              let publicPackets = PgpFingerprint.packets(in: publicBinary)
        else { return nil }
        let publicBodies = publicPackets.filter { $0.tag == 6 || $0.tag == 14 }
        guard publicBodies.first?.tag == 6, publicBodies.count == secretBodies.count else {
            return nil
        }

        var fingerprints: [String] = []
        for (secret, publicPacket) in zip(secretBodies, publicBodies) {
            let publicBody = publicPacket.body
            // A secret-key packet is its public-key body followed by the S2K
            // usage octet. Zero means the secret is stored in the clear; any
            // other value is a passphrase-protected packet (refused before
            // any password KDF could run) or a GNU dummy stub with no secret.
            guard secret.count > publicBody.count,
                  secret.starts(with: publicBody),
                  secret[secret.startIndex + publicBody.count] == 0,
                  let fingerprint = PgpFingerprint.fingerprint(ofKeyPacketBody: publicBody)
            else { return nil }
            fingerprints.append(fingerprint)
        }
        guard Set(fingerprints).count == fingerprints.count, let primary = fingerprints.first else {
            return nil
        }
        return PrivateKeyInventory(primaryFingerprint: primary, keyFingerprints: fingerprints)
    }

    func legacyInventories(armored: Data) -> [PrivateKeyInventory]? {
        let keys = Self.keys(inArmored: armored)
        guard !keys.isEmpty else { return nil }
        defer { keys.forEach { _ = $0.clearPrivateParams() } }
        var inventories: [PrivateKeyInventory] = []
        for key in keys {
            guard let inventory = Self.publicInventory(of: key) else { return nil }
            inventories.append(inventory)
        }
        return inventories
    }

    func mergeLegacy(current: Data, previous: Data) -> Data? {
        let currentKeys = Self.keys(inArmored: current)
        let previousKeys = Self.keys(inArmored: previous)
        defer { (currentKeys + previousKeys).forEach { _ = $0.clearPrivateParams() } }
        guard !currentKeys.isEmpty, !previousKeys.isEmpty else { return nil }

        var currentInventories: [PrivateKeyInventory] = []
        for key in currentKeys {
            guard let inventory = Self.publicInventory(of: key) else { return nil }
            currentInventories.append(inventory)
        }

        // Current first: signing and the Sent copy read the first key of a
        // legacy collection, so the newest material must lead.
        var kept = currentKeys
        for key in previousKeys {
            guard let inventory = Self.publicInventory(of: key) else { return nil }
            let covered = currentInventories.contains { held in
                held.primaryFingerprint == inventory.primaryFingerprint
                    && Set(held.keyFingerprints).isSuperset(of: inventory.keyFingerprints)
            }
            // A retired key is kept whole. Where the account rotated a subkey
            // under the same primary, the older entity rides behind the newer
            // one: decryption tries both, signing only ever sees the first.
            if !covered { kept.append(key) }
        }
        guard kept.count <= Self.maxLegacyKeys else { return nil }

        var binary = Data()
        defer { binary.resetBytes(in: 0..<binary.count) }
        for key in kept {
            guard let serialized = try? key.serialize() else { return nil }
            binary.append(serialized)
        }
        var armorError: NSError?
        let armored = ArmorArmorWithType(binary, Self.privateKeyBlock, &armorError)
        guard armorError == nil, !armored.isEmpty else { return nil }
        return Data(armored.utf8)
    }

    // MARK: - Private

    /// Every private, unlocked key in the given armored blobs. A blob that
    /// does not parse, or a key still wanting a passphrase, only shrinks the
    /// set; an empty set is `unusableKey`, because guessing an empty
    /// passphrase would report "wrong key" for what is really a locked one.
    private func decryptionRing(fromArmored blobs: [Data]) throws -> CryptoKeyRing {
        guard let ring = CryptoKeyRing(nil) else { throw PgpCryptoError.unusableKey }
        for blob in blobs {
            for key in Self.keys(inArmored: blob) {
                var locked: ObjCBool = false
                guard key.isPrivate(),
                      (try? key.isLocked(&locked)) != nil,
                      !locked.boolValue
                else { continue }
                try? ring.add(key)
            }
        }
        guard ring.countEntities() > 0 else { throw PgpCryptoError.unusableKey }
        return ring
    }

    /// The key that signs: the first of the blob, which in a legacy
    /// collection is the current one (merges keep it first) and in a
    /// keyring member is the member itself. `CryptoKey(fromArmored:)` cannot
    /// be used here — gopenpgp refuses armor holding more than one key, which
    /// is exactly what a merged collection is.
    private static func signingKey(fromArmored blob: Data) throws -> CryptoKey {
        guard let key = keys(inArmored: blob).first, key.isPrivate() else {
            throw PgpCryptoError.unusableKey
        }
        return key
    }

    /// Every key in one armored blob, which may be a legacy collection.
    private static func keys(inArmored blob: Data) -> [CryptoKey] {
        let text = String(decoding: blob, as: UTF8.self)
        var error: NSError?
        guard let binary = ArmorUnarmor(text, &error), error == nil, !binary.isEmpty,
              let ring = CryptoNewKeyRingFromBinary(binary, &error), error == nil
        else { return [] }
        return (0..<ring.countEntities()).compactMap { try? ring.getKey($0) }
    }

    /// Fingerprints of a parsed key, from the key packets of its public view.
    private static func publicInventory(of key: CryptoKey) -> PrivateKeyInventory? {
        guard let publicBinary = try? key.getPublicKey(),
              let packets = PgpFingerprint.packets(in: publicBinary)
        else { return nil }
        let fingerprints = packets
            .filter { $0.tag == 6 || $0.tag == 14 }
            .compactMap { PgpFingerprint.fingerprint(ofKeyPacketBody: $0.body) }
        guard let primary = fingerprints.first else { return nil }
        return PrivateKeyInventory(primaryFingerprint: primary, keyFingerprints: fingerprints)
    }

    /// Collects armored public keys into one ring, skipping any that do not
    /// parse. A key that fails to parse only ever shrinks the candidate set.
    private func keyRing(fromArmored keys: [String]) throws -> CryptoKeyRing {
        guard let ring = CryptoKeyRing(nil) else { throw PgpCryptoError.unusableKey }
        for armored in keys {
            guard let key = CryptoKey(fromArmored: armored) else { continue }
            try? ring.add(key)
        }
        return ring
    }

    /// Reads what the verification actually established.
    ///
    /// `present` is "this message carried a signature", which is true whether
    /// or not it verified — a signed message from a sender with no bound key
    /// is `present, !valid`, and that is not an accusation. Only
    /// `signatureState` decides how it reads.
    private static func rawSignature(from result: CryptoVerifiedDataResult) -> RawSignature {
        let keyID = result.signedByKeyIdHex()
        // Attribution is the entity's fingerprint, never the signature's own
        // issuer fingerprint: that one is the signing subkey's whenever a
        // subkey signed, and nothing a bound public key reports matches it.
        let fingerprint = result.signedByKey()?.getFingerprint() ?? ""

        var verified = true
        do {
            try result.signatureError()
        } catch {
            verified = false
        }

        // No key id and no attribution means nothing claimed to sign this.
        // GopenPGP returns sixteen zeroes as the issuer id for an unsigned
        // encrypted message when verification keys were configured. That is
        // a sentinel, not a signature: treating it as present made merely
        // learning a sender key turn unsigned mail into an invalid-signature
        // result.
        let hasKeyID = !keyID.isEmpty && keyID.contains(where: { $0 != "0" })
        let present = verified || hasKeyID || !fingerprint.isEmpty
        guard present else { return RawSignature() }

        return RawSignature(
            present: true,
            valid: verified && !fingerprint.isEmpty,
            signerKeyID: keyID,
            signerFingerprint: fingerprint
        )
    }

    /// Whether a decryption error is the decompressed-size cap being hit.
    ///
    /// Matched on the message because gomobile flattens every Go error to an
    /// `NSError` with the same domain and code, so there is nothing else to
    /// match on. A miss costs the precision of one exit-table row, never
    /// safety: the message is rejected either way.
    private static func describesSizeLimit(_ error: Error) -> Bool {
        let text = (error as NSError).localizedDescription.lowercased()
        return text.contains("decompressed")
            || text.contains("too large")
            || text.contains("size limit")
    }
}
