# Strong cryptography

[Product overview](../README.md) · [Security](../SECURITY.md) · [Assurance case](ASSURANCE-CASE.md)

KyPost ships one cryptographic profile, and it is the strong one. Every key the app makes,
and every key it accepts from a server or a contact, meets the NIST minimums through 2030
(SP 800-57 Part 1, as of 2012): 112-bit symmetric, RSA 2048, discrete-log 224, elliptic
curve 224, hash 224. Smaller keys are refused. There is no setting that turns them back on,
so a default install already has them fully disabled and there is nothing to configure.

Paths are relative to the `KyPost/` source folder.

## TLS: every certificate in the chain

Every URLSession in the app has `PinnedSessionDelegate` as its delegate: the shared relay
session (`App/SingletonGraph.swift`) and the pairing connection
(`Data/Networking/RelayPairingConnection.swift`). The app opens no other sockets. It speaks
no IMAP or SMTP and does not use Network.framework. On every server-trust challenge, whether
or not the host is pinned, the delegate (`acceptsServerTrust`) does three things:

1. Runs the system's own evaluation (`SecTrustEvaluateWithError`): host name, validity,
   anchors and Apple's TLS certificate rules.
2. Requires **every certificate of the evaluated chain**, anchor included, to carry an RSA
   key of at least 2048 actual bits or a prime-curve EC key of at least 256 bits
   (`hasStrongKey`). It reads the actual key size, never the RSA block size, because
   2047-bit and 2048-bit keys share one block size. A key the app cannot read or measure, or
   a key of any other type (Ed25519, for example), is refused.
3. Only then answers `.useCredential`. Otherwise the handshake is cancelled before any
   request is sent, and the error is `NetworkError.certificateRefused`.

The pin check from [SECURITY.md](../SECURITY.md#certificate-pinning) runs before these
steps. It narrows what is accepted and never replaces them.

Relay sessions also set `tlsMinimumSupportedProtocolVersion = .TLSv12`. The app declares
no App Transport Security exception, so ATS's TLS 1.2 floor and its forward-secret cipher
suite requirement apply as well.

**What this changes for a server.** A relay certificate chain with an RSA key under 2048
bits, an EC key under 256 bits (P-224), or an Ed25519 key anywhere in it, root included, no
longer connects. Reissue the certificate. Public ACME chains (Let's Encrypt ISRG Root X1
RSA-4096 and X2 P-384, with RSA-2048 or EC P-384 intermediates) are unaffected.

## OpenPGP

The app links GopenPGP v3.5.2 (`Dependencies/gopenpgp.env`) and uses its default profile
(`crypto.PGP()` → `profile.Default()`). It encrypts with AES-256 and hashes with SHA-256.
The library already refuses DSA and ElGamal keys, the secp256k1 curve, and MD5, RIPEMD-160
and SHA-1 message signatures. Its RSA minimum is 2047 bits, though, and the binding cannot
change it. `Domain/Security/PgpKeyFloor.swift` closes that gap. Every primary and subkey
packet must be RSA of at least 2048 actual modulus bits, or ECDH, ECDSA, EdDSA, X25519,
X448, Ed25519, Ed448 or one of the ML-KEM, ML-DSA or SLH-DSA algorithms. Any other algorithm
or key version is refused. `GopenPGPCrypto` applies the floor as follows:

| Use | Below the floor |
| --- | --- |
| Encrypting to a recipient | The whole message is refused, never sent without that recipient |
| A sender's signature | The key is not offered, so the signature reads as present but not verified |
| This device's own key, for signing, the Sent copy and its QR code | `unusableKey`, so sending is refused |
| Decrypting mail already received | Allowed, so mail sent to an older key stays readable |

The app does not generate OpenPGP keys. The account key is made outside the app and reaches
it through device enrollment.

## Key inventory

| Connection or key | Default | Smaller refused? | Where |
| --- | --- | --- | --- |
| Relay API, pairing, push registration, MFA, contacts, sign-on token exchange, QR key URLs (all HTTPS) | System trust, then RSA ≥ 2048 or EC ≥ P-256 on the whole chain, TLS ≥ 1.2 | Yes, the handshake is cancelled | `Data/Networking/PinnedSessionDelegate.swift` |
| Relay pin | SHA-256 of the leaf SPKI | Not applicable (hash) | `PinnedSessionDelegate.spkiSHA256` |
| Device enrollment envelope | HPKE DHKEM(P-256), HKDF-SHA256, AES-256-GCM | Yes, only this suite opens | `Domain/Security/DeviceEnvelope.swift`, `VaultSealer.swift` |
| Device key (vault seal, enrollment) | Secure Enclave P-256 | Fixed, cannot be configured | `Domain/Security/DeviceAgreementKey.swift`, `EnrollmentVault.swift` |
| Legacy vault records | ECIES X9.63-SHA256 AES-GCM to the P-256 device key, only opened, to migrate | Not created | `EnrollmentVault.swift` |
| App-lock PIN verifier | PBKDF2-HMAC-SHA256, 150,000 iterations, 128-bit salt, 256-bit output, peppered with HMAC-SHA256 under a key derived from a Secure Enclave P-256 key, or a random 256-bit key where there is no Secure Enclave | Fixed | `Domain/Security/PinHasher.swift`, `PinPepper.swift` |
| OpenPGP recipient, signer and own keys | Per the table above | Yes | `Domain/Security/PgpKeyFloor.swift`, `GopenPGPCrypto.swift` |
| OpenPGP message encryption | AES-256, SHA-256 | Library default profile | GopenPGP `profile.Default()` |

SHA-1 appears once, as the OpenPGP v4 fingerprint (`Domain/Security/PgpFingerprint.swift`),
because RFC 4880 defines v4 fingerprints that way. It identifies a key and is never a
signature or an integrity check. Version 6 keys use SHA-256.

## Out of scope

These are not code this project produces:

- the mail servers behind the relay, and KyPost-Server itself, including its TLS
  configuration and the account keys it or the web app generates;
- Apple's frameworks and OS services: APNs delivery, the TLS stack inside URLSession and
  Network.framework, WebKit's loading of remote mail content (blocked unless the user allows
  it per message), and the Secure Enclave;
- KyAuth and the identity provider behind sign-on. KyAuth enforces its own floor, in
  KyAuth-iOS `KyAuth/Networking/HTTPClient.swift`.

## Evidence

- `KyPost Tests/TransportKeyFloorTests.swift` builds real chains from
  `scripts/tls-key-floor-fixtures.sh` and evaluates them with `SecTrust`. System trust alone
  accepts a 2047-bit RSA leaf (asserted as a control), and the floor refuses it. RSA-2047
  intermediates and roots, Ed25519, untrusted and wrong-host chains are refused too, while
  RSA-2048, P-256 and P-384 are accepted. The delegate answers
  `.cancelAuthenticationChallenge` and reports `certificateRefused` for the short chain, and
  `.useCredential` for the strong one.
- `KyPost Tests/PgpKeyFloorTests.swift` holds the packet rule to known bodies (actual modulus
  bits, a header that overstates them, v6, and the allow list), and drives GopenPGP with real
  RSA-2047 and RSA-2048 keys: a short recipient, signer or own key is refused, while mail
  already sent to one still decrypts.
- CI runs both on the iOS Simulator (`ios-tests`) and compiles for macOS (`macos-build`) on
  every pull request.

**Not proven:** the floor on a physical device, or against a live relay on another OS build.
The simulator run is the evidence.
