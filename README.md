# KyPost

A native SwiftUI mail client for macOS and iOS. It connects to a KyPost mail relay.

The app talks only to the relay backend. There is no direct IMAP or SMTP. You pair a device one time with a QR code or a deep link. The relay then handles mail access, server-side keyword tabs, push notifications, and contact sync.

> **Naming:** the app uses the name **KyPost** everywhere. This covers the Dock and Home Screen label, the About screen, the permission prompts, the Xcode project, scheme and folders, and the deep-link scheme (`kypost://`). The bundle ID and the Keychain access group are `org.kysecurity.mail`, matching the Android client. They were `com.urlxl.mail` until the identifier rename, which had to land before the first App Store submission because a bundle ID cannot be changed afterwards. See `Brand_Refresh_KyPost.md`.

## Features

- **Inbox with keyword tabs** — the relay sorts mail into tabs and labels. You set the tab visibility in the settings.
- **Server folders** — Inbox and its subfolders, Drafts, Junk, Sent, Trash, and Archive with subfolders. On macOS these folders are in the sidebar. On iOS they are in the folder menu on the Inbox screen.
- **HTML email rendering** — a themed WebKit reader on both platforms. Links open in the default browser. The app renders plain-text messages natively.
- **macOS features** — a three-pane split view, pop-out email windows (double-click or right-click a message; each keeps its message when the main window changes folder, and a restored one reopens it from the cache), a preview pane you can turn on and off, drag-and-drop of emails onto sidebar folders to move them, and a native Preferences window (⌘,). Apple Mail's shortcuts, in the Message menu: Reply ⌘R, Reply All ⇧⌘R, Forward ⇧⌘F, Archive ⌃⌘A, Move to Junk ⇧⌘J, Mark as Read ⇧⌘U, and ⌫ to delete in the list or a pop-out reader. They act on the selection or the open message and are off while nothing is selected, the app is locked, or it is not paired. There is no Mark as Unread: the relay has no unread action. Elsewhere: ⌘N new email, ⇧⌘N refresh, ⇧⌘S contact sync. A failed attachment download, Save As or mark-as-read is said in a toast.
- **Compose and send** through the relay. A send that times out or gets a server error may still have gone out, so the app does not offer Send again until you have checked Sent and chosen to retry; the retry carries the same `Idempotency-Key`. On macOS, quitting asks before it discards a message you have not sent, and sends archive, move and delete actions still in their Undo window first.
- **Push notifications** (APNs) for new mail and MFA challenges. A polling fallback also runs (90 s in the foreground, background refresh on iOS).
- **MFA approval** — approve login challenges from a notification tap.
- **Contact sync** — two-way sync with the relay. Local edits win first, and the reconciliation keeps the data safe from conflicts. Changes not yet synced survive a server history reset, and a sync never deletes more than half of the cards it manages in Apple Contacts in one pass. Contacts carry the full extended schema: groups, photo, IM and social handles, websites, relations, extra dates, phonetic names, department, custom fields, pronouns, and a PGP public key.
- **PGP key exchange with QR** — share your public key in person. *My QR Code* makes a pickup link that expires in 2 minutes. The code carries the fingerprint of the key on your device. *Scan to add contact key* reads the link of another person, checks the key against that fingerprint, and saves it to a contact. A code without one (the other device holds no key) saves the key as not verified in person. iOS scans with the camera and accepts a pasted link as a fallback. macOS accepts only a pasted link, because it has no VisionKit scanner.
- **Encryption state on every message** — a message that the server decrypted says so, and you can then see that the server read your mail. A message only your own key can open says that too; on a device you enrolled it decrypts here. The decrypted body is never stored; it lives only while the message is on screen. Previewing a decrypted attachment writes it to a temporary file, deleted when the preview closes, when the message closes, and by the security wipe; saving one writes it where you choose. For a server-custody account the app holds no private key at all. For a client-custody account it holds one only after you deliberately run device enrollment. It is stored encrypted to a Secure Enclave key that only opens after Face ID, Touch ID or the device passcode — at most once per app unlock: unlocking the app with Face ID, Touch ID or the passcode covers it, otherwise the first decrypt asks, and locking the app (or backgrounding it on iOS, or locking the Mac's screen) means the next decrypt asks again. A key stored in the clear by an earlier version is re-sealed the first time it is opened after updating. Enabling Hostile Location Protection, the security wipe, or resetting a stranded app lock destroys it, and none of them brings it back. See `docs/E2E_PGP.md` in the server repo.
- **Signature states decided on this device** — "You confirmed this key" only for a key you pinned here by QR; "Same key as last time" and "Key has changed" from this device's own history of the first key it saw sign for each sender; "Signer not confirmed on this device" for a key only the relay vouches for. The relay cannot mark a key verified, and its key-change report can only add a warning. A mismatch between the message's From and the addresses the signing key names is flagged.
- **Encrypted and signed send** — for an account whose key the server holds, the Encrypt and Sign flags travel with the message, and the relay does the OpenPGP work. If a recipient has no usable key, the relay refuses first and asks you. If you confirm, the relay mails a one-time link to the recipient. It also stores the plaintext of that message on your server for up to 7 days, together with the named recipients. For an account whose key the server does not hold, a device you enrolled encrypts and signs on the device itself (PGP/MIME, each Bcc recipient gets a separate ciphertext, and the Sent copy is encrypted to your own key). On a device that is not enrolled, the app saves the draft on the server and webmail takes over.
- **17 themes** — the palettes match the web and Android apps, except where a color did not reach WCAG AA contrast (4.5:1) and was changed here: Patina Ky's text, the error/success/warning text on light themes, secondary text, the reader's link color on pale-accent themes, and the button text on Coffee and Polished Ky. `KyPost/Presentation/AGENTS.md` lists each one. The default theme is **Busnes Light**; a theme you already chose is kept.
- **Tip Jar** — an optional one-off tip through In-App Purchase, in About (iOS: Settings → About & Tip Jar; macOS: KyPost → About KyPost). It unlocks nothing. About also lists the open-source software KyPost includes, with each licence, under **Acknowledgements**.

### Security (Settings → Security)

- **Require Unlock to Open** — gates the app behind Face ID, Touch ID, or
  the device passcode (`LAContext`). iOS locks the app when you send it to the
  background. macOS locks the app when the screen locks, and not when you
  switch apps. A delay — Immediately (the default), 30 seconds, 1 minute or
  5 minutes — can be set; lengthening it asks you to authenticate.
- **App PIN** — optional, 8 to 12 digits, separate from your device passcode.
  This reverses an earlier decision. The README used to say the OS owned
  rate-limiting and lockout and there was no app-specific PIN; that was true
  only while `LAContext` was the sole verifier, because the OS throttles
  guesses at the passcode, not at anything of ours. A PIN checked inside the
  app has no such backstop, so KyPost owns the throttle:
  - the first two wrong attempts are free,
  - the third onward adds a growing wait — 30s, 60s, 5m, 15m, 30m; a
    restart begins the current wait again rather than skipping it,
  - **ten wrong attempts in a row erase** the pairing and everything KyPost
    has stored on this device. Your mail stays on your server. The number can
    be set to 10, 20 or 30, or Never; allowing more attempts asks you to
    authenticate, and a stored value that does not verify counts as 10.
    A correct PIN, or unlocking with Touch ID or your password, starts the
    count over.

  If the key protecting the PIN verifier becomes unavailable, KyPost says so
  and counts nothing — a PIN it cannot check is not a wrong PIN, and it must
  not spend your attempts. A wipe that cannot finish says which parts it
  could not remove, keeps the app locked, retries at the next launch, and
  after three failed attempts (the first run and two retries) blocks the app
  behind a "reinstall to clear this" screen rather than presenting a clean
  first-run app over data that is still here. "Reset KyPost on This Device"
  on the lock screen is the same wipe.
- **Hostile Location Protection** — keeps no mail, contacts, or attachments
  on the device. All data stays in memory and reloads from your server,
  including sync positions, keyword settings, and the keys you verified. The
  app erases the local cache when you turn this option on. There are three
  honest limits. An attachment preview writes a file into the sandboxed
  temporary directory of the app while the preview is open, because Quick
  Look needs a file, and the app deletes the file on dismissal. The erase of
  the store is a plain delete, not a forensic overwrite. And cards already
  exported to Contacts stay there, and KyPost forgets which ones it made, so
  use Remove Exported Contacts before you turn this option on.
- **Require unlock for notifications and MFA** — moves the relay credential
  behind user presence. Background mail checks and MFA approvals then wait
  until you open and unlock the app. On an iPhone this covers all background
  delivery. On a Mac it applies while the screen is locked.
- **Always on**: certificate pinning. Pairing pins the relay's key on the
  pairing's own connection, before any credential is sent: the link's `pin=`
  when it has one, otherwise the key that first handshake presents. A pairing
  that cannot read the key fails. The app never re-pins silently afterward,
  and a link cannot replace a stored pin. The pin is bound to its host and
  fails closed: a key the app cannot hash, or a pin it cannot read from the
  Keychain, refuses the connection. If the certificate changes, remove the
  pairing in Settings → Connection and pair again. Relay responses are never
  cached on disk. The app also applies these protections. Sender HTML
  renders with JavaScript off and remote content blocked: subresource loading
  is off and a WebKit content rule list refuses every load the message makes
  except the app's own inline images, so preconnect, prefetch, `<a ping>`,
  CSS fonts and imports, `srcset` and posters fetch nothing. A test renders
  every one of these against a local server and counts zero requests. "Load
  Remote Content" lifts the block for that message only. Navigation out of
  the message is denied by default, so a redirect cannot beacon home past the
  block. The app computes PGP fingerprints locally from the key bytes, so it
  refuses a relay that lies. The local store carries a backup exclusion.
  Screen-capture protection is on: macOS excludes the windows from recordings
  and screen sharing, and iOS covers the content while a recording or a mirror
  is active. Neither platform can block a plain system screenshot.

## Requirements

- Xcode 26 (deployment target macOS and iOS 26.0; iPhone, iPad and Mac)
- A running llama-labels backend (the live deployment is behind Cloudflare at `mail.urlxl.com`)
- For push: an APNs key configured on the backend

The app uses SwiftData for persistence, URLSession for networking, and WebKit for rendering.

Its one external dependency is **GopenPGP** — the same OpenPGP implementation Proton uses — consumed as a binary XCFramework through the local package in `Dependencies/GopenPGP`. That binary is built from source by `.github/workflows/gopenpgp-xcframework.yml`, from the upstream tag pinned in `Dependencies/gopenpgp.env`, using upstream's own `build.sh`; `Package.swift` pins its SHA-256, so the bytes cannot change without that line changing. Nothing outside `KyPost/Domain/Security/PgpCrypto.swift` and its conforming types may reference the library.

## Getting started

1. Open `KyPost.xcodeproj` in Xcode.
2. Select the *KyPost* scheme and your destination (My Mac, or an iOS device or simulator).
3. Build and run.
4. Pair the device. In the web frontend, open **Settings → Security → Devices** and choose **Pair a new device**. On a Mac, click **Pair this device**: the browser opens a `kypost://native-pair?...` link in KyPost, which asks you to confirm the server. If nothing opens, the page shows the link; paste it in Settings → Connection → **Paste Pairing Link…**. On iOS, scan the QR code. Pairing registers the device and stores its credentials and the server's certificate pin in the Keychain.

Until you pair, the inbox says how: on a Mac it gives the web steps above, and on iOS it points to Settings → Connection.

## Architecture

The target builds for both platforms from one codebase in `KyPost/`:

| Layer | Contents |
| --- | --- |
| `App/` | Entry point, scenes, app delegate, DI graph (`SingletonGraph`), polling scheduler, notification dispatcher |
| `Data/` | Relay clients (`RelayMailSource`, sync, push and registration clients), SwiftData DAOs and entities, Keychain and settings stores |
| `Domain/` | Models, repositories (mail, keywords, contacts, push), use cases (send, pairing, MFA) |
| `Presentation/` | Shared SwiftUI screens and view models, macOS-specific root and preferences views, style-guide components |
| `Style/` | Theme palettes and manager (binding contract with web `theme.ts` and Android `AppTheme.kt`) |

The platforms split at the root view. iOS uses a tab layout (`MainTabView`). macOS uses `NavigationSplitView` (`MacRootView`) plus a per-email `WindowGroup` for the pop-out readers.

### Wire contracts

The Android reference repo (`llama-mobile`) defines the relay endpoints and the payload shapes. The primary documents are `Mobile_Mail_Relay.md` and `Mobile_Contact_Sync.md`:

- `GET /api/inbox` — emails grouped by tab (`{tabs, byTab, cursor, delta, removed, agedOut, hasMore, nextBefore}`);
  with `before=<messageId>&bodies=0`, one page of older mail (`{byTab, hasMore, nextBefore}`)
- `GET /api/mail/body?mailbox=&messageId=` — one message's body, for a row that arrived without one
- `GET /api/mail/search?q=&mailbox=&limit=50` — server-side search of one folder, every field (`{results}`)
- `GET /api/inbox/folders?parent=` — folder listing (full paths, for example `INBOX/Receipts`)
- `POST /api/inbox/actions` — bulk read, archive, spam, delete and move
- `POST /api/mail/send` — comma-joined recipient strings
- `POST /api/mail/draft` — save a draft (the same body shape as send, without the PGP flags)
- `GET /api/pgp/bootstrap` — the key custody of this account (`hasIdentity`, `protection`)
- `POST /api/pgp/recipients/check` — contacts-only recipient key preflight (never `/resolve`)
- `GET/POST /api/contacts/sync` — cursor-based contact sync
- `GET /api/pgp/qr/token` — make a PGP key-pickup token and URL that expire in 2 minutes (pairing-auth `sub` and `hash`)
- `GET /api/pgp/qr/key?t=` — get a scanned public key and fingerprint (the token is the credential)
- `POST /api/notifications/native/register` — APNs device registration

Before you change any of these endpoints, read the Android implementation. Do not guess.

## Testing

The unit tests use Swift Testing (`@Test` and `#expect`) and live in `KyPost Tests/`. The UI test stubs are in `KyPost UITests/`. Run the tests in Xcode with ⌘U, or with this command:

```sh
xcodebuild test -project "KyPost.xcodeproj" -scheme "KyPost"
```

The network-facing tests run against a stubbed `HTTPClient`. They need no backend.

## Known gaps

- **Draft saving from compose.** The PGP webmail handoff saves a draft on the
  server, but there is no Save Draft button and no auto-save.
- **QR scanning with the camera on macOS.** Paste the pairing links and PGP key
  links instead. Camera scanning works on iOS.
- **The on-device encrypted send and read paths have not been exercised against a
  live relay.** They are covered by unit tests against fakes, so the wire
  contracts for `/api/pgp/recipients/resolve`, `/api/mail/send-pgp` and
  `/api/mail/pgp-payload` are unverified in practice.
- **The release workflow has not run end to end.** `release.yml` signs
  automatically with an App Store Connect API key and uploads both platforms,
  but no tag has exercised it yet. Its one-time setup (the `release`
  environment and five secrets) is listed at the top of the workflow.
- **No visionOS build.** The app targets iPhone, iPad and Mac only.

## License

MIT, developed by Busnes.app — see [LICENSE.txt](LICENSE.txt).
