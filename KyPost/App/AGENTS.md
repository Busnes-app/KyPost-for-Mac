# App layer — dependency graph, lifecycle, and the rebuild rule

Scope: `KyPost/App/` — the entry point, delegates, `SingletonGraph`,
`AppEnvironment`, and the pull-polling scheduler.

## The one rule that must not regress

`SingletonGraph.shared` is a **computed alias** into
`AppEnvironment.shared.graph`. Hostile Location Protection swaps the whole
graph at runtime (`AppEnvironment.rebuild`), so:

- **Re-read `SingletonGraph.shared` (or a child) at every use.** Computed
  properties and closure bodies that dereference `.shared` inline are safe.
- **Never capture the graph or one of its children into long-lived state**
  (an `App`-level `@State`, a global, a notification-observer capture list)
  unless that state sits inside a view tree keyed with
  `.id(environment.generation)` — those are torn down and rebuilt on swap.
- Every scene root in `KyPostApp` carries `.id(environment.generation)`.
  A new `WindowGroup`/`Settings` scene must too, plus the `LockedOverlay`
  and `protectedFromCapture()` modifiers its siblings have.
- `SingletonGraph.shutdown()` must stop any new long-lived task or resource
  a graph child owns (pollers, monitors, auto-refresh loops, and
  `relaySession`, whose delegate-backed `URLSession` holds its delegate and
  connection pool until `invalidateAndCancel()`). If you add one, add its
  stop call there, or the superseded graph keeps writing to a database the
  app no longer shows — or, worse, keeps relay connections open through the
  Hostile Location Protection swap that was meant to close them.

`KyIdentitySignOnCoordinator` (iOS) is App-level `@State` beside the router
for the same reason: a sign-on spans a trip to KyAuth, during which the lock
tears the pairing sheet down. It holds no graph child and re-reads `.shared`
per use. `onOpenURL` offers `kypost://kyidentity-signon` to it before the
router, and `scenePhase == .active` makes it check for KyAuth's response.

- **The token exchange is gated like any windowless entry point.** While
  `KyIdentitySignOnCoordinator.appIsGated()` (locked, `startupWipeVerdict`
  pending, or `blockedByAbandonedWipe`) the response stays unread in the App
  Group — no ID token in memory, no relay call. `KyPostApp` re-checks on the
  gate clearing, which is how a return that lands on the lock screen
  completes after unlock. The 180 s deadline still applies.
- **`.kyPostSessionReset` clears App-level state.** `performSecurityWipe`
  (first, before any await), `resetAfterFailedUnlock`, and
  `SettingsViewModel.unpair` post it; the coordinator `reset()`s (withdraws
  the request, discards the response, drops a finished link, voids in-flight
  work), the router drops its deferred action and presented routes, and
  `ForwardAttachmentHandoff` drops a forward's held attachments and voids any
  forward still in flight, and `RsvpTracker` ends its RSVP session (which also
  voids any calendar handoff waiting on its confirmation or the permission
  prompt).
  Anything new that erases the pairing posts it, and any new App-level state
  that could present or re-pair observes it (`NotificationObservation`).

`AppEnvironment.eraseHostileLocationDefaults` runs when Hostile Location
Protection turns on and at every launch while it is on (`PushLifecycle.onLaunch`).
A `UserDefaults`-backed store that goes memory-only under the mode erases its
persisted copy there; switching reads to memory does not remove it.

`shutdown()` also **drops** the inbox's held list actions (the undo window),
its older-mail paging state and the rows it shows, voiding any refresh in
flight (`InboxViewModel.forgetAccount`) rather than
sending them: the superseded graph's session is cancelled, and a
rebuild is a Hostile Location Protection switch or a wipe. The lock sites
(`PushLifecycle.onBackground`, the macOS screen-lock observer) instead
**commit** them — on iOS the `didEnterBackgroundNotification` observer in
`installLifecycleObservers` commits first, under a background assertion —
and must do so before `appLockManager.lockAfterGrace()` (a grace period
does not extend the undo window) — see the root "Inbox list actions"
contract.

**Leaving an account is one list, `AccountTeardown`** (enrollment vault,
session and pending reports; notification history and pull cursor; recipient
pins; mail signature; cached mail and cursors; the inbox's held actions and
rows). `SettingsViewModel.unpair` runs it after clearing the pairing, and a
registration that stores a pairing for another `sub` or server over the
current one runs it first (`DeviceRegistrationService.onAccountReplaced`,
wired to `SingletonGraph.makeAccountTeardown`); an unreadable previous
pairing counts as another account. A new account-scoped store adds its clear
there, not at either call site.

