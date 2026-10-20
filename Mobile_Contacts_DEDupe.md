# Contact De-duplication — Mobile Integration Guide

> Implementation record: this note uses historical repository names and describes its original rollout. For current installation and supported behavior, start with [README.md](README.md); KyPost Server owns the current wire contracts. Completion notes here do not establish present-day live integration coverage.

This document describes how to expose the backend's contact
de-duplication feature (`llama-labels` repo) to all three mobile/desktop
clients: this repo's Android app, `kypost-for-Mac` (iOS/macOS), and
`llama-Linux` (KDE Plasma Desktop + Plasma Mobile). It mirrors
`Client_Contact_Update.md`'s shape — a Part 0 backend prerequisite, a
shared contract, then one concrete section per client — written so a
fresh Claude session in any of the three client repos (or in
`llama-labels`) can implement its slice with no other context beyond
reading the current source files it points to.

## Summary

The backend already has a complete, tested de-duplication implementation:
`backend/internal/contacts/dedupe.go` (matching/merge logic) +
`Store.Dedupe()` (`backend/internal/contacts/store.go:265`) + the HTTP
handler `handleContactsDedupe` (`backend/internal/api/contacts_handlers.go:123`),
exposed as `POST /api/contacts/dedupe`. It finds duplicate live contacts —
sharing a normalized email or phone, or a normalized name when at least
one side is otherwise empty — merges each qualifying group into its
oldest member (unioning multi-value fields, taking scalars from the
most-recently-updated member), and tombstones the losers so every sync
client converges on the same result via its ordinary sync pull. It is
**exact-match only** (no fuzzy/similarity matching, no libphonenumber —
see the dedupe design doc referenced below for why) and **on-demand
only** (no scheduled job, no auto-trigger on import).

