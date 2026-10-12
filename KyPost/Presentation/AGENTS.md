# Presentation DOX

## Purpose

SwiftUI views, view models, and reusable components for macOS and iOS from one
target. Screens compose Components; view models hold state and talk to
Domain.

## Ownership

- `Screens/` — full surfaces (compose, inbox, contacts, PGP)
- `Components/` — reusable views with no screen-specific knowledge
- `Shared/ViewModels/` — `@Observable @MainActor` state, injected from `SingletonGraph`
- `macOS/` — macOS-only shells (`MacRootView`)

## Local Contracts

- **`AppTheme.defaultThemeName` (`Busnes Light`) is the only fallback
  name.** A fresh install, a saved name no longer offered, and a missing
  palette all resolve through it; an explicit saved choice is always kept
  (`ThemeManager` discards only unknown names). Palettes match web
  `THEME_OPTIONS` and Android `AppTheme.kt` hex for hex and are opaque — the
  Busnes `line` is Android's composite of the web's translucent value.
- **Sheets do not inherit `\.theme`.** Every `.sheet` re-injects
  `.environment(\.theme, theme)`. A sheet that skips it renders unthemed.
- **Nothing presents while the app is locked — the router enforces it, not
  the cover.** `NavigationRouter.handle` defers the action when `isLocked()`
  and replays it from `resumeDeferredAction`; `lockAwareRouting(router)` on
  each scene root wires both directions and dismisses presented routes on
  lock. The lock cover cannot be the control: on macOS a window-modal sheet
  renders *above* `LockedOverlay`, and on iOS SwiftUI allows one presentation
  per view, so a sheet already on screen stops the `fullScreenCover`
  presenting at all. Either way MFA approval and pairing were reachable on a
  locked app. A new scene root gets `.lockAwareRouting(router)` alongside its
  `.id(generation)`, `LockedOverlay`, and `protectedFromCapture()`.
- **`PushPairingView` closes itself on iOS when the lock engages.** Settings
  presents it outside the router, so `dismissPresentedRoutes` cannot reach
  it, and "Sign in with KyIdentity" backgrounds the app on purpose. A sign-on
  that finishes while a pairing screen is on screen lands in that screen's
  confirmation step; otherwise it goes through `router.handle`, which defers it
  until unlock. A link the screen never took (it was dismissed first) goes to
  the router when the last pairing screen disappears, so it is never stranded.
- **Notification history renders nothing while locked or after an abandoned
  wipe.** `NotificationHistorySections` (iOS Settings → Notifications →
  Notification History; macOS Notifications tab) shows sender and subject
  lines, so it decides `NotificationHistoryAccess` itself rather than trusting
  the cover, for the same macOS sheet reason as the router — and because the
  macOS Settings scene sits outside the main window's `ManualRecoveryView`.
  After an abandoned wipe the view model does not even load the history. Rows
  for a synthesized `pull-<seq>` id mark read but open nothing.
- **The MFA approval screen has no plain Approve button.** When the payload
  carries no usable `matchDigits`, `MfaApprovalView` offers Deny and an
  explanation — never a generic Approve. Number matching exists because a
  contentless Approve is the tap an MFA-fatigue attack collects, so falling
  back to that button handed the downgrade to whoever shapes the push payload.
  `MfaApprovalViewModel.respond` refuses a numberless approval before any
  request, and the server refuses it too.
- **The lock screen leads with a PIN when one is set**, and auto-prompts
  `LAContext` only when one is not. A system authentication sheet raised over a
  PIN field asks for something the user did not ask for; a PIN exists only
  because they chose it. Removing a PIN is an *off* path and re-authenticates
  like the rest.
- **Every PIN outcome gets its own sentence, and `verifierUnavailable` is the
  one that matters.** It means the PIN was *not* wrong — telling the user it was
  invites them to burn attempts against a threshold that outcome deliberately
  does not advance. The two wipe outcomes say nothing on the lock screen: the
  wipe rebuilds the app underneath it, so the notice is carried in
  `AppEnvironment.wipeNotice` and rendered by the rebuilt window.
