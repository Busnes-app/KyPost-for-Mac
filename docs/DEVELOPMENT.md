# Development

[Product overview](../README.md)

Commands and unlinked file paths below are relative to the repository root.

> **Naming:** the app uses the name **KyPost** everywhere. This covers the Dock and Home Screen label, the About screen, the permission prompts, the Xcode project, scheme and folders, and the deep-link scheme (`kypost://`). The bundle ID and the Keychain access group are `org.kysecurity.mail`, matching the Android client. They were `com.urlxl.mail` until the identifier rename, which had to land before the first App Store submission because a bundle ID cannot be changed afterwards. See `Brand_Refresh_KyPost.md`.

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

[KyPost Server](https://github.com/Busnes-app/KyPost-Server/tree/main/docs) owns the relay wire contracts, including `DEVICE_ENROLLMENT.md`, `E2E_PGP.md` and the mobile mail/contact documents. The Android client is a sibling implementation, not a replacement for those server contracts:

- `GET /api/inbox` — emails grouped by tab (`{tabs, byTab, cursor, delta, removed, agedOut, hasMore, nextBefore}`);
  with `before=<messageId>&bodies=0`, one page of older mail (`{byTab, hasMore, nextBefore}`)
- `GET /api/mail/body?mailbox=&messageId=` — one message's body, for a row that arrived without one
- `GET /api/mail/search?q=&mailbox=&limit=50` — server-side search of one folder, every field (`{results}`)
- `GET /api/inbox/folders?parent=` — folder listing (full paths, for example `INBOX/Receipts`)
- `POST /api/inbox/actions` — bulk read, archive, spam, delete and move
- `POST /api/mail/send` — comma-joined recipient strings
- `POST /api/mail/draft` — save a draft: `{to, pgpDraft}` (encrypted on the device, client custody) or the send body without the PGP flags (plain, server custody or no PGP identity only); a 200 counts only with `{"ok": true}`
- `GET /api/pgp/bootstrap` — the key custody of this account (`hasIdentity`, `protection`)
- `POST /api/pgp/recipients/check` — contacts-only recipient key preflight (never `/resolve`)
- `GET/POST /api/contacts/sync` — cursor-based contact sync
- `GET /api/pgp/qr/token` — make a PGP key-pickup token and URL that expire in 2 minutes (per-device authentication headers; no account-wide `sub`/`hash` authentication)
- `GET /api/pgp/qr/key?t=` — get a scanned public key and fingerprint (the token is the credential)
- `POST /api/notifications/native/register` — APNs device registration

Before changing a wire shape, read the server contract and both native implementations. Registration exchanges the one-time pairing token for `deviceId` and `deviceSecret`; subsequent calls use `X-Kypost-Device-Id` and `X-Kypost-Device-Secret`.

## Testing

The unit tests use Swift Testing (`@Test` and `#expect`) and live in `KyPost Tests/`. The UI test stubs are in `KyPost UITests/`. Run the tests in Xcode with ⌘U, or with this command:

```sh
xcodebuild test -project "KyPost.xcodeproj" -scheme "KyPost" -destination 'platform=macOS'
# Run iOS-only code separately using an installed simulator destination:
xcodebuild test -project "KyPost.xcodeproj" -scheme "KyPost" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Many network unit tests use a stubbed `HTTPClient`; they do not qualify live relay interoperability. Keep the shared test plan serial as documented in `AGENTS.md`. Screenshot tests skip unless `KYPOST_SCREENSHOTS=1`; `scripts/capture-screenshots.sh` captures demo appearance, not functional acceptance. Live relay send/read, device enrollment, physical-device APNs, Keychain and App Store release checks remain separate gates.