**Decision for this feature: mobile does not reimplement any of this.**
Each client adds a manual "Find & merge duplicates" action that calls
`POST /api/contacts/dedupe` directly, shows the returned report, then
runs its existing sync pull to pick up the resulting tombstones and
merged survivor. The server remains the sole authority on what counts as
a duplicate and how fields merge — this doc is about *exposing and
consuming* that decision, not duplicating it. See
[Part 0](#part-0-prerequisite-backend-gap--fix-in-llama-labels-first) for
the one thing that has to change first.

Full backend design rationale (why exact-match, why on-demand, the merge
policy details, survivor selection, the chain/component guard against
over-merging): `docs/superpowers/specs/2026-07-12-contact-dedupe-design.md`
in the `llama-labels` repo. Read that before touching any of the code
below — this doc assumes it and does not repeat it.

---

## Part 0: Prerequisite backend gap — fix in `llama-labels` first

`POST /api/contacts/dedupe` is registered with `s.withAuth(...)`
(`backend/internal/api/server.go:202`):

```go
mux.HandleFunc("POST /api/contacts/dedupe", s.withAuth(s.handleContactsDedupe))
```

`withAuth` (`server.go:2841`) only accepts a web session cookie
(`s.currentUser(r)`). None of the three mobile clients have a session
cookie — they all authenticate with pairing credentials (`sub`/`hash`
query params), same as `GET/POST /api/contacts/sync`. This is the exact
same trust-boundary gap `Client_Contact_Update.md`'s own Part 0 already
identified for `GET /api/groups` and `GET /api/contacts/{id}/photo` — as
of this writing those are **also still unfixed** (still `withAuth` at
`server.go:221` and `server.go:219`), so whoever picks up any of these
three gaps should fix them together rather than three separate PRs
re-deriving the same pattern.

**The fix.** `handleContactsDedupe` doesn't read auth itself — it calls
`s.contactsFor(r)` (`server_userscope.go:107`), which calls
`authFromContext(r)` to read whatever `AuthContext` the routing
middleware injected. `withMailAuth` (`server.go:2857`) already injects
that same `AuthContext` under the same `authContextKey{}`, via
`resolveMailAuthContext` (`server_userscope.go:236`), which accepts
**either** a session cookie **or** `sub`/`hash` pairing — mechanically
identical to what `/api/contacts/dedupe` needs. Two ways to land this,
in order of preference:

1. **If groups/photo's Part 0 fix has already landed** by the time this
   is picked up, it will have generalized `resolveMailAuthContext` into
   a shared, non-mail-specific helper (its doc comment already says "it
   already has no mail-specific logic in it" — `Client_Consact_Update.md`
   recommended exactly this generalization). Reuse that same helper for
   `/api/contacts/dedupe` rather than inventing a second one.
2. **If not landed yet**, the minimal, verified-correct interim fix is
   to swap the route registration:
   ```go
   mux.HandleFunc("POST /api/contacts/dedupe", s.withMailAuth(s.handleContactsDedupe))
   ```
   This works today with **zero handler changes** (confirmed: `withAuth`
   and `withMailAuth` inject the identical `AuthContext` shape via the
   identical context key, and `contactsFor`/`authFromContext` don't care
   which one populated it). Do update `withMailAuth`'s doc comment
   (`server.go:2852`, currently "gates mail read/act-on endpoints...")
   to mention it's now also used for contacts dedupe, or rename it to
   something scope-neutral (e.g. `withPairingAuth`) if you're touching it
   anyway — don't leave a misleading comment.

Either way, this is a self-contained, low-risk change confined to
`backend/internal/api/`. Do it as its own small PR before starting any
client work below, and verify it's callable via pairing auth before any
client code depends on it:

```
curl -X POST 'https://<server>/api/contacts/dedupe?sub=<subscriberId>&hash=<subscriberHash>'
```

Expect `200` with a `DedupeReport` body (see next section) — or `401` if
the hash is wrong, matching `/api/contacts/sync`'s existing error
contract.

---

## Shared contract (all three clients)

**Request.** `POST /api/contacts/dedupe?sub=<subscriberId>&hash=<subscriberHash>`,
empty body — same query-param pairing convention as
`/api/contacts/sync`, not headers, not a cookie.

**Response** (`DedupeReport`, `backend/internal/contacts/store.go:254`):

```json
{
  "mergedCount": 3,
  "groups": [
    { "survivor": "abc-123", "absorbed": ["def-456", "ghi-789"] }
  ]
}
```

`mergedCount` is the total number of contacts tombstoned (losers);
`groups` is `[]` when nothing merged. `survivor`/`absorbed` are UIDs, not
display names — clients that want to show names in the report need to
resolve them against their already-synced local contact list (all UIDs
in the response were, by definition, contacts the client already knows
about, since dedupe only ever operates on the caller's own existing
address book).

**Every client implements the same four steps:**

1. **Trigger** — a manual, user-initiated action (e.g. a menu/toolbar
   item near the existing "Sync"/"Refresh" action). No auto-trigger on
   sync, import, or app foreground — this matches the backend having no
   scheduled job either.
2. **Call** — `POST /api/contacts/dedupe` as above. Reuse each client's
   existing HTTP stack and error-handling shape (the same
   401/503/network-error categories the existing sync client already
   distinguishes) — this is a plain request/response call, nothing
   streaming or long-running.
3. **Report** — show a simple result: "N duplicate groups merged" (or
   "No duplicates found" when `mergedCount == 0`), optionally expandable
   to list survivor/absorbed names once resolved locally.
4. **Refresh** — immediately trigger the client's existing sync pull so
   the local cache picks up the tombstones (absorbed contacts, which
   arrive as ordinary deletes) and the updated survivor record (which
   arrives as an ordinary change) on the very next pull. **Nothing new
   to parse here** — a dedupe result is indistinguishable, on the wire,
   from any other change another device or the web UI made; it rides the
   existing sync delta format untouched.

**Invariant to hold in every client implementation:** no client
implements duplicate-matching or merge logic for this feature. If you
find yourself writing an email/phone-normalization function for this
work, stop — that means you've misread the contract. (Android's
`DeviceContactMatcher.kt` and Mac's `SystemContactsExporter.swift` also
do email/phone matching, but for a *different* problem — linking a
device-native contact to an already-synced one — and are unrelated to
this feature. Don't merge these concerns; see each client section.)

**Known limitations, shared across all three clients:** none of the
three local contact models carry the backend's `mergedUIDs`/`mergedInto`
provenance fields yet, so no client can show "this contact absorbed
these others" from local storage after the fact — the report shown
immediately after a dedupe call is the only place that information is
ever visible client-side. That's an acceptable v1 gap, not something
this doc asks you to fix (it's `Client_Contact_Update.md`-shaped field
work, tracked separately per client). Client-specific extra gaps are
called out in each section below.

---

## Android

**Network call** — add to `ContactSyncClient.kt`
(`app/src/main/java/com/urlxl/mail/contacts/ContactSyncClient.kt`),
alongside the existing `pull`/`push`:

```kotlin
sealed class ContactDedupeResult {
    data class Success(val report: ContactDedupeReportDto) : ContactDedupeResult()
    data class Unauthorized(val message: String) : ContactDedupeResult()
    data class ServiceUnavailable(val message: String) : ContactDedupeResult()
    data class Retryable(val message: String) : ContactDedupeResult()
}

suspend fun dedupe(serverUrl: String, subscriberId: String, subscriberHash: String): ContactDedupeResult {
    val base = "${serverUrl.trimEnd('/')}/api/contacts/dedupe".toHttpUrlOrNull()
        ?: return ContactDedupeResult.Retryable("Server URL is not valid")
    val url = base.newBuilder()
        .addQueryParameter("sub", subscriberId)
        .addQueryParameter("hash", subscriberHash)
        .build()
    val request = Request.Builder().url(url).post("".toRequestBody(JSON_MEDIA_TYPE)).build()
    // parse via json.decodeFromString<ContactDedupeReportDto>, same shape as execute()'s
    // 200 branch for pull/push — 401/503/other map to the result types above the same way.
}
```

**New DTOs** in `ContactSyncModels.kt`:

```kotlin
@Serializable
data class ContactDedupeReportDto(
    val mergedCount: Int = 0,
    val groups: List<ContactDedupeGroupDto> = emptyList(),
)

@Serializable
data class ContactDedupeGroupDto(
    val survivor: String = "",
    val absorbed: List<String> = emptyList(),
)
```

**Repository** — add to `ContactSyncRepository.kt`
(`app/src/main/java/com/urlxl/mail/contacts/ContactSyncRepository.kt`),
next to the existing `ContactSyncOutcome` sealed class and `sync()`:

```kotlin
sealed class ContactDedupeOutcome {
    data class Success(val report: ContactDedupeReportDto) : ContactDedupeOutcome()
    object NotPaired : ContactDedupeOutcome()
    object Unauthorized : ContactDedupeOutcome()
    data class ServiceUnavailable(val message: String) : ContactDedupeOutcome()
    data class Retry(val message: String) : ContactDedupeOutcome()
}

suspend fun dedupe(): ContactDedupeOutcome {
    val pairing = pairingProvider() ?: return ContactDedupeOutcome.NotPaired
    return when (val result = client.dedupe(pairing.serverUrl, pairing.subscriberId, pairing.subscriberHash)) {
        is ContactDedupeResult.Success -> ContactDedupeOutcome.Success(result.report)
        is ContactDedupeResult.Unauthorized -> ContactDedupeOutcome.Unauthorized
        is ContactDedupeResult.ServiceUnavailable -> ContactDedupeOutcome.ServiceUnavailable(result.message)
        is ContactDedupeResult.Retryable -> ContactDedupeOutcome.Retry(result.message)
    }
}
```

`dedupe()` deliberately does **not** call `sync()` internally — keep it a
single-purpose method (mirrors `sync()` itself only doing pull-or-push,
not both). The caller triggers the refresh explicitly, per the shared
contract's step 4.

**UI wiring** — `ContactsListActivity.kt`
(`app/src/main/java/com/urlxl/mail/contacts/ContactsListActivity.kt`)
already has the exact pattern to copy at `onCreateOptionsMenu`/
`onOptionsItemSelected` (lines 122–170) and its `MENU_REFRESH`/
`MENU_DEVICE_SYNC` companion constants (line 245). Add a third:

```kotlin
private const val MENU_DEDUPE = 2
```

```kotlin
menu?.add(0, MENU_DEDUPE, 0, R.string.contacts_dedupe)
```

and in `onOptionsItemSelected`, follow `MENU_REFRESH`'s exact shape —
launch in `lifecycleScope`, call `repository.dedupe()`, map the outcome
to a string resource, `Toast` it, then on `Success` also call
`repository.sync()` (step 4 of the shared contract) before showing the
toast or as a follow-up toast — either ordering is fine, just don't skip
it. Add `contacts_dedupe` (button label) and result strings (e.g.
`contacts_dedupe_result` with a `%d` placeholder for `mergedCount`,
`contacts_dedupe_none`) to the strings resource, next to the existing
`contacts_sync_success`/`contacts_sync_unauthorized` entries.

**Known limitation (Android-specific).** `ContactEntity`/`ContactDto`
carry `emails`/`phones` as arrays already, so a merge that unions two
emails will show up correctly after the follow-up sync. But neither
carries the backend's extended fields (`photoRef`, `groupIDs`, `pgpKey`,
`ims`, etc. — see `Client_Contact_Update.md`) or `mergedUIDs`/
`mergedInto`, so a merge that combines those on the survivor silently
drops them on decode (`Json { ignoreUnknownKeys = true }`) until that
separate field-parity work lands. Not a regression from this feature —
it's the same gap that already exists for every other source of those
fields.