- **"Erased" and "partly erased" are different banners**, and "it will be
  retried" must never be shown by the run that stopped retrying. An abandoned
  wipe replaces the whole app with `ManualRecoveryView` rather than warning
  above it.
- **Every *off* path in Security settings re-authenticates first.** Turning a
  protection off is the destructive direction and the pane is reachable from
  the macOS menu bar. Authentication must precede the downgrade, not follow
  it: turning the credential gate off writes the device secret back into the
  plain Keychain item, and doing that before the prompt left it applied even
  when the user cancelled. The combined lock-off path authenticates once via
  `confirmWithDeviceAuth` and then uses
  `AppLockManager.disableLockAfterAuthentication`, so one prompt covers both
  changes.
- **The contacts list carries `ContactSyncBanner`** on both platforms
  (`safeAreaInset`), re-evaluated each minute because a change turns "stuck"
  by age alone. Retry is `ContactsViewModel.sync()`. vCard export goes through
  `VCardShareMenu` only — it owns the Hostile Location Protection refusal.
- **Loosening a Security picker re-authenticates; tightening does not.** A
  longer lock delay or a higher wipe threshold (or Never) goes through
  `confirmWithDeviceAuth` first, like the *off* paths.
- **The iOS background snapshot is covered by a window, not an overlay.**
  `PrivacySnapshotCover` (AppDelegate) puts an opaque `UIWindow` at
  `.alert + 1` over each scene entering the background whenever the lock is
  on, and removes it on return only after the grace deadline is resolved. An
  in-tree overlay sits below presented sheets, so an open reply would show.
- **Generated HTML uses a link-scheme allowlist.** `RichTextHTML` emits an
  `<a href>` only for `http`, `https`, `mailto`, `tel`. Escaping the attribute
  value stops it breaking out of the quotes and does nothing about
  `javascript:` or `data:text/html` — and this app is the *sender* of the mail
  it builds, so that would ship an active payload under the user's address.
- **Fonts carry meaning**: `AppFont.ui` for names and prose, `AppFont.mono`
  for email addresses and other machine text. A bare address rendered in mono
  is the signal a recipient isn't in the address book.
- **Only four font weights ship.** Space Grotesk and IBM Plex Mono are bundled
  from `Resources/Fonts` in regular, medium, semibold, and bold only. Any other
  `AppFont` weight silently resolves to the nearest bundled face — add the TTF
  and list it in `UIAppFonts` before using one. The bundle is flat, so
  `ATSApplicationFontsPath` is `.` and `UIAppFonts` carries bare filenames.
- **New pure value types must be declared `nonisolated`.** The target defaults
  to MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`), which infers
  isolated conformances; SwiftData casts codable composites off the main actor
  and an isolated conformance fails that cast at runtime, not compile time.
  See `Domain/Models/Contact.swift`.
- **Contacts are searched in memory, not in the store.** `Contact.emails` is an
  encoded blob `#Predicate` cannot see into, so both compose autocomplete and
  the address book run `ContactSearch` over `ContactsViewModel.searchIndex`,
  rebuilt in `load()`. Do not add a second contact cache.
- **Compose recipients are `[RecipientToken]`; `ComposeDraft` stays strings.**
  `ComposeDraft` is a `WindowGroup` scene value, so its `Codable` shape is a
  serialization contract — decode every key with `decodeIfPresent` or an
  archive from an older build throws and the window restores blank. Tokens are
  live editing state and are deliberately not `Codable`.