`AppEnvironment.onRebuild` re-runs the launch wiring (`PushLifecycle`)
after a swap; it is nil under tests so no runtime services start there.
It is installed once, from the platform delegate
(`PushLifecycle.installRebuildHandler`), **not** from `onLaunch` — installing
it there made `onLaunch` assign a closure that calls `onLaunch`, reassigning
the property from inside `rebuild` while that same property was being invoked,
and re-ran `requestAuthorization` on every toggle.

`AppEnvironment.shared` never traps on a bad store. A `ModelContainer` that
will not open falls back to deleting the store files, then to an in-memory
container; only an invalid *schema* is fatal. Mail lives on the server, so the
local store is always disposable.

`AppEnvironment.resetAfterFailedUnlock` is the app lock's only escape hatch,
offered by `UnlockView` once `AppLockManager.shouldOfferReset` is true. It
erases rather than bypasses: gated secret, pairing, desktop session, both lock
flags, store, photos, temp attachments, delivered notifications, drafts, the
mail signature. Keep
it that way — anything that unlocks *without* erasing is a bypass.

## URL schemes

`KyPost/Info.plist` declares two `CFBundleURLTypes`: `kypost` (pairing,
desktop pairing, the iOS KyIdentity return) and `mailto`, which is what lets
macOS offer KyPost as the default mail app. iOS cannot become the default mail
app without Apple's entitlement, so there a `mailto:` is handled only if
something opens one here. Both arrive through `onOpenURL` →
`NavigationRouter.handleURL`; the mailto parse never touches the pairing
parsers' rules.

## The startup wipe gate

`PushLifecycle.onLaunch` starts `AppEnvironment.enforceWipeAtStartupOnce()`
**first**, and `KyPostApp.rootView` renders `StartupGatePlaceholder` until
`startupWipeVerdict` settles. The check is a gate and has to be used as one:
Android ran the equivalent in a fire-and-forget coroutine under a comment
claiming it ran before anything read cached data, so deleting the app-lock
state to disable the lock got the inbox rendered with every cached message
intact and the wipe landed a few hundred milliseconds later.

- **Once per process.** A wipe rebuilds the graph and a rebuild re-runs
  `onLaunch`; without the guard the app would wipe itself in a loop.
- `AppEnvironment.performSecurityWipe` reads the pairing **before** the steps
  run (the `pairing` step deletes what the deregister authenticates with),
  records `wipeNotice` **before** the rebuild (the rebuild replaces the graph a
  notice stored there would live in), and rebuilds last — which is what closes
  the SwiftData file descriptors on the store the wipe unlinked.
- A verdict of `.settled(.incomplete(_, willRetry: false))` blocks the whole
  app behind `ManualRecoveryView`. Entry points that never present a window
  guard on `securityWipe.blockedByAbandonedWipe` themselves — currently
  `PushNotificationDispatcher.handleIncoming`, `presentLocally`,
  `presentMfaLocally`, `deliveredRemotePushes`, the KyIdentity sign-on
  (`KyIdentitySignOnCoordinator.appIsGated`), and notification history
  (`NotificationHistoryAccess`), which the macOS Settings scene shows outside
  the main window's recovery screen.

`AppLockManager.onWipe` is wired in `onLaunch`. Left unset it fails closed and
reports a wipe that could not run, rather than rejecting the eleventh wrong PIN
exactly like the third.

## iOS lifecycle runs on notifications, not delegate callbacks

The iOS app is scene-based (the SwiftUI lifecycle generates a scene manifest),
and UIKit does not call `applicationDidEnterBackground`,
`applicationWillEnterForeground` or `applicationDidBecomeActive` on the app
delegate in a scene-based app. `AppDelegate.installLifecycleObservers` drives
`PushLifecycle.onBackground` (+ `scheduleBackgroundPull`),
`returnedWithinGrace` and `onForeground` from the matching `UIApplication`
notifications instead. Those fire once per app-level transition however many
scenes are open, and are handled synchronously on the main queue so the lock
engages before the background snapshot. Do not add those delegate methods
back; they are dead code here. `PrivacySnapshotCover` uses the per-scene
`UIScene` notifications because it covers each scene's own window.

