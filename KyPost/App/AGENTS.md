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
router (the return presents nothing, so the lock does not defer it), and
`scenePhase == .active` makes it check for KyAuth's response.

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
flags, store, photos, temp attachments, delivered notifications, drafts. Keep
it that way — anything that unlocks *without* erasing is a bypass.

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
  `PushNotificationDispatcher.handleIncoming` and `presentLocally`.

`AppLockManager.onWipe` is wired in `onLaunch`. Left unset it fails closed and
reports a wipe that could not run, rather than rejecting the eleventh wrong PIN
exactly like the third.

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

Background pull is gated on `appLockManager.isLocked` in the `BGTaskScheduler`
handler as well as in `onForeground`, and `presentLocally` withholds sender and
subject while locked. "Require Unlock to Open" reads as "nobody sees my mail
without authenticating"; a subject line on the lock screen breaks that.

## Verification

- `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
  (`AppEnvironmentTests`, `SecurityTests`, `SecurityWipeTests`,
  `SecurityWipeStepsTests`).
- The rebuild path is exercised end-to-end by toggling Hostile Location
  Protection in Settings → Security on a paired build.

## Child DOX Index

None.