- **Closing a compose with content asks first** (Android #118):
  `ComposeViewModel.closingNeedsConfirmation` — any recipient, pending
  recipient text, subject, attachment or non-blank body, a signature-only body
  included — until the message was sent or handed off. Cancel asks; iOS
  refuses the swipe-down and `SheetDismissGuard` turns the refused attempt into
  the same prompt; macOS answers `windowShouldClose` through
  `WindowCloseGuard`. Both are proxies that forward every other delegate call
  to SwiftUI's. Closes the app forces (Hostile Location Protection, wipe) never
  ask.
- **A compose open when the lock engages stays, covered, and sends nothing.**
  The inbox owns the iOS compose sheets, so `dismissPresentedRoutes` cannot
  reach them and the root `fullScreenCover` cannot present over them:
  `ComposeView` overlays `UnlockView` on itself (navigation bar included) and
  blocks the swipe-down while locked. `ComposeViewModel` takes `isLocked` and
  refuses send, pickup re-send and webmail hand-off while it is true, on both
  platforms. The lock also closes compose's own sheets and dialogs, which
  would otherwise sit above the cover.
- **The signature is plain text placed by compose** (Android #177,
  `MailSignatureStore`, ≤1000 characters): after an RFC 3676 `-- ` line and
  above any quote on new messages, replies and forwards, never above a
  non-blank external body (`ComposeDraft.bodyIsExternal`, a `mailto:` body).
  Compose builds its `AttributedString` from plain text, so markup in a
  signature or a mailto body is shown, never interpreted. Account data:
  unpair, the failed-unlock reset and the wipe clear it; Hostile Location
  Protection does not.
- **`mailto:` links are compose prefills, nothing more** (Android #105,
  `MailtoLinkParser`): `to`/`cc`/`bcc`/`subject`/`body` only, split before
  decoding, header fields flattened to one line, the body capped. They route
  as `NavigationAction.composeMail`, so the lock defers them like any deep
  link; the shell takes the request (`takeComposeRequest`) and owns the
  window (macOS) or sheet (iOS) from then on. iOS shows one compose at a
  time, so a link arriving while one is open stays pending
  (`takeComposeRequest(composeIsOpen:)`, latest wins) and opens when it
  closes — never by swapping the open sheet's content. The message body's link policy
  still never hands a `mailto:` link to `openURL`.
- **Uncommitted recipient text lives on the view model**, not in view `@State`,
  so `send()` can flush it. Typing an address and pressing ⌘↩ must still mail
  it.
- **Floating overlays anchor from the top of the view tree.** Compose's
  dropdown uses `anchorPreference` + `.overlayPreferenceValue` at the content
  level. `.popover` steals key-window focus on macOS; `.overlay` on a field
  inside the header `Grid` draws under the AppKit-hosted `TextEditor`.
- **Rows in a focus-sensitive overlay must not be `Button`s.** A `Button`
  takes first responder, dropping the field's focus and tearing the overlay
  down before the action runs. Use `.contentShape` + `.onTapGesture`.
- **`.toast(message:)` is a pure renderer** — the caller owns dismissal.
  `ContactsViewModel.statusMessage` persists by design; compose expires its own
  toast on a timer. A toast bound to a window renders *behind* any sheet over
  it, so a sheet that raises toasts binds `.toast` itself.
- **`SecondaryButtonStyle` stretches to `maxWidth: .infinity`** (built for
  sheet footers). Constrain it with `.frame(width:)` inside an `HStack`.
- **Aligning columns across separate rows takes fixed widths**, not `Grid`:
  each `Grid` sizes its columns independently, so a header `Grid` drifts out
  of line with row `Grid`s. See `AddressBookView.Column`.
- PGP message state is decided in `Domain/Models/PgpMessageState.swift` and
  never re-derived in a view. `EmailListRow` marks only the two unreadable
  states (`lock.fill` / `exclamationmark.triangle.fill`); a server-decrypted
  row is deliberately unmarked. `EmailDetailView` shows the signature badge
  **only** for `.decryptedByServer` — for a client-protected message the
  server never saw the plaintext, so `pgpSigned`/`pgpVerified` are not a
  verdict about anything. A client-protected message automatically decrypts
  when its key is already held; otherwise it shows Decrypt, whose deliberate
  press prompts to unlock the key. Cancelling leaves Decrypt available. The
  reader has no webmail fallback. PGP explanation and controls disappear once
  plaintext is visible — the signature line, a dropped-attachment notice and
  the decrypted files then show beside the body instead — and the body has
  layout priority so it owns the remaining scrollable space without imposing
  an infinite-height content constraint on its macOS window. The reader navigation bar does not repeat
  the sender, and client-protected PGP/MIME transport parts are not presented
  as attachments. Its HTML uses the bundled IBM Plex Mono family, matching
  plain message bodies, and constrains text, tables, images, and preformatted
  blocks to the reader width. Decrypt uses `PrimaryButtonStyle`, whose accent
  fill and `readableOnAccent` foreground are contrast-tested for every theme.
- **The reader's To/Cc lines are flattened** (`displayHeaderText`): controls,
  format characters and line/paragraph separators become one space, so a
  display name cannot forge a labelled line or reverse an address with a bidi
  override. A field with nothing left is hidden. Decrypted attachment names
  are flattened the same way for display and through `safeAttachmentFileName`
  for any file written.
- **Forward carries the original's attachments through
  `ForwardAttachmentHandoff`, never `ComposeDraft`** (a scene value restoration
  archives). One slot keyed by draft id, claimed once from compose's `.task`,
  at most 12 MiB, refusing rather than evicting; what did not come along is
  said in compose. Dropped on `.kyPostSessionReset`,
  `.kyPostCloseComposeWindows` and by the wipe's in-memory step. Forward runs
  through `runForward`: it waits for the attachment listing (a failed listing
  is said in compose, not read as "no files"), and a forward still in flight
  when any of those boundaries passes stores nothing and opens no compose
  window (`ForwardAttachmentHandoff.begin`/`isCurrent`). The reader cancels it
  on disappear.
- **The invite card is only as reliable as the relay's listing** (root
  AGENTS.md, "Calendar invites and RSVP"). It loads after the attachment chips,
  never for a client-protected message, and derives its RSVP buttons from
  `RsvpTracker`. The RSVP alert's binding setter must not release the revision
  directly: SwiftUI clears it before the tapped button runs
  (`InviteCardModel.rsvpPromptDismissed`).