## Lock ordering at launch

`PushLifecycle.onLaunch` wires `credentialGateService.wireAtLaunch()`
**before** any poll, and `onForeground` is gated on
`appLockManager.isLocked` — the deferred sync runs from `onUnlock`.
Reordering these reintroduces either a blank-secret read (gate on) or a
locked-launch poll.

`wireAtLaunch` is also the credential gate's only repair point: the gate
enabled *without* the app lock is a state the running session cannot escape
(its toggle is disabled, and `requestUnlock` returns early once unlocked, so
the in-memory secret can never come back). Settings refuses to create it —
`SecuritySettingsView` authenticates first, then clears the gate *before*
dropping the lock and aborts the whole change if that fails — and a relaunch
resolves it if a partial write ever does.

That repair is driven by `AppLockStore.lockState`, never `lockEnabled`.
`lockEnabled` collapses a Keychain read failure into `false`, which is right
for deciding what to *show* and wrong for deciding to repair: the repair writes
the device secret back into the plain, non-presence-gated item, and one
transient `errSecInteractionNotAllowed` at launch used to trigger it
permanently. Any new caller that acts destructively on this flag uses
`lockState` and fails closed on `.unreadable`.

`PushLifecycle.runEnrollmentReporter()` restates an enrollment acknowledgement
that did not land, or a Hostile Location Protection teardown. It runs from
`onForeground` and, on macOS, from `applicationDidBecomeActive` — macOS has no
foreground transition, so without it a pending report waits for a relaunch or
an unlock. It is a no-op without a marker, nil when unpaired, and
`EnrollmentReportTrigger` skips it while `appLockManager.isLocked` or
`securityWipe.blockedByAbandonedWipe` (telling the server what key material
this device holds is not a claim to make from a device the app failed to
erase) and while a run is already in flight, so overlapping hooks send once.

Background pull is gated on the lock in the `BGTaskScheduler` handler, the
macOS wake observer, and `onForeground`. Each resolves a pending grace-period
deadline (`resolvePendingLock` / `returnedWithinGrace`) before reading
`isLocked`, because a suspended iOS app never ran the timer. On macOS the
screen-unlock notification cancels the deadline only when
`CGSessionCopyCurrentDictionary` confirms the screen is unlocked, and
`shutdown()` stops the pending-lock timer. `presentLocally`
withholds sender and subject while locked, from the banner *and* its stored
`userInfo`. "Require Unlock to Open" reads as "nobody sees my mail without
authenticating"; a subject line on the lock screen breaks that.

## Pull is also the push-mode heartbeat

