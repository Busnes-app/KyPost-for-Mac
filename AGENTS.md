
# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## Testing

- Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`.
- iOS-only code (`#if os(iOS)`, e.g. `KyIdentitySignOnCoordinatorTests`) runs
  only under an iOS destination: `xcodebuild test -scheme "KyPost"
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
- `KyPost.xctestplan` is the shared test plan, referenced from the
  shared scheme. Both test targets set `parallelizable: false`, and that must
  stay off.
- `KyPost UITests/ScreenshotTests` is a **capture run, not a check**, and
  skips itself unless `KYPOST_SCREENSHOTS=1` is in the environment. Keep that
  skip: it drives the app for minutes, and on macOS it needs UI automation
  (`sudo DevToolsSecurity -enable`) that an ordinary machine will not have.
  Run it through `scripts/capture-screenshots.sh` — see the demo-build
  contract in `KyPost/App/AGENTS.md`.

  Swift Testing parallelizes test functions in-process by default. With it on,
  roughly one full-suite run in six aborts with SIGABRT: an uncaught
  Objective-C exception is thrown inside SwiftData/CoreData's
  `performBlockAndWait` and rethrown across the block boundary, killing the
  process. Whichever tests are in flight are then reported as failures, so the
  names change every run and are unrelated to the real fault — pure JSON and
  theme tests "fail" in 0.000s because they never ran. No single test is the
  trigger (skipping the prime suspect does not help), and the app itself is
  unaffected: it opens exactly one ModelContainer, where the suite opens dozens
  concurrently.

  Note `parallelizable` belongs on each entry in `testTargets`, not in
  `defaultOptions`, where it is silently ignored.

- **The GopenPGP binary bakes in `GODEBUG=asyncpreemptoff=1`; nothing sets
  it at run time.** Without it the embedded Go runtime kills whatever process
  links it, the shipping app as well as the test host:

  ```
  signal 16 received on thread with no signal stack
  fatal error: non-Go code disabled sigaltstack
  ```

  Signal 16 is `SIGURG`, which Go sends for async goroutine preemption; it
  lands on a thread whose alternate signal stack non-Go code has removed. In a
  macOS crash report it shows only as `EXC_CRASH (SIGABRT)` with
  `runtime.raise_trampoline` ← `runtime.asmcgocall` on the crashed thread (the
  Go frames are stripped); the text above goes to stderr. A UI launch test
  reports it as "Application 'org.kysecurity.mail' does not have a process
  ID".

  **Where it is set, and why there.** `gopenpgp-xcframework.yml` adds
  `-X=runtime.godebugDefault=asyncpreemptoff=1` to upstream's `build.sh`
  ldflags. The runtime reads that string in `schedinit`
  (`parsedebugvars`) before any Go code runs. The alternatives do not work:
  `setenv` in the app is too late, because the c-archive runtime starts from
  an image constructor before `main`, and cmd/go rejects `asyncpreemptoff` in
  a `godebug` directive or `//go:debug` line (it accepts only the keys in
  `internal/godebugs`). A `GODEBUG` environment variable still overrides the
  default. The workflow checks every slice carries the value.

  **Measured 2026-10-13** (macOS 26.5.2, Xcode 27.1, GopenPGP v3.5.2 built
  with Go 1.26.5 locally and 1.27.2 in CI, `KyPost.xctestplan` with no
  `GODEBUG`, alternating runs):
  - full `KyPost Tests`: **4 crashes in 8 runs without the baked default, 0
    in 8 with it**, then **0 in 8 more against the published pin**;
  - launching the app binary for 20 s: **3 of 8 died without it, 0 of 8 with
    it**; the launch UI test failed 1 of 8 without it, 0 of 8 with it.

  It only turns off async preemption; goroutines still yield at function
  calls. A GopenPGP rebuild that drops the flag brings the crash back in the
  app, not only in tests. If it ever returns with the flag present, a bounded
  retry keyed on this exact signature is the test-side fallback, never a
  blanket job retry.

## Local Contracts

### The OpenPGP library (`Dependencies/GopenPGP`, `Domain/Security/PgpCrypto.swift`)

GopenPGP is consumed as a **binary XCFramework pinned by SHA-256** in
`Dependencies/GopenPGP/Package.swift`. SwiftPM refuses the download if the
bytes stop matching, which is the only property that makes an opaque binary in
a crypto path acceptable.

- The binary is built by `.github/workflows/gopenpgp-xcframework.yml` from
  ProtonMail/gopenpgp at the tag in `Dependencies/gopenpgp.env`, using
  **upstream's own `build.sh`** rather than a reimplemented `gomobile bind`.
  Reimplementing it got three things wrong that the script encodes; call the
  script. The workflow's one patch to it adds
  `-X=runtime.godebugDefault=asyncpreemptoff=1` to its `-ldflags`, fails if
  that line stops matching, and checks every slice carries the value after
  the build (see the GODEBUG note under Testing). Keep it on any rebuild.
- Track plain `vX.Y.Z` tags. `vX.Y.Z-proton` builds against Proton's
  go-crypto fork and swaps in Proton's own default profile.
- **The build is not bit-reproducible.** Two runs of the same pinned tag
  produced different hashes. gomobile embeds build IDs and paths and the job
  does not pin Xcode, so the checksum identifies one specific build. Do not
  write a verification procedure that assumes rebuilding reproduces the hash.
- **Verify a checksum against the asset, never against the release notes.**
  The first release's notes quoted a hash the asset did not have, because two
  workflow runs raced and one clobbered the other's upload. The workflow now
  serialises and refuses to overwrite an existing release, but the habit is
  what protects you: `shasum -a 256` the download, or read GitHub's own
  `digest` field.
- **Only `PgpCrypto.swift` and its conforming types may `import Gopenpgp`.**
  The v2→v3 API break is recent enough that a swap must touch one file. The
  reader, compose, and the signature binding must never learn which library is
  underneath.

### Client-side encrypted send (`Domain/UseCases/ClientEncryptedSender.swift`)

Each rule below is a defect someone already found once.

- **Recipient keys come from `POST /api/pgp/recipients/resolve`,** and this is
  the only path that may call it. Everywhere else uses `/check`, which answers
  "is there a usable key" without handing back key material. The two also
  differ in error shape: on `/resolve`, 200/409/413 are JSON while 400/500 are
  plain text.
- **Split with `splitRecipientFields`, never the preflight's splitter.** That
  one dedupes across To/CC/BCC and collapses a BCC recipient into the To
  header.
- **To and CC share delivery 0; each BCC gets its own ciphertext,** so no BCC
  recipient's key id appears in a packet another recipient can read. Delivery 0
  stays first: index 0 failing is a hard failure server-side, later ones only a
  warning.
- **`OutgoingEnvelope` has no `bcc` field by construction,** and the writer
  emits a fixed, closed header set with no caller-supplied path. That is what
  structurally guarantees the relay's forbidden headers (`Received`,
  `Authentication-Results`, `Return-Path`, `Bcc`) can never appear.