- **The whole email row is the open target.** `EmailListRow` expands to the
  list width and supplies a rectangular content shape, including whitespace.
  The decrypt action uses visible button chrome rather than link styling.
- **Keyword order is a device-local setting.** Both platforms use native List
  movement so the whole row is draggable and neighboring rows move live. They
  persist the complete order in `KeywordSettingsStore` and apply it to Inbox
  tabs. Newly observed keywords follow the saved names alphabetically.
  Returning from Settings recomputes tabs locally rather than fetching mail.
- **Initial inbox refresh failures get a 90-second grace period and one silent
  retry after 15 seconds.** Cached mail remains usable while a transient launch
  failure may recover. A persistent connectivity failure is separate toast
  state whose only copy is "Unable to connect to the mail server." Raw
  transport descriptions never reach the view; explicit refreshes show the
  same sanitized toast immediately, while pairing errors remain inline and
  never wait. Leaving Inbox cancels both pending timers and clears the toast.
  Returning calls `loadIfNeeded`, so tab switching never starts another cache
  read or network refresh; only the foreground cadence resumes.
- **The inbox list's signals are per folder on screen.** The freshness line
  under the tabs reads "Not updated yet" until that folder's first successful
  refresh, then "Updated … ago" (`FreshnessLine`, re-rendering on its own).
  "No messages in {folder}" shows only once that folder refreshed successfully
  (`showsEmptyFolderState`); a loading or failed folder with an empty cache
  shows a spinner or nothing, never "empty". A refresh that finishes after a
  folder switch is not painted, and refreshes are tracked per folder so a slow
  one for the folder just left cannot block the new one. Every pick bumps
  `selectionGeneration`; a Sent/Drafts listing that answers after a newer pick
  is dropped silently rather than selected.