The server queues every notification for pull in both delivery modes and never
flips the mode itself (server issue #137 option 1, Android #129), so a device on
a dead relay recovers only by polling. `PullPollingScheduler` runs in both modes
and `PullHeartbeatPolicy.decide` says whether a tick touches the network:

- Pull mode always polls. Anything else (push, or no mode yet) polls only once
  APNs has been quiet for 3 h (a constant), counted from
  `PushSettingsStore.lastPushReceivedAt`, else `lastRegisteredAt`; heartbeat
  polls are then spaced 15 min apart, counted from the later of the last
  successful pull and `lastHeartbeatAttemptAt` (stamped *before* the request,
  so a failing relay is not retried every tick). A pull answer of "push" is
  not "stop".
- `lastRegisteredAt` is set by a new pairing only. Routine re-registration of
  the same account (same `sub` and `srv`) keeps it: it proves the relay
  answers, not that APNs delivers. A same-account pairing with no stamp yet
  (it predates the stamp) gets one, and then
  `DeviceRegistrationService.reconcileExistingPairingPushes` records its
  delivered banners regardless of the stamp, so the next heartbeat does not
  re-alert them.
- `lastPushReceivedAt` only moves forward and is fed by every handled APNs
  payload, `willPresent`, and the newest `UNPushNotificationTrigger` banner
  still in Notification Center — the server sends alert pushes, which do not
  wake a suspended iOS app, so the banner is the only evidence. Each tick also
  records those banners' mail into history
  (`PushRepository.reconcileDeliveredPushes`) before pulling, so the heartbeat
  does not alert them a second time — only banners inside the heartbeat
  window and dated after `lastRegisteredAt`, since unpair leaves Notification
  Center alone. A reconcile run is pinned to the session it started under and
  stops when unpair moves it on.
- A heartbeat (and a first pull, cursor 0) drops entries queued more than 6 h
  ago while still advancing the cursor past them; a months-stale cursor would
  otherwise re-alert the whole backlog.
- The wire shape is the server's `{seq,title,body,data,createdAt}` with mail or
  MFA fields inside `data` — `PullNotificationDTO.routed`, MFA first. History
  dedupes by `messageId` as well as `seq`, so mail push already delivered is not
  alerted twice; pulled MFA is never stored and is raised only within the
  server's 5-minute window — measured when the banner is raised, not at tick
  start — as a detail-free tap-to-open banner.
- `pollNow` is single-flight. The iOS refresh task is armed whenever paired.
  `PullPollingScheduler.shutdown` (graph teardown) cancels the poll in flight
  as well as the cadence; backgrounding only stops the cadence. A cancelled
  poll persists and presents nothing: `PushNotificationDAO.insert` itself
  refuses a cancelled caller, so an insert queued on the actor at shutdown
  does not land.
- History shows 30 rows (`PushNotificationDAO.historyLimit`). Rows pushed past
  that keep only their message id, seq and time for
  `deliveryIdRetention` (the heartbeat window) and are then deleted; they are
  never listed. The cap is applied at launch and when the history screen
  loads, not only on insert.
- Unpair clears history, the pull cursor and the heartbeat clock
  (`PushRepository.clearForUnpair`), and first moves the repository's
  `session` on. Every write a pull makes — history rows (checked inside the
  DAO actor), cursor, delivery mode, heartbeat stamps — and every banner it
  raises is checked against the session it started under.

## The screenshot demo build

`DemoContent.swift` is `#if DEBUG` in full and inert unless the process is
launched with `-KyPostDemo`. It exists so App Store screenshots can be taken
without photographing the developer's own mail, and without a pairing or a
network. `scripts/capture-screenshots.sh` drives it through
`KyPost UITests/ScreenshotTests`.

Three seams carry it, and each one defaults to the real path:

- `MailRepository(overrideSource:)` — serves `DemoMailSource` and **skips the
  pairing guard in `refreshFolder`**. Without it an unpaired build paints
  "Pair this device (Settings → Connection) to load mail" over every shot.
- `PgpSendService.preload(hasIdentity:protection:accountAddress:)` — installs
  a bootstrap answer so compose offers Encrypt/Sign. Nothing in a shipping
  build may decide custody locally; this is the only caller.
- `SingletonGraph.isDemo` (init default `launchIsDemo`) — one switch read by
  the stores, the database and photo cache (in-memory, so a demo mailbox never
  lands on disk beside real mail), the mail source, the Contacts adapter, the
  push wiring, and the contact seed in `runStartupMigrationsIfNeeded`.

Rules:

- **Never make the demo switch reachable from the UI or from a Release
  build.** It fabricates mail and asserts a key custody the server never
  confirmed; both are lies if a user can reach them.
- The demo database is in-memory on purpose. Do not "fix" it to persist.
- **The demo graph never touches the real app's state.** It replaces
  whatever defaults, Keychain, gated credential, device-key tag and Contacts
  store it was given with `DemoContent.isolated*` stand-ins and
  `NoopSystemContactStore`, skips APNs registration and the notification
  prompt, and returns from `runStartupMigrationsIfNeeded` after seeding —
  the repairs belong to the real stores. The theme reads
  `SingletonGraph.launchUserDefaults` for the same reason. Anything new that
  persists or reaches the network goes through the graph, or is gated on
  `isDemo` explicitly.
- `-KyPostDemoScreen` is read only together with `-KyPostDemo`.
- `ScreenshotTests.capture` attaches the app's own window or nothing. Never
  add a whole-display fallback on macOS: the display carries other apps.
- `-KyPostDemoScreen mfa` exists because MFA approval arrives by push and has
  no navigable route. Add a case there rather than a new launch argument.
- The fixtures are invented. Keep them invented, and keep the addresses on
  `.example` — a screenshot is published, and a real address in one is a
  real person's inbox.

## Verification

- `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
  (`AppEnvironmentTests`, `SecurityTests`, `SecurityWipeTests`,
  `SecurityWipeStepsTests`, `PullHeartbeatTests`).
- The rebuild path is exercised end-to-end by toggling Hostile Location
  Protection in Settings → Security on a paired build.

## Child DOX Index

None.