- **The real subject rides inside the ciphertext** as a protected header; the
  outer subject is always `outerPlaceholderSubject`, matching the server's
  constant.
- **The Sent copy is encrypted to the public half of the vault key,** never to
  anything the server supplied. A hostile server handing back "your" key would
  otherwise get a readable copy of every message sent.
- **`tier == "key_changed"` is a broken TOFU pin** — a distinct, louder
  outcome checked *before* "no key on file", never folded into it.
- **There is no pickup fallback here and there must not be.** The server-side
  one works by storing plaintext, which is the thing client custody exists to
  prevent.
- **Resolve before unlocking.** A send that was going to be refused anyway must
  not interrupt the user for a biometric they gain nothing from.
- `sanitizeHeaderValue` **must iterate `unicodeScalars`.** In Swift `"\r\n"` is
  a single `Character` equal to neither `"\r"` nor `"\n"`, so a `Character`
  loop lets CRLF through and header injection works.
- **Sign with `HeldKeyMaterial.signingKey` only** — a keyring's explicit active
  member, or the first key of a legacy collection. A retired key is never a
  fallback. gopenpgp's `CryptoKey(fromArmored:)` refuses a multi-key armor, so
  `GopenPGPCrypto` takes the collection's first key itself.
- **`materialGeneration` rides on `/api/mail/send-pgp`** when a keyring is held
  and is **omitted** (never null, never invented) for legacy armor. The two
  converted-account 409s are told apart by JSON field — `reenrollmentRequired`
  checked first, then `pgpStateChanged` — and are their own `ClientSendOutcome`
  rows, each with its own sentence naming re-enrollment. Never by prose.

### Keys pinned on this device (`Data/Storage/RecipientPinStore.swift`)

The minimal port of Android's `recipient_pins` (#191). This client had no
per-address on-device pin before — `VerifiedPgpKeyStore` is per-uid memory for
holding a synced key change for review, and the relay's TOFU (`key_changed`)
is the server's pin, not this device's.

- **A key verified here by QR is authoritative for its addresses.** The QR
  save (`saveContact(_:verifiedInPerson: true)`) pins the contact's key for
  each of its emails, replacing what was pinned; re-scanning is how a pin
  changes. A contact with no email gets no pin. Sync never writes a pin.
- **The one thing a synced copy may do is revoke it**, recorded on every
  contact write (sync and local), never on a lookup:
  `PgpKeyRevocation.withRevocations` takes only revocation signatures of
  the pinned primary or of a subkey the pin holds, from a copy of the same
  primary; nothing else crosses. `OpenPgpKeySections` moves packets and
  decides nothing. **GopenPGP is the only verifier**: it checks every
  revocation in the pin against the pinned primary whenever the key is used
  and disregards one that fails. A primary revocation is kept when the key
  then reads `isRevoked`. A subkey revocation must be well formed, at most
  8 KiB, and leave the library reading the same key with no ability gained;
  then it is judged on that subkey alone (primary plus that one subkey).
  Where the subkey grants something the primary alone does not (encrypting,
  or signing under a non-signing primary), it is carried **only if** that
  capability goes — nothing the library disregards is stored. Where it does
  not (a signing subkey under a signing primary: GopenPGP has no per-subkey
  query) it is carried unjudged, up to `maxRevocationsPerSubkey`, and one
  more **withdraws that subkey from the pin** instead of being refused.
  **A bound must never keep a genuine revocation out.** **Never gate
  the unjudgeable case on an observed change, and never add a hand-written
  signature check**: a Swift verifier only covers the algorithms and hashes
  someone remembered — every gap is a genuine revocation dropped and a
  compromised subkey still confirmed.
- **Reader:** where the resolved sender is pinned, the pin replaces the relay's
  `signerKeys` (`EncryptedMessageReader.signerKeys`) — intact is the only key
  and reads `verifiedConfirmed`; revoked or broken is a conflict, so a signed
  message reads `keyChanged`. Keyed on `resolvedSender`, never a parsed `From`.
  The reader takes a pin provider, not a snapshot, and reads it on every
  attempt: a reader lives as long as its screen.