- **Row dates** come from `InboxRules.rowDate`: time for today, medium date
  otherwise, device zone, blank for a missing `atUtc` (`Email.unknownDate`,
  which sorts last — never "now"). List roots apply `relabelsAtMidnight()`.
- **The All tab is hideable** (`KeywordSettingsStore.allTabVisible`, iOS
  Keyword Settings). A vanished selected tab falls back to All, or with All
  hidden to the first visible tab; with every tab hidden there is no strip and
  no filter. A relay label spelt "All" is not a second All tab. macOS ignores
  the setting (`appliesAllTabSetting`): its sidebar's Inbox row is the folder.
  `$`-keywords stay filtered.
- **Selection:** iOS uses edit mode ("Select") with a bottom action bar; macOS
  the list's own selection. Both cap at 500 rows (the 501st is refused with a
  notice), end the selection on any folder change, and send ids in on-screen
  order. Swipes and row context menus are off while selecting.
- **New mail:** a repaint of the same folder and tab that lands rows above the
  old top keeps them in sight when the list is at its top (`scrollToTopRequest`)
  and otherwise counts them on the "N new messages" pill, which scrolls up on
  tap and clears on reaching the top or switching tab/folder. A first paint or
  folder switch announces nothing.
- **"Load older mail" is the list's last row** (`LoadOlderFooter`, both
  shells): not selectable, no swipes, hidden while selecting on iOS. It shows
  under a non-empty folder until that folder has nothing older or its server
  cannot page; the per-folder paging state lives in `InboxViewModel` and is
  dropped by `forgetAccount()` (wipe, rebuild, unpair). A page that lands after
  a folder switch is not painted.
- **The reader fetches a missing body before rendering**
  (`EmailDetailView.loadBodyIfNeeded`): a spinner while it loads, the failure's
  own sentence and "Try again" if it fails — never an empty screen passing for
  a short message. Reply/Forward quote the fetched body.
- **A notification-tap target is consumed once**, at the start of the hunt:
  `router.pendingMessageId` is cleared before the resync, found or not.
  `prepareForPushTap` switches to Inbox and waits out an in-flight refresh so
  the forced full resync actually runs; if the wait (30 s) expires or the
  resync is skipped (`refresh` returns false), it reports failure and returns
  nil, never the cached row.
- `notice` is the inbox's transient toast (rejected actions, missing Sent
  folder, selection limit); it expires itself. `connectionNotice` keeps its
  own contract above.
- Encrypted send is decided by key custody, not by hope.
  `Domain/Models/PgpKeyCustody.swift` maps `/api/pgp/bootstrap` to
  `serverHeld` / `clientHeld` / `noIdentity`, and anything unrecognised
  degrades to `clientHeld`. Compose shows Encrypt/Sign **only** for
  `serverHeld`; `clientHeld` gets the webmail handoff (save a draft, then
  `openURL`, never an in-app WebView), and `.noIdentity` or a nil custody shows
  nothing at all.
- **The keyless-recipient confirmation copy is contract.** It lives in
  `ComposeViewModel.pickupConfirmationMessage`, verbatim from
  `Client_Encrypted_Send.md`, and must name every address, say the plaintext
  sits on the server for up to 7 days, and default to Cancel. Every pickup
  link this app can cause is the server-readable kind; softening the wording
  defeats the opt-in.
- **The pickup opt-in is per message and never remembered.** `encrypt`, `sign`
  and `allowPickupFallback` live on the view model and die with the window.
  Do not persist them to `ComposeDraft`, `UserDefaults`, or the keychain.
- **A keyless 409 re-send must reuse the refused `OutgoingEmail`**
  (`PendingPickup.email`), flipping only `allowPickupFallback`. Rebuilding from
  live compose state risks a subtly different message; re-running the preflight
  wastes a round trip on a question the 409 already answered.
- **The preflight is a lower bound.** `/api/pgp/recipients/check` searches only
  the user's contacts, while the send path also runs WKD and keyserver
  discovery. Word it "no key on file", never "this will be sent in the clear".