---

## iOS/macOS (`kypost-for-Mac`)

**Network call** — add to `ContactSyncClient.swift`
(`KyPost/Data/Networking/ContactSyncClient.swift`), which
already has `pull`/`push` following this exact shape:

```swift
struct ContactDedupeGroup: Decodable, Equatable, Sendable {
    var survivor: String
    var absorbed: [String]
}

struct ContactDedupeReport: Decodable, Equatable, Sendable {
    var mergedCount: Int
    var groups: [ContactDedupeGroup]
}

func dedupe(serverUrl: String, auth: RelayAuth) async throws -> ContactDedupeReport {
    try await httpClient.post(
        ContactDedupeReport.self,
        url: try dedupeEndpoint(serverUrl),
        query: auth.queryItems,
        jsonBody: EmptyEncodable()  // or whatever this HTTPClient uses for a bodyless POST — check its post() overloads for the pattern the codebase already uses elsewhere (e.g. logout/action-style calls), don't invent a new one
    )
}

private func dedupeEndpoint(_ serverUrl: String) throws -> URL {
    guard let url = URL(string: serverUrl) else { throw NetworkError.invalidURL }
    return url.appending(path: "api/contacts/dedupe")
}
```

**Repository** — add a `dedupe()` method to `ContactSyncRepository.swift`
(`KyPost/Domain/Repositories/ContactSyncRepository.swift`),
alongside its existing `sync()` (line 90). Same single-purpose rule as
Android: `dedupe()` calls the client and returns the report/error; it
does not call `sync()` itself.