- **Sender:** `ClientEncryptedSender.applyPins` runs after resolve and before
  the vault opens. Revoked → `recipientKeyRevoked` ("verify the new key by
  QR"); broken, or a relay key whose bytes fingerprint differently →
  `keyChanged`; a match encrypts to the pinned bytes. The sender also takes a
  pin provider and reads it twice: after resolve, and again after the vault
  opens with no await before encrypting (`recheckPins`). A recipient whose
  pin no longer lands on the key already chosen stops the send with the same
  two outcomes; it is never re-chosen silently.
- A pin is trusted only while its bytes fingerprint to the stored fingerprint
  (`broken` otherwise, never "absent"). The reader and sender each take a
  provider returning a `RecipientPinSnapshot` value, never a snapshot taken
  at construction; `pins:` is deliberately not defaulted on either. Memory-only under Hostile Location Protection — and erased from
  defaults when the mode turns on and at every launch while it is on
  (`AppEnvironment.eraseHostileLocationDefaults`) — swept by the wipe, cleared
  on unpair.

### Contacts: sync status and vCard export

- **Sync status** (`Domain/Models/ContactSyncStatus.swift`, Android #182):
  waiting while named `needsSync` contacts or delete tombstones are queued;
  stuck when one is over an hour old or three syncs in a row failed. Nameless
  contacts are held back on purpose and are not counted. The failure count
  lives in `ContactSyncRepository.health`, **in memory only**; not paired is
  not a failure. The reason shown is the newest failure's first line, at most
  200 characters — for `NetworkError.transport`/`.decoding`, their own
  description, which `localizedDescription` would drop. The outbox count also
  lives in `health.pending`, recounted by the repository after every write and
  every sync, so syncs the change monitor runs reach the banner.
- **vCard** (`Utilities/VCard.swift`, Android #184): 4.0 or 3.0; every value
  escaped and stripped of control characters by **unicode scalar** (C0, DEL,
  C1, U+2028/2029 — wider than Android), so no field can start a property or a
  second card; BDAY only for a real `YYYY-MM-DD`; the server uid is never
  written. Shared through `ShareLink` over a `DataRepresentation`, so this app
  writes no file; refused under Hostile Location Protection with an
  explanation (`VCardShareMenu`).

### Reading client-protected mail (`Domain/UseCases/EncryptedMessageReader.swift`)

- **The decrypted body is never persisted.** Not to SwiftData, not to the
  cached body field. It is returned to the caller and lives for the life of the
  view showing it.
- **The exit table is eleven distinct cases, not one error string.** Each gets
  its own sentence and sometimes its own button. Two that are easy to get
  wrong: `cancelled` is not an error — the user dismissed a sheet they raised,
  so the screen simply goes back to offering Decrypt; and `noEncryptedContent`
  is *terminal*, so the UI must not offer Retry. `readOutcomeAllowsRetry` is
  the single place that decides this.
- **`signerKeys` arrive already narrowed to the resolved sender.** Do not
  re-narrow them, and never parse a `From` header to do it. Android shipped
  exactly that and a differential harness caught it disagreeing with the
  server's parser on 27 of 111 adversarial headers.
- **PGP payload DTO defaults use `decodeIfPresent`.** The relay omits false and
  empty signer-key fields, so synthesized decoding turns the first ordinary
  signing key into a fetch failure instead of applying the documented defaults.
- **Render `resolvedSender`, never the raw `From`,** wherever a verdict is
  shown. The two are separable by an attacker, and a correct verdict displayed
  next to the wrong address is still a lie.
- A decrypt failure must **not** clear `EnrollmentSession`. One message failing
  says nothing about the held key, and clearing re-prompts for every later
  message.
- **The decrypted body never leaves `EncryptedReadViewModel`.** It is not
  written to SwiftData, not assigned to the cached body field, and not carried
  into a scene value that state restoration would archive. `forget()` runs on
  disappear. An iOS layout switch rebuilds the reader, so it counts as one:
  the message stays open (its row, in `MailShellState`), its plaintext goes,
  and the new reader decrypts again at once if the key is still held, else
  offers Decrypt.
- **Opening client-protected mail decrypts immediately when its key is held.**
  If the key needs unlocking, opening the message shows Decrypt without
  prompting; that deliberate action raises the unlock prompt. Cancelling is a
  non-error and leaves Decrypt available for another attempt.
- `EnrollmentSession` holds the key material as bytes it can zero — **every**
  member of a held keyring and its original bytes, not just the active key —
  and every session boundary must clear it: app lock, backgrounding, memory
  pressure, security wipe, unpair. Android's equivalent was missed by the wipe
  path, which then reported "Complete" with the private key still in the
  process heap. Its storage is plain stored fields, not an enum payload:
  zeroing a bound payload copy triggers copy-on-write and misses the original.
- **Decrypt with every held key** (`HeldKeyMaterial.decryptionKeys`): mail
  encrypted to a retired key, or to a hidden recipient, only opens that way.
- **Decrypted attachments stay in memory** (`DecryptedBody.attachments`,
  Android #109). `PgpMimeReader` keeps at most 50 parts and 4 MiB decoded,
  drops an over-cap part whole (never truncated) and sets
  `attachmentsOmitted`, which the screen says out loud. A
  `multipart/signed`'s `application/pgp-signature` part is transport, not a
  file. Quick Look needs a file, so `DecryptedAttachmentFiles` stages one per
  preview under `attachments/decrypted` (inside the root the wipe and the HLP
  purge delete); the view model deletes it when the preview closes and in
  `forget()`. Save As goes only where the user picks, and is refused under
  Hostile Location Protection like any attachment. When the app lock engages
  the reader closes the preview and the save panel and calls `forget()`;
  Decrypt is offered again after unlock. `forget()` also voids a read still
  in flight, so a decrypt finishing after it keeps nothing.
- **`cid:` images become `data:` URIs** (`InlineImages`) for png/jpeg/gif/webp
  only, within 128 KiB per message; anything else keeps its unresolvable
  `cid:`. Markup inside an HTML comment or a raw-text/RCDATA
  element (`script`, `style`, `textarea`, `title`, `xmp`, `iframe`,
  `noembed`, `noframes`, `plaintext`) is text, as an HTML parser reads it: it
  is never rewritten and spends no budget. `data:` images render with `loadsSubresources` off (verified against
  WebKit), so remote content stays blocked.
  **The scan must stay linear on any input** (`MarkupScanner`): no
  backtracking pattern over an open-ended tag or body; malformed markup made
  the old single regex slow down quadratically. Tag names match as ICU
  case-insensitive matching does (`<ſcript>` is a script), so the test
  diffs the scanner against that old pattern. A body over
  `InlineImages.maxScannedLength` (1 Mi UTF-16 units) renders without inline
  images. `EncryptedReadViewModel.renderedHTML` is computed once per read,
  off the main actor (`@concurrent`), never in a view's body.
- **A nested MIME signature is detected, not verified** (#111). With no packet
  signature the verdict is `unchecked` ("Signature not checked") when a
  `multipart/signed; protocol=application/pgp-signature` wrapper exists at any
  depth, else `unsigned` ("Encrypted, not signed"). Both are message-level:
  shown without a resolved sender and never marking a row.
- **Reply, Reply All and Forward are closed on client-protected mail**
  (`mayReplyOrForward`): quoting the plaintext would put it in an archived
  `ComposeDraft`, and the webmail handoff uploads a server draft. The buttons
  stay pressable and explain.
- **The reader has no webmail fallback** (`KyPost/Presentation/AGENTS.md`): no
  "Open in webmail" link, not on a failed decrypt, the reply gate, or dropped
  attachments.

### Signature attribution is entity-level (`Domain/Security/GopenPGPCrypto.swift`)

A signature is attributed to a bound key by **entity fingerprint**, never by
key id. This is not a style preference; the two live at different levels and
mixing them fails silently:

- `VerifyResult.SignedByKeyIdHex()` returns the signature packet's *issuer* id,
  which is the signing **subkey's** whenever a subkey signed.
- `KeyRing.GetHexKeyIDsJson()` returns `PrimaryKey.KeyId` per entity — no
  subkeys, and there is no API that lists them.

Match one against the other and every subkey-signed message resolves to
"unknown signer" — no error, no alarm, and in the safe direction, which is what
makes it survive review. `SignedByKey()` returns the entity, so its fingerprint
is comparable to what a bound public key reports about itself.

Two further rules that are only visible as things the code does **not** do:

- Never call `insecureDisableUnauthenticatedMessagesCheck`,
  `insecureAllowDecryptionWithSigningKeys`, `disableIntendedRecipients` or
  `disableVerifyTimeCheck`. Each is an opt-out, so integrity checking and
  signature strictness are what happen by leaving them alone. Adding one would
  read like a fix for a decryption failure.
- `maxDecompressedMessageSize` must stay set to `maxDecompressedPlaintextBytes`.
  The library enforces the cap *during* decompression; the default is not this
  app's cap, and without it an encrypted zip bomb is an OOM kill.

GopenPGP also verifies against the **decryption key** whether or not it was
offered, so self-sent mail reads as verified. Harmless — signing needs the
private half — but a test whose message is signed by the key that decrypts it
is not testing which keys are trusted.

### Device enrollment (`Domain/Security/DeviceEnvelope|EnrollmentVault|EnrollmentCeremony`)

- **Gated on Hostile Location Protection being off.** Enabling HLP destroys the
  envelope; turning HLP back off does not restore it, and must not — the user
  re-runs the ceremony deliberately. Checked at the start of the ceremony *and*
  again before storing, because the user can flip it mid-window.
- **A device with no passcode cannot enrol.** The envelope's protection *is*
  the lock screen. Report it, do not degrade.
- The device key allows the **device credential**, not biometry alone. Biometry-
  only invalidates on every enrollment change, costing an ordinary user a full
  re-ceremony — and enrolling a biometric already requires the passcode, so the
  attacker it would exclude already holds what the key accepts.
- Adopt an existing device key only if it still matches the spec. Presence
  alone means a key from an earlier build with weaker parameters is reused
  forever with no signal, silently breaking the migration the design plans for.
- The envelope AAD is **length-prefixed**, and the fingerprint is normalised
  and validated where the AAD is built — not by doc comment. Space-grouped hex
  reaching an AAD that strips whitespace produces an authentication failure the
  design reports as a substituted-key alarm.
- A failed open is **hostile or stale, never a retry**. A 404 on the envelope
  covers both "never sealed" and "expired" — one case, so a caller cannot split
  them.
- The enrollment code is derived from **this device's own key material**, never
  from anything the server returned, or the comparison compares the server
  against itself. 14 Crockford characters: the search is offline, so length is
  a work factor, not a per-attempt probability.
- The ceremony takes no platform types. That is what makes its whole exit table
  a plain unit test; if a port of it needs a host app to test, the port went
  wrong.

Device-envelope v3 (KyPost-Server #199/#201/#210; Android `a20a533e` et al.):

- **Publish `envelopeVersions: [2, 3]`** (`supportedEnvelopeVersions`). Omitting
  it resets the server's claim to `[2]` and the browser refuses to seal v3.
- **The version picks the HKDF info and AAD domain** (`envelopeDomain`); a v3
  envelope is never retried as v2. v3 framing is strict where v2 stays lenient:
  numeric `v`, exactly five fields, 128 KiB, canonical padded base64, an
  on-curve point; its AAD needs a non-empty device id and a 40/64-hex
  fingerprint.
- **A v3 envelope is opened only with the delivery metadata** from
  `GET /api/pgp/device/envelope` (`version`, `materialGeneration`, `keyring`).
  The opened `kypost-pgp-keyring-v1` ring (`PgpKeyring.swift`) must name the
  AAD's fingerprint as active and match the delivery exactly — generation,
  primary set, full inventory — else `keyringRejected` and nothing is touched.
- **Every member's fingerprints come from its own packets** via
  `PgpKeyInspecting`: one unprotected secret key per member (S2K usage octet
  zero after the library's own public body), no public-only or dummy packets,
  no subkey the library dropped. Subkey **binding signatures are not verified**
  — gomobile exposes no API for it (Android checks them; a known gap).
- **History is never overwritten** (`KeyringImport.swift`). A v2 re-enrollment
  merges with the sealed legacy collection, current key first. A keyring
  replaces a previous record only if it is the identical bytes (replay, nothing
  rewritten) or a newer generation whose inventory contains every key held —
  deliberately more permissive than Android's refuse-all-incomparable, and
  equally lossless. Anything else keeps the previous record.
- **The vault is one Keychain item** (`VaultRecord`: kind, generation,
  fingerprint, material), so replacement is atomic and a failed write leaves
  the old record. The earlier two-item layout is still read and retired on the
  next store. A record that will not decode throws; it is never sealed over.
- **Order: validate → store durably → hold → acknowledge.** No session install
  and no acknowledgement for material not on disk.
- **Acknowledge with metadata.** A keyring is confirmed as
  `{encryptionEnrolled, envelopeVersion: 3, materialGeneration, fingerprint}`,
  never the bare boolean. A 409 is `acknowledgementRefused`, terminal, never
  retried — and it clears any pending marker an earlier failed delivery left.
  A transient failure sets a pending marker that `EnrollmentStateReporter`
  restates on the next unlocked foreground (Android: WorkManager), up to
  `maxEnrollmentReportAttempts`.
- **Each pending marker carries a revision** minted per delivery. The reporter
  clears or advances it only via `replacePendingReport(ifRevision:)` with the
  revision it read before sending, so a request that finishes after a
  re-enrollment cannot erase or rewind the newer marker.
- **Teardown marker (Android `b0786ee8`).** Enabling Hostile Location
  Protection destroys the vault *then* marks it, so the reporter tells the
  server `encryptionEnrolled: false`. `destroy` leaves the marker; `store`
  clears it; dropping the pairing (unpair, reset, security wipe) clears both
  markers, because no device row is left to correct. `notEnrolled` is sent
  only on that proven loss, never because a probe found nothing.

### PGP signature trust (`Domain/Models/PgpSignatureState.swift`)

- **There is no client-side `From` parser, and there must not be one.** Android
  deleted theirs after a differential harness over 111 adversarial headers found
  27 divergences from the server's parser — worst, the RFC 5322 comment
  `Bob (Eve <eve@evil>) <bob@x>`, where the server binds `bob@x` and the client
  bound `eve@evil`, letting any contact forge a verified badge for anyone.
  Three fix rounds each closed one construct and opened another. The server
  ships `signerKeys` already narrowed to the sender it resolved; consume that
  narrowing, never reproduce it.
- This app has two address parsers and **neither may reach a verdict**:
  `RelayMailSource.splitSender` fills display fields, and `EmailAddress.parse`
  builds outgoing recipients. Audited 2026-08-18; keep them apart.
- Eight states, not verified/unverified (`unsigned` and `unchecked` describe
  the message, the other six its sender). The line that matters is **identity**
  (`verifiedConfirmed` — confirmed out of band) versus **continuity**
  (`verifiedSeenBefore` — same key as last time). Most keys arrive by Autocrypt
  harvest, so a flat "verified" overclaims for nearly all of them. The wording
  is part of the contract.
- Ordering is load-bearing: a `conflict` outranks both a good key and an
  invalid signature for the same sender, because reporting the survivor as
  verified hides precisely the event worth reporting.
- `signerUnknown` is **not an accusation** and does not mark a row: an ordinary
  correspondent not yet in the address book, a rotated key, and a forgery are
  locally indistinguishable.
- Key-id extraction is injected. An unparseable bound key must only ever shrink
  the candidate set, never grant a pass, and subkey ids must match — a signing
  subkey's id differs from the primary's, so matching only the primary rejects
  every normally signed message.

### App lock, PIN, lockout and wipe (`Domain/Security/AppLockManager|SecurityWipe`)

Phase 11 **reversed** the earlier "verification is `LAContext`'s job, lockout is
the OS's" position. It held while `LAContext` was the only verifier; a PIN
checked in this process has no OS counter behind it, so this app owns the
throttle. `AppLockStore` and the README say so in place rather than having the
old sentence edited out.

- **A PIN that cannot be *checked* is not a wrong PIN.** `PepperUnavailable` →
  `UnlockAttemptOutcome.verifierUnavailable`, which does **not** advance the
  wipe counter. Folding the two together is how Android destroyed user data in
  response to an OS-level key invalidation the user neither caused nor could
  avoid. `PinHasher.matches` therefore throws instead of returning false.
- **`PinPepper.ensureExists` is only called when setting a PIN**, never when
  verifying one. Minting a pepper on the verify path makes every later correct
  PIN read as wrong, and ten of those wipe the machine.
- **Minimum length is 8, not 6.** Iteration count cannot defend a small
  keyspace; the pepper forces brute force on-device, and 10^6 is an hour of
  that where 10^8 is days. Runs, repeats, keypad walks and dates are refused
  because ten guesses makes them a real risk.
- **Every PIN check goes through `attemptPinUnlock` or `verifyPinThrottled`.**
  A screen that checks the store directly is an unthrottled oracle that never
  advances the wipe counter. Both serialise through one in-flight task: two
  concurrent checks otherwise read the same count, both write `n + 1`, and both
  clear the lockout gate at the same instant.
- The lockout deadline is on **`CLOCK_MONOTONIC_RAW`**, and clamped to the
  stored duration. A wall clock is cleared from the Date & Time pane; a
  monotonic one restarts at zero on reboot, so without the clamp a reboot reads
  the deadline as the whole previous uptime.
- **The tripwire is armed by `setPin`, not by `setLockEnabled`.** The PIN is
  optional on this platform, so arming it with the toggle would make
  "configured, and the PIN vanished" true immediately and wipe the machine at
  the next launch. `unreadable` never arms it either — a Keychain that will not
  answer yet is the ordinary state of a Mac mid-launch.
- **The wipe threshold is the user's: 10 (default, kept from before the
  setting existed), 20, 30, or never** (`WipeThreshold`). It lives in the
  Keychain tagged with the PIN pepper's HMAC (`WipeThresholdSeal`), and
  anything that does not verify — forged, garbled, half-written, unreadable,
  pepper gone — reads as 10, never as the looser value it claims.
  `AppLockManager.verify` re-reads and re-verifies it on every attempt; the
  `wipeThresholdSetting` mirror is for the UI only. Loosening it (or the grace
  period) re-authenticates; tightening applies directly.
- **The grace period is a monotonic deadline, not only a timer**
  (`lockAfterGrace` / `resolvePendingLock` / `returnedWithinGrace`). iOS
  suspends the app, so a timer cannot be the control: every gate that reads
  `isLocked` after a background trip (foreground, `BGTaskScheduler`, macOS
  wake, `presentLocally`) resolves the deadline first. A firing timer resolves
  rather than locks, and a successful unlock clears the deadline (Android's
  2026-08-28 fixes). The trigger still drops `EnrollmentSession` at once, an
  earlier deadline is never pushed back, and an unknown stored delay reads as
  Immediately (the default — iOS pickers do not background the app, so
  Android's 30 s reason does not carry over). The macOS screen-unlock
  notification is a hint: only `screenUnlockReported(verifiedUnlocked: true)`,
  confirmed from the login session's own state, cancels the deadline.
  `SingletonGraph.shutdown()` calls `AppLockManager.shutdown()` so a superseded
  graph's timer never fires. A failed threshold save still refreshes
  `wipeThresholdSetting` from the verified store.
- **PIN entry caps at `PinPolicy.maxLength` through `PinPolicy.capped`**, never
  a literal (Android #139 shipped a 6-digit cap against an 8–12 policy).
- **The wipe fails closed.** `WipeResult.complete` is only returned when every
  step ran; a step must not catch its own errors, or the step cannot fail and
  the claim cannot be supported. An incomplete run keeps its marker, resumes at
  the next launch, and after `SecurityWipe.maxResumes` sets `abandoned` —
  which stops the retries **without** forgetting. Clearing the marker to
  express "giving up" is the bug that presented a clean first-run app over data
  that was never deleted.
- **Order: in-memory plaintext, then local files, then network.** The
  deregister is not a step and is never folded into the result — an unreachable
  relay says nothing about local data, and counting it would keep the resume
  marker set forever.
- **Read the pairing before the wipe, not at the deregister's call site.** The
  `pairing` step deletes what that call authenticates with.
- The Hostile Location Protection posture is captured at the start and restored
  after the defaults sweep, and is **sticky across resumes** — re-reading it on
  a resumed run reads defaults the interrupted run already swept and loses the
  setting permanently.
- `SecurityWipe` takes its steps as a parameter. That is what makes its whole
  exit table a plain unit test; `SecurityWipeSteps` is the only half that knows
  about SwiftData, Contacts and the Keychain.

### Phishing flag and message-body navigation

- `$Phishing` is the reserved RFC 8621 keyword the server sets on mail
  impersonating KyPost. Matched case-insensitively and trimmed, because IMAP
  keywords are case-insensitive and a server may echo back `$phishing` for a
  keyword set as `$Phishing`. Exact match — `$PhishingReport` is a different
  keyword. The message is flagged **in place**: nothing moves or hides mail.
- The relay's `keywords` array must stay decoded and **unioned** with the
  tab-derived label, never replacing it. The label drives the tab strip; the
  wire list carries protocol keywords. Dropping either loses something.
- `$`-prefixed keywords are IMAP protocol flags, not user labels: they are
  filtered out of the tab strip, the row chips, and the Keywords settings
  screen. The phishing warning must not be hideable. (Divergence from Android,
  whose `KeywordTabs.buildTabs` does not filter them.)
- **The message body reaches only http/https.** An allowlist, not a denylist.
  Handing a link tap to `openURL` hands it to the system, and the system routes
  this app's own scheme back into this app — so a `kypost://native-pair` link
  in a message would raise the pairing confirmation on top of the sender's
  pretext. A mail body has no business opening `file:`, `tel:` or any other
  scheme either, and a denylist needs updating every time one appears.
- Un-gestured navigations stay blocked regardless of scheme: a
  `<meta http-equiv="refresh">` is plain HTML and a main-frame navigation, so
  neither the JavaScript switch nor `loadsSubresources` touches it.

### Mail delta sync (`Data/Mail`, `Data/Storage/MailCursorStore.swift`)

- **A message is (folder, messageId), never the id alone** (`MailRowKey`,
  `Email.id`). The relay's id is a bare IMAP UID on IMAP accounts, unique only
  within one mailbox, so INBOX and Sent can both hold `42`. `EmailEntity` is
  `#Unique` on the pair (AppSchemaV7); every DAO lookup, merge, removal, read
  flag, action, held row, attachment staging path and pop-out window uses the
  pair. A delta's `removed` ids delete only from the fetched folder. A push
  (and a notification-history tap, which replays one) names its message by id
  alone and always means INBOX, via `prepareForPushTap`. Readers built from a
  row (`EncryptedReadViewModel`, the invite card's attachment fetch, Forward's
  attachment collection) take the row's own folder, never an assumed one.
- **A folder with no cached row ignores its cursor** and fetches the whole
  window. A cursor describes rows this device holds; after the store is
  discarded or re-keyed, a delta would leave the folder empty until the daily
  resync. This is what keeps the local store disposable.
- **`isFullWindow` is derived from what we asked for, never from the wire's
  `delta` flag.** A relay predating the matching server fix labels a `since=0`
  response `delta: true` all the same, and only a full window can say what is
  *absent*.
- **Only a full window may prune, and only window rows.** A partial delta
  describes what changed; everything it omits is still legitimately in the
  mailbox. Pruning against one deletes the folder.
- **Mail older than the window is kept** (KyPost-Server `before=` paging and
  `agedOut`/`hasMore`/`nextBefore`; Android #183). `EmailEntity.inWindow` is
  false for rows paged in by "Load older mail" (`MailRepository.loadOlder`) or
  reported `agedOut`, and no snapshot prunes them; `removed` still deletes any
  row. A full window first takes absent rows dated before its oldest row out
  of the window (they aged out unreported) and prunes only absent rows inside
  its range. A page is metadata only: a held row takes just its read state and
  labels, a new one is stored bodiless and out of the window.
- **Every `/api/inbox` request uses `MailRepository.windowLimit` (50).** The
  relay keeps a window and cursor per `limit`; a cursor sent with another limit
  is one that window never issued.
- **A delta with `hasMore` is walked before its cursor is committed** (deltas
  only, never a full window): `before=nextBefore` pages until one holds an id
  the folder already had, then window and pages are written in one
  `EmailDAO.reconcile` save (rolled back on error), then the cursor. A failed
  or contradictory walk — no usable `nextBefore`, a page without `hasMore` —
  throws, stores nothing (not even the window: a stored row would count as
  held and the retry would stop at it) and keeps the old cursor. ponytail: the
  walk stops after `maxOverflowPages` (20) and commits.
- **A `before=` answer without `hasMore` is a server that ignored it** (its
  newest window, not older mail): stored nothing, "This server can't load older
  mail…", and the footer hides for that folder. A 400 there is a stale anchor:
  the next press starts again from the oldest row held.
- **A row without a body fetches one on open** (`GET /api/mail/body`,
  `MailRepository.loadBody`): blank body and not `pgpEncrypted` — a blank
  encrypted row is the client-protected shape and keeps its decrypt path. The
  fetched body is cached only on a window row; a page carries no PGP flags, so
  an out-of-window row fetches again on every open. 404 and 413 are their own
  sentences, never "couldn't reach the server".
- **Leaving an account erases its mail** (`MailRepository.forgetAccount`):
  every row in or out of the window, cached bodies, and every cursor. It is one
  step of `AccountTeardown` — out-of-window rows are never pruned, so nothing
  else would remove them.
  `EmailDAO.accountEpoch` is captured before a refresh, page or body fetch goes
  to the network and checked by its write; one that started under a forgotten
  account stores nothing, cursor included. The pairing being left is refused
  from then on (`SecurePairingStore.retireCurrentPairing`, see
  `KyPost/App/AGENTS.md`).
- Known gaps, all needing server help: out-of-window rows never learn of a
  deletion (opening one says it is gone) and are not healed after a
  UIDVALIDITY reset; encrypted mail stored from a page has no PGP flags, so it
  opens through `/api/mail/body` with no decrypt path.
- **An "updated" row carries no body.** Merge into the existing row and keep
  the cached body; a blank incoming `bodyMode` never overwrites a known one. If
  there is no existing row, **skip it** — storing it creates a row whose empty
  body is indistinguishable from a client-protected message, and the reader
  then claims end-to-end encryption for mail the server decrypted. A
  metadata-only delta is not a delivery.
- **Advance the cursor only after the rows are committed.** A crash between
  the two costs a refetch; the other order loses messages permanently.
- Cursors are opaque server strings — never assume numeric or ordered. Scoped
  per pairing *and* folder, with the resync stamp on its **own** scope key:
  sharing one lets writing the stamp re-authorise a stale cursor for a new
  pairing.
- Folder names are unvalidated server strings, so cursor keys hash them. That
  stops a crafted name colliding with another folder's key, and keeps the
  user's folder taxonomy out of a plaintext defaults file. Under Hostile
  Location Protection the store is memory-only for the same reason.
- **`wokenAt` pins a woken snoozed message to the top.** List order is
  `EmailEntity.sortDate` (`wokenAt ?? receivedAt`), stored because a
  `SortDescriptor` cannot coalesce; every write of either date rewrites it.
  The displayed date stays `receivedAt`. An "updated" row without `wokenAt`
  means the pin was removed, so the merge writes nil through.
- **A push tap forces a full resync before opening its target.** The cached row
  is fine for the list; rendering the detail screen from it can show a stale
  `bodyMode` or stale PGP state.

### Inbox search (`MailRepository.search`, `InboxViewModel`, Android #171)

- **The server searches; the cache is never consulted or written.**
  `GET /api/mail/search?q=<trimmed>&mailbox=<folder on screen>&limit=50`
  through the pinned relay session with pairing headers, every field (`field`
  is not sent; the server defaults it to `all`). Results are a view of the
  folder, not its window: written to the cache they could prune it or be
  mistaken for it. A 200 that is not `{"results": […]}` is "Malformed search
  response"; 400/503 use the ordinary mapping.
- **Each result is stamped with the searched folder**; actions, held rows,
  read flags and opening use (folder, id). An uncached result fetches its body
  on open (`MailRepository.loadBody`, which reuses a cached row's body for the
  same pair **together with that row's OpenPGP state** — a result carries
  none, and dropping it hides a cached verdict or turns a client-protected row
  into a server fetch), and Reply All uses the result's own `sentTo`/`cc` —
  the body endpoint carries none. `InboxViewModel.email(for:)` (macOS pop-out
  readers) prefers the folder row but takes the result's To/Cc.
- **Results land only while their submission is the newest and their query
  and folder are still on screen.** A failure says why and shows the folder
  list — never an older query's results. The search ends on clearing or
  cancelling the field, editing it away from the submitted query, a folder
  switch, a notification tap, and `forgetAccount` (wipe, rebuild, unpair).
- **The query is never logged or persisted** — scene memory (view `@State` on
  macOS, `MailShellState` on iOS so a layout switch keeps it) and view-model
  memory only; no `@SceneStorage`, no state restoration, no defaults.
- Known gap: results carry no PGP flags (the server sends none), so encrypted
  mail found only by search and not cached opens through `/api/mail/body` with no decrypt
  path, like older mail.

### Relay error mapping (`Data/Mail/MailSource.swift`)

- `NetworkError.from` sees a status code and a body, never headers. Anything
  header-derived — currently `Retry-After` — is parsed at the call site holding
  the `HTTPURLResponse` and passed in. Android hit the same wall and resolved
  it the same way; do not try to read headers inside the mapper.
- A `Retry-After` that is not delta-seconds reads as **absent, never zero**.
  "Retry immediately" is the one answer a malformed header must not produce.
- 400 carries its body as `.badRequest(body:)`, because the relay answers
  plain text there and the body is the only discriminator — unlike the two
  409s, which are told apart by JSON field. Deciding what that text *means*
  belongs in `RelayMailSource`, not `HTTPClient`.
- An unconfigured account (400 "imap configuration is required…") is its own
  outcome. Never build UI for the server's web-only mail configuration
  endpoints: an unconfigured relay is an empty state pointing at the web app,
  not a form.
- 502 is `.upstreamFailure` and retryable with backoff; other 5xx are not.
  Telling the user to retry is only honest for the one that is.

### KyIdentity sign-on via KyAuth, iOS only (`Domain/SignOn`, `Data/Networking/KyIdentitySignOnClient.swift`, `KyIdentitySignOnCoordinator`)

Binding contract: KyAuth-iOS `docs/specs/2026-10-11-ios-signon-handoff.md`.
Port of KyPost Android's `signon/`; status mapping and texts mirror it.

- **A URL carries only a nonce.** Request and response travel through the App
  Group `group.org.kysecurity.signon`, in the iOS entitlements only; team
  TATYN4X57D is the trust boundary. KyPost writes
  `SignOn/requests/<nonce>.json` (atomic, `.completeFileProtection`), reads
  and deletes `SignOn/responses/<nonce>.json`, and sweeps stale files (over 5
  minutes) only in `responses/`. `requests/` is KyAuth's to sweep.
- `origin` is exactly `RelayOrigin.origin` (`https://host[:port]`, lowercase
  punycode host, 443 dropped). KyAuth refuses anything not already canonical.
- The pending nonce lives in memory only, is accepted only from
  `kypost://kyidentity-signon?nonce=…` or on becoming active, and is abandoned
  after 180 s. The ID token is never logged or stored; it is a local for the
  one relay call.
- The response is not read, and the token not exchanged, while the app is
  locked, before the startup wipe verdict settles, or behind an abandoned
  wipe; a wipe, failed-unlock reset or unpair discards the whole sign-on.
  Details in `KyPost/App/AGENTS.md`.
- The relay's link goes through `PairingLinkParser`, must name the relay's own
  host, and then takes the ordinary confirmation step. Sign-on never pairs
  directly, so registration, pinning and secret storage stay single-path.
- macOS has no sign-on: no App Group, no entry, no return handling.

### Inbox list actions (`MailRepository.applyAction`, `InboxViewModel`, `Domain/Models/InboxRules.swift`)

- **HTTP 200 from `/api/inbox/actions` is not success.** The relay answers
  `{ok, action, processed, failed: [{messageId, error}], targetMailbox}` and
  its loop stops early on a cancelled request, leaving ids in neither list.
  `applyAction` is the only gate on dropping a cached row: an id is confirmed
  only when it is absent from `failed[]` **and** `processed` equals the number
  of such ids; a shortfall confirms nothing. A bare `{"ok":true}` reads as zero
  processed. Ids are trimmed and de-duplicated first (the relay counts them
  that way), and more than `maxActionIds` (500, server `maxInboxActionIDs`)
  is refused without a request. Partial failure reads "1 of 3 not changed: …".
- **List actions (archive/delete/junk/move, single or bulk, drag-to-folder)
  are held for a 5 s Undo; nothing reaches the relay until the window
  closes.** One bar covers every held action; a new action restarts the window
  without sending. Each held action leaves `PendingMailActions` exactly once —
  `takeAll` (sent) or `undoAll` (never). Held and in-flight rows are hidden by
  (folder, id), never id alone, so a refresh cannot bring them back and a
  same-id row in another folder stays visible. The source folder is pinned at
  tap time.
- **Commit points:** the timer, leaving the list, iOS backgrounding (under a
  background-task assertion), and app lock. Leaving is switching tabs on iOS
  or, in the iOS stack layout only, opening a message over the list; on macOS
  switching to Contacts or closing the window. In the iOS split layout the
  list stays beside the reader, so opening a message commits nothing and held
  actions run out their 5 s timer. **A layout switch (rotation, multitasking
  resize, fold) is never leaving**, even when it leaves the reader covering
  the list: held actions stay undoable and on their timer
  (`InboxListPresence.departure` → `leaveInbox(commitsHeldActions: false)`).
  The iOS shell (`MainTabView`) decides this, not the list view's
  `onDisappear`, which fires on every switch.
  The lock sites call `commitHeldActions()` **before** `lockAfterGrace()`,
  grace period or not: the commit binds the relay source synchronously, and
  `lock()` drops the gated device secret.
- **Drop points, never send:** security wipe (`inMemoryPlaintext` step), graph
  rebuild (`SingletonGraph.shutdown`, whose session is about to be cancelled),
  unpair. "Never" is the safe direction — the mail stays where it was. A
  process killed inside the window likewise loses the action.
- **Reader actions (archive/move/junk/delete in `EmailDetailView`) are not
  undoable**: they run at once through `performNow`, and the reader closes only
  when the relay confirmed that id; a rejection keeps it open with the reason.
- **Sent and Drafts are resolved, never hardcoded or created.** Each pick lists
  the top-level folders and opens the first whose leaf matches the server's
  alias list (`special_folders.go`: Sent, Sent Items, Sent Messages, Sent Mail /
  Drafts, Draft), case-insensitively, in that preference order. Paths under
  Archive are Archive's. No match is a notice, and the folder on screen stays.
  The relay exposes no special-use flag, so a localized name (`Gesendet`) reads
  as missing.
- **Move targets** are INBOX, Inbox children, top-level folders, then Archive
  children (best effort), de-duplicated case-insensitively, minus the message's
  own folder; `Archive` itself is never a target (the Archive action resolves
  the real archive server-side), so a drag onto the Archive sidebar row goes
  through `InboxViewModel.drop`, which runs Archive, not a move. Labels are raw paths, so two same-leaf folders
  stay distinguishable. Inbox children are an Apple-only addition: this client
  shows them in its sidebar.

### MFA number matching (`Domain/Models/MfaNumberMatch.swift`)

- **Every value comes from the server.** Never invent decoys. This client used
  to fill a short set from an LCG seeded on the challenge id, which made the
  wrong answers derivable by anyone holding the id and therefore the right one
  derivable by elimination — the entire guarantee of number matching, given
  away. A challenge that does not carry the correct value and exactly
  `choiceCount - 1` decoys of the same width is one this client cannot offer an
  approval for: `options` returns nil and the screen leaves only Deny. There is
  no plain-Approve fallback, and adding one re-opens the MFA-fatigue tap that
  number matching exists to close.
- **Digit width is whatever the server sent**, validated against
  `MfaChallenge.matchDigitsLengthRange`, never an exact literal. The width was
  pinned to 2 in three places across two repositories with no negotiation, so
  widening the server's value space would have silently disabled approval on
  every deployed client.
- **Order is shuffled once per challenge and held.** Do not re-derive it on a
  redraw, and do not sort by a hash of `(challengeId, value)`: that hash
  expands to `H(challengeId) * 31^n + f(value)`, and with equal-width
  candidates the challenge-id term cancels out of every comparison, leaving a
  plain numeric sort that put the answer in the same slot on every challenge.

### Calendar invites and RSVP (`Domain/Calendar/`)

Port of kypost-android #172/#176 against KyPost-Server #353/#354. KyPost writes
an event only when asked and syncs no calendar.

- **The parser refuses rather than repairs** (`parseCalendarInvite`): over
  256 KiB or 50 VEVENTs, any structural error, any unparseable event, or no
  series master (override-only) is no card at all. Only a VEVENT's own
  properties count (a VALARM's DESCRIPTION does not). Lines are unfolded **as
  bytes** before UTF-8 decoding; dates are strict (no rollover); controls and
  `\p{Cf}` are stripped from text (ZWJ kept) and make an address unusable.
- **TZID lookup chain:** as given, last three then two path segments, then
  CLDR's Windows-name table (`WindowsTimeZones`, regenerate from CLDR — ICU's
  lookup is not public API). Over 128 characters or unresolved reads as
  floating, and the card says so. A time with neither `Z` nor TZID is
  floating too and gets its own notice; an all-day date does not.
- **The organizer is its bare `mailto:` address, never CN**, and the card says
  when it is not the From address. Notices: phishing, organizer ≠ sender,
  CANCEL, update (REQUEST with SEQUENCE > 0), unknown zone, floating time.
- **Add to Calendar is a tap only**, never for CANCEL or REPLY. EventKit
  write-only access is requested on that tap and nowhere else
  (`INFOPLIST_KEY_NSCalendarsWriteOnlyAccessUsageDescription`, macOS
  `personal-information.calendars` entitlement). Under Hostile Location
  Protection every handoff is confirmed first. An RRULE EventKit cannot express
  adds the first occurrence and says so — including a weekly `INTERVAL > 1`
  or `BYSETPOS` rule whose days a different week start would regroup, since
  EventKit takes no WKST. The event carries DTSTART's zone (`CalendarEvent.timeZone`), so a
  series repeats at the organizer's wall clock; floating and all-day stay
  zoneless.
- **A handoff is bound to the session it was tapped in** (`PendingHandoff`,
  `RsvpTracker.session`). `CalendarHandoff.add` rechecks it after the
  permission prompt and before saving: nothing from an ended session reaches
  the calendar store.
- **The card's prompts never outlive the lock or the session.** Its alerts sit
  above `LockedOverlay` on macOS, so `InviteCardModel` presents a prompt only
  while unlocked and in its session (`presentedRsvp` / `presentedHandoff`),
  the lock withdraws both (`lockEngaged`, releasing the RSVP revision), and
  requesting, confirming and saving all refuse while locked.
- **RSVP (REPLY)** copies UID verbatim and SEQUENCE, restates RECURRENCE-ID
  without TZID (a zoned one becomes UTC; unrestatable means no RSVP), adds
  DTSTAMP, folds at 75 octets without splitting UTF-8. ATTENDEE is the
  `suggestedUserIDs` address the invite lists, else the primary, fetched fresh
  per RSVP; an alias is also sent as `from`. Buttons need the relay's
  `calendarMethod`.
- **Always unencrypted and unsigned** (`RelaySendRequest(calendarReply:)` has
  no PGP flag), and every RSVP is confirmed in a prompt that says so.
- **Only a 200 with `"calendarReply": true` is an RSVP.** Without it the
  organizer got plain mail: say so, never retry. Only a definite refusal
  (`rsvpRefusedBeforeSending`) re-arms the buttons on the open screen;
  anything else is "may have been sent". As on Android, a fresh open of the
  invite is the user's deliberate retry of an unsure send: it re-arms the
  buttons but keeps the warning shown, and the retry is still confirmed.
- **`RsvpTracker` owns state** per UID + RECURRENCE-ID + SEQUENCE, outliving the
  screen. It advances its `session` and drops everything on
  `.kyPostSessionReset`; a send confirmed in an ended session does no I/O, and
  `MailRepository.sendCalendarReply` refuses a replaced pairing from the same
  read that authenticates the request.

### Contact groups

- `GET /api/groups` is **pull-only and cursorless**. Every pull is the whole
  truth, so a group absent from the response is deleted locally. This device
  never creates a backend group (Client_Contact_Update.md Part 2 point 3), so
  there is no outbox and nothing to reconcile.
- `CNGroup` materialization is **one direction: backend → device**. A group the
  user made in Contacts is never turned into a backend group — there is no
  endpoint for it.
- Same adoption discipline as cards: an existing link wins, then a group the
  user already has *by name* is adopted rather than duplicated, then a new one
  is created. **An adopted group is never renamed and never deleted** — we did
  not author it.
- Membership removals are scoped to groups this app links. A card the user also
  put in their own group stays in it.
- An unknown group id resolves to no name and is skipped, never rendered as a
  raw UUID and never given an invented name — it only means the cache is
  behind.

### Contact identity (`Data/Contacts/`)

- `SystemContactMapper.matchKeys(for:)` has two overloads — one for `Contact`,
  one for `CNContact` — and **they must stay symmetric**. Each side offers one
  key per email, else the name+phone fallback. When the app side offered only
  `emails.first`, a person whose card carried only their *second* address
  matched on neither side: the export wrote a duplicate card, and the import
  read the original card as a stranger and wrote a duplicate contact — queued
  for the relay, so the duplicate reached the server and every other device.
  A new field that participates in identity goes into both overloads or
  neither.
- `ContactDAO.repairImportedDuplicates` groups by connected components over
  shared keys, not by one key per row. Grouping on a single key cannot see the
  duplicates above, because a non-primary-email match is exactly the case where
  the two rows' primary keys differ.
- `Contact.primaryEmail` / `primaryPhone` are `emails.first` / `phones.first`.
  Anything that treats email order as meaningful is suspect; prefer the
  `matchKeys` set.

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

## Child DOX Index

- `KyPost/App/AGENTS.md` — the dependency graph and its rebuild rule
  (`AppEnvironment` / `SingletonGraph.shared` aliasing), lifecycle/lock
  ordering at launch, the pull poll as push-mode heartbeat.
- `KyPost/Presentation/AGENTS.md` — SwiftUI views, view models, and
  components: theming and font contracts, MainActor isolation rules, compose
  recipient tokens and contact search, and the macOS/iOS input deviations.

## Product icon

App/launcher assets use the Busnes.app-site Systems stamp family. Regenerate platform sizes from the matching master in `../Busnes.app-site`; preserve resource names and adaptive foreground safe margins. This asset update does not change native theme defaults.
