# Security Policy

KyPost for Mac is the companion app to a self-hosted KyPost server. It holds a pairing
credential for someone's mail account, caches their mail, and — depending on settings —
their contacts, attachments, and the account's OpenPGP private key. This document covers
how to report a vulnerability and what the app does and does not protect.

For **server-side** security (TLS termination, reverse proxies, key custody at rest,
deployment hardening), see [SECURITY.md in the server
repository](https://github.com/Busnes-app/KyPost-Server/blob/main/SECURITY.md).
Report server vulnerabilities there, not here.

How the protections below fit together is argued in [docs/ASSURANCE-CASE.md](docs/ASSURANCE-CASE.md).
How to check the GopenPGP binary and a release is in [docs/VERIFYING-RELEASES.md](docs/VERIFYING-RELEASES.md).

## Reporting Security Vulnerabilities

Report vulnerabilities in the Mac app via GitHub Security Advisories rather than opening
a public issue.

1. Go to the [Security
   Advisories](https://github.com/Busnes-app/KyPost-for-Mac/security/advisories/new) page
2. Click "Report a vulnerability"
3. Provide a description, affected versions, and reproduction steps if you have them
4. Do not disclose publicly until a patch is available

If you are unsure which repository a finding belongs to, file it here and it will be
moved. A misfiled report is better than an unfiled one.

### Disclosure Timeline

Matching the server repository, so a finding spanning both is not governed by two
different clocks:

- **Critical** (credential disclosure, authentication bypass, remote code execution):
  30 days
- **High** (privilege escalation, cryptographic weakness, local data disclosure past a
  security control): 60 days
- **Moderate** (denial of service, information disclosure): 90 days

You will get an acknowledgement within 2 business days, a severity assessment, and credit
in the release notes unless you prefer anonymity.

## What the app protects, and what it does not

Read this before relying on any single control. Each section says where the control
stops.

### App lock

"Require Unlock to Open" gates the app behind Face ID, Touch ID, or the device passcode
(`Domain/Security/AppLockManager.swift`). iOS locks on backgrounding; macOS locks when
the screen locks, and not when you switch apps. If the setting cannot be read at launch
— the Keychain is often not ready yet for a Mac login item — the app starts locked and
asks again once it can. On macOS a locked window hides its toolbar and search field, and
its content is disabled and hidden from VoiceOver, not just covered.

An **app PIN** is optional and separate from the device passcode. It exists because a
verifier this app owns can be throttled by this app; `LAContext` is throttled by the OS
and cannot be.

- 8 to 12 digits (`Domain/Security/PinPolicy.swift`). Eight, not six: the verifier is
  peppered with a key that cannot leave this machine, which forces a brute force
  on-device, and 10^6 guesses is still under an hour of that where 10^8 is days.
- The first two wrong attempts are free, because typos happen; the third onward adds a
  growing delay — 30s, 60s, 5m, 15m, 30m (`Domain/Security/LockoutPolicy.swift`). The
  delay is enforced in the manager, not by a disabled button, so a second entry point
  cannot become an unthrottled oracle. The deadline is on a monotonic clock that the
  Date & Time settings cannot move; it records the boot it was set in, and after a
  restart the current delay is served again in full rather than skipped. If the deadline
  cannot be saved, the delay still holds for the rest of that session.
- After ten consecutive wrong attempts with no intervening success, local data is wiped
  (`Domain/Security/SecurityWipe.swift`). A success is a correct PIN or an unlock with
  Touch ID, Face ID or the device password; either starts the count and any delay over.
  The number is configurable (10, 20, 30 or never).
- Because an attacker gets a bounded number of guesses, common PINs are refused at set
  time. The runs, repeats, keypad walks and dates that dominate published leaked-PIN
  datasets would otherwise all fit inside the ten.
- **A PIN that cannot be *checked* is not a wrong PIN.** If the Secure Enclave key
  backing the verifier is gone or unusable, the app says so and counts nothing. Folding
  that into "wrong" is how the Android app destroyed user data in response to an
  OS-level key invalidation the user neither caused nor could avoid.
- **The wipe fails closed.** It reports each step it could not complete rather than
  claiming a clean erasure, keeps the app locked, and resumes at the next launch. It gets
  three attempts — the first run and two resumes. If the third still cannot finish it
  stops retrying — but it does *not* forget: the marker persists, and every launch from
  then on blocks the whole app behind "manual recovery required" instead of presenting a
  first-run screen over data that is still on disk. The marker is kept in both the app's
  preferences and the Keychain, so deleting the preferences file re-runs the wipe rather
  than opening the app. Reinstalling is the recovery: the next launch re-runs the wipe,
  which then completes.
- A **tripwire** covers the other direction: if the Keychain loses the stored PIN while a
  plain marker still says one was set — which is what deleting the item to disable the
  lock looks like — the app wipes at launch rather than opening the inbox. A Keychain
  that merely will not answer yet does *not* arm it; that is the ordinary state of a Mac
  mid-launch, and erasing someone's mail for a transient status would be worse than the
  attack.
- The PIN verifier's pepper lives in the Secure Enclave wherever there is one. If the
  enclave is present but will not create the key, setting a PIN fails rather than
  falling back to a weaker Keychain-only pepper.

**What it does not do:** the app lock gates the app, not the Mac. It is not a defence
against an attacker with the machine unlocked and the app already open. The escape hatch
offered after repeated authentication failures erases rather than bypasses — it is the
same security wipe, removing the pairing, everything cached and the cards exported to
Contacts — so a user locked out by a changed biometric enrolment is not stranded. The
lock comes off only once that wipe reports complete; until then the app stays locked
and the reset can be retried. A dismissed Touch ID prompt does not count toward offering
it.

### Hostile Location Protection

An opt-in mode (off by default) for users who expect their machine to be inspected or
seized. When enabled, KyPost keeps no mail, contacts or attachments on disk: the
SwiftData store and the contact-photo cache are constructed in-memory, and the enrollment
envelope is destroyed. The preferences that describe the account are held in memory
too, and what was saved before is erased when the mode is turned on and at every launch
while it is on: mail, contact and notification sync cursors, queued contact deletions,
keyword names and settings, keys you verified, keys pinned on this device, and the record
of which Contacts cards KyPost created.

Turning it *off* does not restore the envelope. Re-enrolling is a deliberate act.

**Known limitation — this removes files, it does not overwrite them.** The stated use
case is a border crossing, and that is precisely the context where "deleted" and
"unrecoverable" are different claims: on APFS the blocks survive until something
overwrites them. Turn it on before you have anything worth finding, not after.

Also still on the machine while it is on: attachment previews use the sandboxed temporary
directory briefly while open, because Quick Look needs a file; notifications you have
already received stay in Notification Center; and cards exported to Apple Contacts remain
there. Because the mode erases the record of which cards KyPost created, neither Remove
Exported Contacts nor a wipe can recognise cards exported before it was turned on — run
Remove Exported Contacts first.

### Certificate pinning

KyPost is self-hosted with a per-user server URL, so there is no certificate to hardcode.
A pin is the SHA-256 of the server's leaf SubjectPublicKeyInfo. It is stored in the
Keychain bound to the host it was seen on (`Data/Storage/SecurePairingStore.swift`), and
every connection to that host must present that key
(`Data/Networking/PinnedSessionDelegate.swift`).

- **Pairing has its own connection** (`Data/Networking/RelayPairingConnection.swift`).
  It probes the server first. The key that handshake presents must match the link's
  `pin=` if it has one, or else the pin already stored for that host; with neither, it
  becomes the pin. The registration, which sends the pairing token and receives the
  device secret, then rides that same connection, held to that pin. If no key can be
  read, nothing is sent and the pairing fails. The shared session that mail and
  background sync use only ever enforces stored pins.
- **A link cannot replace a pin.** If the host already has a pin and the link carries a
  different one, or the server presents a different key, the pairing is refused. If the
  certificate was legitimately replaced, remove the pairing in Settings → Connection,
  then pair again.
- **Re-registration never captures a pin.** A pairing that an older build left without
  one stays unpinned until it is removed and paired again. Settings → Security shows
  whether the relay is pinned.
- **Changing servers drops the old pin.** Saving a pairing for another host removes the
  previous host's pin, and the new server is pinned from its own pairing handshake.
- **It fails closed.** On a pinned host the app refuses a key it cannot hash, and a
  Keychain error while reading the pin refuses the connection rather than falling back to
  system trust.
- **Redirects stay on the origin.** A redirect to another host, another port or plain
  http is refused, so the device-secret header never follows one.
- **Relay responses are not cached.** Relay sessions are ephemeral, with no response
  cache and no cookie store. Unpair and the security wipe also empty the process-wide URL
  cache and cookie store that the relay session of earlier builds wrote to.

**Without `pin=` this is trust-on-first-use.** It detects a certificate that changes
after pairing. It cannot detect an attacker already in position *at* pairing. The web
app adds `pin=` only when the server terminates TLS itself. Pair over a network you
trust.

### Pairing credentials

The app authenticates to the server with a device id and a per-device secret. The secret
is minted by the server at registration and returned exactly once.

- It is stored in the data-protection Keychain, this-device-only. With "Require unlock
  for notifications & MFA" on, it additionally moves behind an access-controlled item
  that requires user presence, and is held in memory only while the app is unlocked.
- It authorises push delivery, pull, contact sync, MFA response and enrollment. It is
  **not** the account password and cannot be used to sign in to webmail.
- Revoke a lost machine from the server's Security page. Revocation is per-device.

### Mail content and PGP

- **Encrypted mail is decrypted on this Mac**, but only once it holds a sealed key
  envelope. Until it does, the app hands the message off to webmail in the user's own
  browser rather than decrypting anything here.
- **Composing to a recipient's PGP key encrypts on this Mac** for a client-custody
  account: the plaintext body is never sent to the relay on that path, the real subject
  travels inside the ciphertext, and each BCC recipient gets their own ciphertext so no
  recipient's key id appears in a packet another can read.
- The decrypted body is never persisted — not to SwiftData, not to the cached body field,
  not into a scene value that state restoration would archive.
- **A signature verdict is not a flat "verified".** Nine states: two describe the message
  (not signed; signature not checked) and seven its sender. The line that matters is
  identity versus continuity, and **both are decided on this device, never by the
  relay**:
  - *You confirmed this key* — only when the signing key is the one you pinned for that
    address on this device by scanning its QR code.
  - *Same key as last time* — the key matches the first key this device itself saw sign
    for that address. That history is kept per address, in memory only under Hostile
    Location Protection, and cleared on unpair and by the wipe. It is recorded only from
    a valid signature by a key whose own User IDs name the address.
  - *Signer not confirmed on this device* — a valid signature by a key only the relay
    vouches for, with no pin and no history here.
  - *This sender's key has changed* — the signing key differs from the pinned or
    first-seen key, the pin was revoked, or the relay reports a change. The relay's
    report can only add this warning; it never upgrades a verdict, and the relay's
    `verified` flag is not read at all.
  - *Signed by a key you haven't saved* and *Signature doesn't match* complete the set.
  The server's resolved sender is shown as an identity only beside a key you pinned;
  otherwise the reader shows the address the signing key names, and warns when the
  message's From is not one of them.
- **Encrypted mail is excluded from push payloads by the server**, regardless of the
  content-preview setting, because push travels through a relay and on to APNs in
  cleartext at every hop.
- The OpenPGP implementation is GopenPGP, consumed as a binary XCFramework **pinned by
  SHA-256** (`Dependencies/GopenPGP/Package.swift`). SwiftPM refuses the download if the
  bytes stop matching, which is the only property that makes an opaque binary in a crypto
  path acceptable.

#### Device enrollment

- The sealed envelope that makes on-device decryption possible is accepted **only while
  Hostile Location Protection is off**, and is destroyed when it is turned on. It is a
  deliberate, user-chosen posture change, not a default.
- The envelope is unwrapped under a Secure Enclave P-256 key created with
  `.privateKeyUsage` and `.userPresence` (device credential or biometry),
  `WhenUnlockedThisDeviceOnly`. A device with no passcode cannot enrol at all — the
  envelope's protection *is* the lock screen — and a device without a Secure Enclave is
  refused rather than given a software key.
- **The private key is never stored in the clear.** Before it reaches the Keychain it is
  sealed to that same Secure Enclave key (ECIES: ephemeral P-256 agreement, X9.63
  SHA-256 KDF, AES-GCM), header included, so the Keychain item holds ciphertext. Opening
  it is a Secure Enclave operation under the key's presence check; nothing else can.
  Fingerprint, generation and kind stay readable without a prompt, because the
  enrollment report needs them.
- **The presence prompt appears at most once per app unlock.** A successful Face ID /
  Touch ID / passcode unlock of the app hands its authenticated context to the vault, so
  opening encrypted mail does not ask again. With the app lock off, or after a PIN
  unlock, the first decrypt prompts once and that context is reused. Every lock
  trigger — locking, iOS backgrounding, the macOS screen lock, even inside a grace
  period — and every vault teardown invalidates it, and the next decrypt prompts again.
- Installs from before the seal held the key in the clear. The first presence-checked
  open seals it, proves the seal opens, and replaces the plaintext item in the same
  Keychain item; plaintext and sealed copies never coexist. Until that first open after
  updating, the plaintext item remains.
- The unsealed key is held in memory only, is zeroed on every session boundary — app
  lock, backgrounding, memory pressure, wipe, unpair — and a security wipe, Hostile
  Location Protection and the stranded-lock reset destroy both the sealed record and the
  Secure Enclave key. If the wipe cannot, it reports itself incomplete and the app fails
  closed; see **App lock** above.

### Keychain items from before the identifier rename

On 2026-08-27 the bundle identifier and Keychain access group moved from
`com.urlxl.mail` to `org.kysecurity.mail`. Keychain items are scoped to their
access group, so anything a pre-rename build stored is unreachable to the app
now — including by the wipe paths, which delete by the current service name.

No migration was added, because no build of this app has ever reached an end
user. Two bases: there is no app release and no version tag, and no
distribution pipeline existed before that date; and the maintainer attested on
2026-08-27 that no build has ever existed outside their control. Developer machines that ran a pre-rename build are
the exception. Those items stay in the data-protection Keychain,
this-device-only, reachable only by something signed with the old
team-and-group pair — but **the "erase everything" guarantee below does not
reach them**, and on a machine where that matters they should be cleared by
hand.

This is stated rather than left to be inferred so that it is auditable, and so
that the decision is revisited if the premise turns out to be wrong. See the
comment in `KyPost/KyPost.entitlements` for what to do in that case.

### What is out of scope

- **A machine with an attacker at the keyboard, unlocked, with the app open.** Every
  boundary here is already inside that.
- **Screen capture by other installed apps**, beyond the capture protection the app sets
  on its own windows.
- **The mail server itself**, and anything reachable with the account password. Those are
  server-repository concerns.
- **Attachments after they leave the app** — anything saved, moved, or opened into
  another app is beyond this app's reach.

## Export compliance

The build does **not** carry `ITSAppUsesNonExemptEncryption`. Each build therefore waits
in "Missing Compliance" until someone answers the encryption questions for it in App Store
Connect, and those answers are the declaration: **uses encryption: yes; standard
algorithms, not proprietary; not available in France.**

It used to be set to **true** in the build settings. App Store Connect then refused every
upload ("Invalid Export Compliance Code") because the app record carries an encryption
declaration filed on 2026-08-28 for the French store, still in review and without a code,
and a build that declares encryption must carry that declaration's
`ITSEncryptionExportComplianceCode`. The app is not offered in France, and App Store
Connect creates no declaration for standard third-party cryptography outside France
(its API answers 409 to one), so there is no code to give. Leaving the key out moves the
same answers from the plist to App Store Connect. If Apple withdraws the August
declaration, setting the key back to `YES` is safe again.

Answering yes is deliberate and is the conservative reading. KyPost implements OpenPGP for
the **confidentiality of message content**, using GopenPGP rather than the encryption
Apple's operating systems provide. That is what makes it non-exempt:

- It is not limited to authentication, digital signatures, or decryption only, which is
  the exemption most often claimed (Category 5 Part 2, exemption (c)). KyPost encrypts
  outgoing mail.
- It is not "encryption available only through Apple's operating system", which is the
  other common route. The crypto is a third-party binary in this repository.

Declaring `false`, in the plist or in App Store Connect, would be faster and would be a misdeclaration.

**This is not the whole obligation, and the remaining part is not a code change.** An app
declaring non-exempt encryption is normally self-classified as mass market under ECCN
5D992.c, which carries an annual self-classification report to BIS and the NSA, and App
Store Connect will ask for the resulting documentation. That filing is a human step and
it has not been done. Someone with the authority to make an export-control declaration
on behalf of this project needs to confirm the classification before the first
submission — treat the App Store Connect answers as recording a decision, not as making one.

## Supported versions

Security fixes target the current release. There is no long-term support branch for older
versions.

## Security Contacts

- **Vulnerability reports:** [GitHub Security
  Advisories](https://github.com/Busnes-app/KyPost-for-Mac/security/advisories/new)
- **Maintainer:** [Yoshiofthewire](https://github.com/Yoshiofthewire)
- **Code of Conduct concerns** are handled separately — see
  [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Security vulnerabilities are not a Code of
  Conduct matter.