**UI wiring** — `ContactsListView.swift`
(`KyPost/Presentation/Screens/ContactsListView.swift`,
lines 58–74) has two `ToolbarItem { Button { ... } }` blocks already
("Add Contact", "Sync"). Add a third calling into
`ContactsViewModel.swift`'s new `dedupe()` method (mirror its existing
`sync()` at line 28 — `isSyncing`-style busy flag, `guard`, `defer`),
which on success also calls `await sync()` before returning (step 4),
and surfaces the report via a `Text`/alert similar to how sync errors
already surface (check `ContactsViewModel`'s existing error-surfacing
property for the pattern to reuse rather than adding a second one).

**Known limitation (Mac-specific, the largest of the three).**
`ContactDTO` already carries `emails: [ContactFieldDTO]?`/
`phones: [ContactFieldDTO]?` on the wire, but the domain `Contact`/
`ContactEntity` (`Data/Database/ContactEntity.swift`,
`Domain/Models/Contact.swift`) only have a single `email: String`/
`phone: String` — whatever mapping step collapses the wire array down to
one value (check the DTO↔domain mapper for exactly which value it
picks, likely `.first`) means **a merge that unions two emails will
silently lose all but one** on this client specifically, worse than
Android or Linux. Flag this plainly in any PR description for this
feature rather than let a QA pass "discover" it as a surprise — it's a
pre-existing model gap, not something this feature is expected to fix.

---

## Linux / KDE Mobile (`llama-Linux`)

This client's `Contact.h` model is the closest of the three to the
backend's (name parts, multi-value emails/phones/addresses, org, title,
notes, birthday all present — see `core/models/Contact.h`), and its
`ContactSyncClient` already round-trips every field 1:1 with the backend
(comment in `core/net/ContactSyncClient.h:12`), so this is the
lowest-risk client for this feature.

**Network call** — add to `core/net/ContactSyncClient.h`/`.cpp`,
alongside the existing `pull`/`push` (`ContactSyncClient.h` declares
these taking a `const RelayAuth&`, defined in `core/net/RelayAuth.h`):