- **A relay `warning` on a 200 means the message was sent.** Show it as a
  notice, keep the window open, and leave Send disabled (`isSent`) — a retry
  duplicates the message. Never pattern-match the warning's wording.
- **Entry points own `isSending`, and claim it before their first `await`.**
  `send`, `confirmPickupFallback` and `handOffToWebmail` set it immediately
  after their `!isSending, !isSent, !didSend` guard; `deliver` and `handOff`
  never touch it (a nested `defer` would clear it early on the handoff path).
  With Encrypt on, the recipient preflight is a live round trip sitting right
  after that guard — claiming the flag any later lets a second ⌘↩ through and
  posts the message twice.
- **The message reader's navigation policy is default-deny.**
  `EmailBodyWebView.navigationPolicy` allows the `about:` load of the message
  itself, routes link taps to `openURL`, and blocks everything else. JS off
  and `loadsSubresources = false` do not cover main-frame navigation — a
  `<meta http-equiv="refresh">` is neither script nor subresource — so an
  allow-by-default branch here silently reopens the remote-content beacon.

## Work Guidance

- About and Support are shared across iOS Settings and the macOS About window.
  macOS exposes one standard About KyPost app-menu item; it does not duplicate
  the surface as a Preferences tab. `AboutView` owns the version, 2026
  Busnes.app copyright, privacy-policy link, embedded MIT license, and StoreKit
  2 donation presentation. `TipJarStore` uses `CupOJoe4Mail` for one-off
  purchases only; prices come from App Store Connect and must not be hardcoded.
  Do not offer recurring support without an ongoing customer benefit.
  `start()` keeps the `Transaction.updates` listener and drains
  `Transaction.unfinished`: a tip that returns `.pending` (Ask to Buy) is
  only ever finished there. Only verified transactions are finished. The
  StoreKit surface is injected (`TipJarTransactionSource`) so
  `TipJarStoreTests` runs without StoreKitTest or a simulator store.

- Reuse `ContactSearch` for any contact matching; don't hand-roll a filter.
  `localizedCaseInsensitiveContains` over every contact per keystroke routes
  through ICU collation — prefer the prebuilt folded index.
- Never map a range found in a folded string onto the original: folding isn't
  length-preserving ("ß"→"ss"), so indices misalign or trap. Fold to filter;
  match the original to highlight.
- Validate addresses with `EmailAddress.isValid` (HTML5 grammar, not RFC 5322).

## Platform deviations (compose recipients)

Recorded so they aren't re-litigated as bugs:

- **No arrow-key/Escape navigation on iOS.** `onKeyPress` needs a hardware
  keyboard; the soft keyboard has no arrows. iOS is tap-driven.
- **No backspace-deletes-last-token.** AppKit's field editor consumes
  backspace before `onKeyPress` sees it at any level of the focus chain, even
  with the field empty. The only workaround is a zero-width sentinel in the
  text, which corrupts paste. Tokens come off via their X button. Tab, Return,
  Escape and the arrows *do* arrive.
- **The dropdown highlights nothing by default.** Preselecting row 0 would
  make Return on a fully-typed address insert a different contact.

## Verification

- Unit: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
  (Swift Testing; `ContactSearchTests`, `ComposeRecipientTests`,
  `ThemeTests`, `InboxParityTests.swift` for the inbox-list rules and the undo
  window, `OlderMailTests.swift` for older mail, delta overflow and bodies on
  open, `MailIdentityTests.swift` for the (folder, id) key).
- Pass `debounceInterval: .zero` to `ComposeViewModel` in tests, and poll for
  the result rather than sleeping a fixed span — the search lands a scheduling
  hop later even at zero, so a fixed sleep goes flaky under load.
- Focus, key routing, overlay z-order, and `FlowLayout` wrapping are not
  unit-testable — drive the app (XCUITest against the `New Email` window
  reaches them) and look at the result.

## Child DOX Index

None.