```cpp
struct ContactDedupeGroup
{
    QString survivor;
    QVector<QString> absorbed;
};

struct ContactDedupeResult
{
    std::optional<NetworkError> error;
    QString detail;
    int mergedCount = 0;
    QVector<ContactDedupeGroup> groups;
};

// POST {serverBaseUrl}/api/contacts/dedupe?sub&hash, empty body.
ContactDedupeResult dedupe(const QUrl& serverBaseUrl, const RelayAuth& auth) const;
```

Follow `pull`/`push`'s existing shape in `ContactSyncClient.cpp` (line
214 onward) for how the request is built and the response JSON parsed —
this is a strict subset of that work (no `changed`/`deleted` arrays to
walk, just `mergedCount`/`groups`).

**Repository** — add a `dedupe()` method to `core/domain/
ContactSyncRepository.h`/`.cpp`, alongside `queueUpdate`/`queueDelete`
(lines 58, 66) and whatever method currently backs `ContactsApp.sync()`
(see below). Same single-purpose rule: it calls the client and returns
a result; the caller triggers the follow-up sync explicitly.

**UI wiring** — `app/qml/pages/ContactsList.qml` already has a `Sync`
`PrimaryButton` (lines 72–79) calling `ContactsApp.sync()`
(`ContactsApp` is `ContactsController` registered as a QML singleton,
`app/contacts/ContactsController.h:12`). Add a `Q_INVOKABLE`/slot
`dedupe()` to `ContactsController` that calls the repository method,
updates the same `statusMessage`/`lastError` properties `sync()` already
uses (so the existing `showSyncStatus` timer/label plumbing in
`ContactsList.qml` lines 28–33, 85–90 works unchanged for this too — no
new UI state needed, just a new trigger and a new message string), and
on success calls `sync()` internally or lets the QML side chain the two
calls — match whichever pattern `ContactsController` already uses when
one action logically implies a follow-up. Add a second `PrimaryButton`
next to "Sync" in `ContactsList.qml`, e.g. text `"Find Duplicates"`,
`enabled: !ContactsApp.isBusy`, `onClicked: ContactsApp.dedupe()`.

**Known limitation.** Same as the other two: no `mergedUIDs`/
`mergedInto`/extended fields on `Contact.h` yet. Otherwise this client
has no field-loss risk on merge — its existing multi-value emails/phones/
addresses will union and display correctly after the follow-up sync.

---

## Verification checklist

- [ ] **Backend (Part 0)**: `POST /api/contacts/dedupe` is callable with
      `sub`/`hash` query params and returns `200` + a `DedupeReport`
      (not `401`). Add a pairing-auth test case to
      `backend/internal/api/contacts_dedupe_test.go`, mirroring
      `server_mail_mobile_test.go`'s pattern for `withMailAuth` (it
      currently only covers session-cookie auth).
- [ ] **Backend**: re-run the existing `dedupe_test.go`/
      `contacts_dedupe_test.go` suite unchanged — Part 0 touches only
      the routing/auth layer, not `dedupe.go` or `store.go`, so no
      existing test should need updating.
- [ ] **Each client**: unit test the new DTO/struct decode, including
      tolerance of a response with `groups: []` (nothing merged).
- [ ] **Each client**: a repository-level test that, given a mocked
      dedupe response followed by a mocked sync pull containing the
      corresponding tombstone + survivor update, ends with the correct
      local state (absorbed contact gone, survivor updated) — extend
      each client's existing sync-repository test file rather than
      writing a new one from scratch (`ContactSyncRepositoryTest.cpp`
      on Linux, the Android equivalent, `ContactSyncTests.swift` on Mac).
- [ ] **Manual, end-to-end, once per client**: create two contacts that
      share an email (via the web UI is easiest), trigger "Find & merge
      duplicates" from the client under test, confirm the report shows
      `mergedCount: 1`, then confirm the duplicate disappears from that
      client's contact list after the follow-up sync.
- [ ] **Manual**: confirm `mergedCount: 0` / "No duplicates found" shows
      correctly when there's nothing to merge (don't just test the
      happy path with guaranteed duplicates).
- [ ] **Manual, Mac only**: after a merge of two contacts with different
      emails, confirm which email survives on the Mac client and
      document it — this is the known single-value-field limitation
      above; the point of this check is to confirm the *actual* behavior
      matches the documented expectation, not to fix it.
