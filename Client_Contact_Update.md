# Extended Contact Fields — Mobile Integration Guide

> Implementation record: this note uses historical repository names and describes its original rollout. For current installation and supported behavior, start with [README.md](README.md); KyPost Server owns the current wire contracts. Completion notes here do not establish present-day live integration coverage.

This document describes how to bring this (separate-repo) mobile app's
contact sync up to date with the extended `Contact` schema just added to
the Llama Labels backend: multiple phones/emails/addresses (already
supported here), plus **groups, a photo, a PGP public key, IM/social
links, websites, relations, extra dates, phonetic names, department,
custom fields, and pronouns**. It mirrors `Mobile_Mail_Relay.md`'s shape —
concrete JSON/Kotlin, a field-by-field mapping table, and a checklist —
written so a fresh Claude session working in this repo can implement
against it with no other context beyond reading the current source files
it points to.

## Summary

The backend's `Contact` struct (`backend/internal/contacts/contacts.go` in
the `llama-labels` repo) grew eleven new fields. **Most of them already
flow through the existing `/api/contacts/sync` endpoint today with zero
backend changes** — `contactPayload` (the shape `/api/contacts`,
`/api/contacts/{id}`, and `/api/contacts/sync` all share) was extended to
include every new field, and `ContactSyncModels.kt`'s `Json { ignoreUnknownKeys
= true }` means the app has been silently receiving and discarding this
data in every sync pull since the backend shipped. Nothing is broken; data
is just not yet captured.

Two things are **not** yet reachable by mobile and need a small backend
change first — see [Part 0](#part-0-prerequisite-backend-gap--fix-in-llama-labels-first).

This app already has a mature two-way contact sync system worth
understanding before touching it:
- **Backend ↔ Room**: `ContactSyncClient` → `ContactSyncRepository` /
  `ContactSyncCoordinator` → `ContactEntity` (Room), keyed by the backend's
  `uid`/`rev`, using `sub`/`hash` pairing auth (no session cookie) —
  exactly like native push pull.
- **Room ↔ Android's native Contacts Provider**: `DeviceContactRepository`
  (raw `ContentProviderOperation` batches against `ContactsContract`),
  `DeviceContactMatcher` (dedupe by email/phone), `DeviceContactConflictResolver`
  + `DeviceContactFieldMerge` (last-write-wins per field, by timestamp),
  wired through a `LlamaContactAuthenticator` sync adapter so this app's
  contacts appear as a proper Android account in Settings → Accounts.

Extending this feature touches **both** halves. Do them in that order —
backend↔Room first (gets data into Room, immediately useful for a future
in-app contact detail screen even before device-sync exists), then
Room↔device (makes the data show up in the phone's native Contacts app,
dialer, Signal/WhatsApp contact picker, etc.).

---

## Field-by-field reference

Backend truth: `backend/internal/contacts/contacts.go` (`Contact` struct)
and `backend/internal/api/contacts_handlers.go` (`contactPayload`) in the
`llama-labels` repo. JSON field names below are exact.

| Field | JSON shape | Android `ContactsContract` mapping | Notes |
|---|---|---|---|
| `groupIDs` | `string[]` (group UUIDs) | `CommonDataKinds.GroupMembership` | Needs a local group-ID↔Android-group-row link table; see [Part 2](#part-2-groups-the-hard-one). |
| `photoRef` | `string \| null` (e.g. `"<sha256>.jpg"`) | `CommonDataKinds.Photo` | Reference only — bytes fetched separately; see [Part 3](#part-3-photo). |
| `pgpKey` | `string \| null` (armored ASCII) | *(none)* | No Android Contacts data kind exists for this. App-only field — see [Part 5](#part-5-fields-with-no-device-mapping-app-only). |
| `ims` | `{service?, label?, value}[]` | `CommonDataKinds.Im` | `service` is one of `whatsapp\|signal\|telegram\|instagram\|x\|linkedin\|facebook\|mastodon\|matrix\|""`(=other, `label` holds the free-text name). None of these have a built-in `Im.PROTOCOL_*` constant — always use `PROTOCOL_CUSTOM` + `CUSTOM_PROTOCOL` = the display label. |
| `websites` | `{label?, value}[]` | `CommonDataKinds.Website` | `label` is freeform (e.g. "homepage"), not a fixed vocabulary. |
| `relations` | `{label?, name}[]` | `CommonDataKinds.Relation` | `label` is one of `spouse\|child\|parent\|partner\|manager\|assistant\|friend\|relative\|other`. Map to the closest `Relation.TYPE_*` constant — **look these up in the current Android SDK docs**, don't guess; fall back to `TYPE_CUSTOM` + `LABEL` for `"other"`. |
| `events` | `{label?, date}[]` (`date` is `YYYY-MM-DD`) | `CommonDataKinds.Event` | `label == "anniversary"` → `Event.TYPE_ANNIVERSARY`; anything else → `Event.TYPE_CUSTOM` + `LABEL`. Birthday is unaffected — it's still the separate `birthday` field mapped to `Event.TYPE_BIRTHDAY`, already implemented. |
| `phoneticGivenName` / `phoneticFamilyName` | `string \| null` | `StructuredName.PHONETIC_GIVEN_NAME` / `PHONETIC_FAMILY_NAME` | The `StructuredName` data row already exists in `DeviceContactRepository`'s insert path (see `CONTENT_ITEM_TYPE` block) — this is just two more columns on a row you're already writing. |
| `department` | `string \| null` | `CommonDataKinds.Organization.DEPARTMENT` | Same story — the `Organization` data row already exists (`COMPANY`/`TITLE`); add `DEPARTMENT` alongside. |
| `customFields` | `{label, value}[]` | *(none, practically)* | Android has no generic "arbitrary label/value" data kind that round-trips cleanly across apps. App-only field — see Part 5. |
| `pronouns` | `string \| null` | *(none)* | No Android Contacts data kind for this (it's an iOS 17+ concept). App-only field — see Part 5. |

---

## Part 0: Prerequisite backend gap — fix in `llama-labels` first

Two of the new backend endpoints are **session-cookie-only** today and
mobile's pairing (`sub`/`hash`) credential cannot call them:

- `GET /api/groups` — needed to resolve a `groupID` to a human-readable name.
- `GET /api/contacts/{id}/photo` — needed to fetch the actual photo bytes
  (mobile already receives `photoRef` for free via `/api/contacts/sync`,
  it just can't fetch the bytes behind it yet).

Both are registered with `s.withAuth(...)` in
`backend/internal/api/server.go` (`llama-labels` repo), which only accepts
a web session cookie — see `withAuth` in `internal/api/server.go`. Compare
to `withMailAuth` / `resolveMailAuthContext` in
`internal/api/server_userscope.go`, which already accepts **either** a
session cookie **or** `sub`/`hash` pairing, exactly the pattern needed
here (it's the same trust boundary `handleContactsSync` itself uses).

**The fix**: add a small `resolveContactsAuthContext` (or generalize
`resolveMailAuthContext` into a shared helper — it already has no
mail-specific logic in it) and switch `GET /api/groups` and
`GET /api/contacts/{id}/photo` (not the POST/DELETE variants — those stay
web-UI-only) to use it. This is a self-contained, low-risk change confined
to `backend/internal/api/` — do it as its own small PR before starting the
Kotlin work below, so the endpoints exist and are testable via `curl -G
--data-urlencode sub=... --data-urlencode hash=...` before any app code
depends on them.

---

## Part 1: Backend ↔ Room (sync DTOs, entity, mappers)

### 1a. `ContactSyncModels.kt`

Add DTOs mirroring the backend types 1:1 (same file as the existing
`ContactFieldDto`/`ContactAddressDto`):

```kotlin
@Serializable
data class ContactImDto(
    val service: String? = null,
    val label: String? = null,
    val value: String = "",
)

@Serializable
data class ContactUrlDto(
    val label: String? = null,
    val value: String = "",
)

@Serializable
data class ContactRelationDto(
    val label: String? = null,
    val name: String = "",
)

@Serializable
data class ContactEventDto(
    val label: String? = null,
    val date: String = "",
)

@Serializable
data class ContactCustomFieldDto(
    val label: String = "",
    val value: String = "",
)
```

Extend `ContactDto` with:

```kotlin
val photoRef: String? = null,
val groupIDs: List<String> = emptyList(),
val pgpKey: String? = null,
val ims: List<ContactImDto> = emptyList(),
val websites: List<ContactUrlDto> = emptyList(),
val relations: List<ContactRelationDto> = emptyList(),
val events: List<ContactEventDto> = emptyList(),
val phoneticGivenName: String? = null,
val phoneticFamilyName: String? = null,
val department: String? = null,
val customFields: List<ContactCustomFieldDto> = emptyList(),
val pronouns: String? = null,
```

(Field names must match the backend JSON exactly — `kotlinx.serialization`
uses the property name by default, same convention already followed by
every existing field here.)

### 1b. `ContactEntity.kt` + Room migration

Follow the file's own documented convention exactly: JSON-string columns
for the new list fields (mirroring `emailsJson`/`phonesJson`/`addressesJson`),
plain nullable columns for scalars:

```kotlin
val photoRef: String? = null,
val groupIDsJson: String = "[]",
val pgpKey: String? = null,
val imsJson: String = "[]",
val websitesJson: String = "[]",
val relationsJson: String = "[]",
val eventsJson: String = "[]",
val phoneticGivenName: String? = null,
val phoneticFamilyName: String? = null,
val department: String? = null,
val customFieldsJson: String = "[]",
val pronouns: String? = null,
```

Bump `AppDatabase.kt`'s `@Database(version = ...)` and add a new
`MIGRATION_3_4` following the exact pattern of the existing
`MIGRATION_2_3` (one `ALTER TABLE contacts ADD COLUMN ...` per new column,
`TEXT` for the JSON/string columns, `DEFAULT '[]'` for the JSON ones,
`DEFAULT NULL` for scalars) — do **not** reach for `fallbackToDestructiveMigration`,
this repo migrates in place.

### 1c. `ContactMappers.kt` and `DeviceContactMappers.kt`

Both files have a `toEntity()`/`toDto()` (or `toDto()`/`toDeviceFieldSet()`)
pair that currently encode/decode `emails`/`phones`/`addresses` through
`mapperJson.encodeToString`/`decodeFromString`. Add the same
encode/decode calls for `ims`/`websites`/`relations`/`events`/`customFields`,
and pass the scalar fields straight through — copy the existing
`emailsJson` lines as the template, there's nothing conceptually new here.

---

## Part 2: Groups (the hard one)

Backend groups (`GET/POST /api/groups`, `PUT/DELETE /api/groups/{id}` —
once Part 0 lands) are **first-class entities** (`{id, name, rev,
createdAt, updatedAt}`), not freeform tags. `Contact.groupIDs` is an array
of backend group IDs. Android's native equivalent is
`ContactsContract.Groups` (one row per group, scoped to this app's sync
account, same `ACCOUNT_TYPE`/`ACCOUNT_NAME` as `DeviceContactAccount`) plus
a `CommonDataKinds.GroupMembership` data row per contact-per-group linking
`RAW_CONTACT_ID` → `GROUP_ROW_ID`.

This needs the same "remote ID ↔ local row ID" bridging problem contacts
themselves already solve with `DeviceContactLinkEntity`. Recommended
approach, mirroring that exact precedent:

1. New Room entity `GroupEntity(id: String, name: String, rev: Long)` — a
   local cache of `GET /api/groups`, refreshed on each sync cycle (small
   list, full-refresh is fine, no delta cursor needed).
2. New Room entity `GroupLinkEntity(groupId: String, androidGroupRowId: Long)`
   — created lazily the first time a group needs to materialize on-device
   (find-or-create an `Groups` row for that account, matching by
   `Groups.TITLE == group.name` first to avoid duplicating a group the
   user already has, same "find-or-create by name" pattern the backend's
   own CardDAV `CATEGORIES` import already uses server-side).
3. When pushing a device-side contact to the backend and it belongs to
   local Android groups not yet known backend-side, either create the
   group via `POST /api/groups` first (needs Part 0) or, cheaper for v1,
   only sync group *membership* one direction (backend → device) and treat
   Android-side group assignment as informational until two-way group
   sync is worth the complexity. State this scoping decision explicitly
   in the PR description if you take the shortcut — don't leave it
   silently half-working.

Renaming: a group rename on the backend is just a new `name` on the same
`id` (`Group.Upsert` bumps `rev`, keeps `id`) — on next sync, update the
matching `Groups` row's `TITLE` in place via the `GroupLinkEntity`, no
need to touch any contact's membership rows.

---

## Part 3: Photo

- `photoRef` already arrives via `/api/contacts/sync` today (part of
  `contactPayload`). Store it as a plain string on `ContactEntity` (Part 1b).
- Fetch actual bytes lazily, only when displaying a contact (avatar in a
  list, contact detail screen) — **do not** try to carry photo bytes
  through the sync payload itself, that was a deliberate backend design
  choice to keep sync payloads small (see `llama-labels`' plan doc in
  its `.claude/plans` history if you want the full rationale).
- Endpoint: `GET /api/contacts/{id}/photo?sub=...&hash=...` (once Part 0
  lands). Cache the bytes locally keyed by `photoRef` (the filename is
  content-hashed server-side, so it's a safe, immutable cache key — no
  need to ever invalidate a cached entry, just add new ones as `photoRef`
  changes).
- Writing the photo onto the device contact:
  `ContactsContract.CommonDataKinds.Photo.PHOTO` accepts raw image bytes
  directly in a `ContentProviderOperation.withValue(..., photoBytes)` —
  follow the exact same `ContentProviderOperation.newInsert(dataUriBase)
  .withValueBackReference(Data.RAW_CONTACT_ID, ...).withValue(Data.MIMETYPE,
  Photo.CONTENT_ITEM_TYPE)...` shape already used for `Email`/`Phone`/etc.
  in `DeviceContactRepository`'s insert batch. This gives a working
  low-res thumbnail everywhere in the OS; treat true full-resolution
  photo support (`RawContacts.DISPLAY_PHOTO_ID` streaming) as a follow-up,
  not a blocker — most contact photos taken from a phone camera or a
  vCard import are already reasonably sized and work fine through `PHOTO`.

---

## Part 4: Device Contacts Provider — write side

`DeviceContactRepository`'s contact-insert batch (the block building
`StructuredName`/`Organization`/`Note`/`Event`/`Email`/`Phone`/`StructuredPostal`
`ContentProviderOperation`s) is the place to add one more
`ContentProviderOperation.newInsert(dataUriBase)...` block per new field,
following the exact same shape as the existing ones — each is: build on
`dataUriBase`, `withValueBackReference(Data.RAW_CONTACT_ID, rawContactUriIndex)`,
`withValue(Data.MIMETYPE, <Kind>.CONTENT_ITEM_TYPE)`, then the kind's own
value columns, guarded by `if (dto.<field>.isNotBlank())` /
`if (dto.<list>.isNotEmpty())` exactly like the existing `org`/`notes`/`birthday`
blocks are guarded.

Concretely, add blocks for:
- `Im` (one per `ims` entry — `PROTOCOL` = `Im.PROTOCOL_CUSTOM`,
  `CUSTOM_PROTOCOL` = the resolved display label — see the field table
  above for the service→label mapping to reuse from the web frontend's
  own `IM_SERVICES` list in `llama-labels/frontend/src/api/contacts.ts`,
  keep the two lists in sync)
- `Website` (one per `websites` entry)
- `Relation` (one per `relations` entry)
- `Event` (one *additional* per `events` entry, alongside the existing
  birthday `Event` row — same MIMETYPE, different `TYPE`/`START_DATE`)
- Extra columns on the **existing** `StructuredName` row: `PHONETIC_GIVEN_NAME`,
  `PHONETIC_FAMILY_NAME`
- Extra column on the **existing** `Organization` row: `DEPARTMENT`
- `Photo` (see Part 3)
- `GroupMembership` (see Part 2)

## Part 4b: Device Contacts Provider — read side

`DeviceContactRepository.readRawContactSnapshot` (and
`DeviceRawContactSnapshot`/`DeviceFieldSet` in `DeviceContactModels.kt`)
is the pull-from-device path — it needs the mirror-image query additions
so a locally-edited IM handle, website, etc. on the phone's native
Contacts app flows back up into Room and then the backend. Extend the
`Data` table projection/query to also read rows where
`MIMETYPE = Im.CONTENT_ITEM_TYPE` (etc.) for the given `RAW_CONTACT_ID`,
same query shape already used to build the current `emails`/`phones`/`addresses`
lists.

## Part 4c: Merge logic

`DeviceContactFieldMerge.kt` has `mergeStringField` (scalar,
timestamp-wins) and `mergeEmailList`/`mergePhoneList`/`mergeAddressList`
(whole-list, timestamp-wins — not a per-item merge). Add:
- `mergeImList`, `mergeWebsiteList`, `mergeRelationList`, `mergeEventList`,
  `mergeCustomFieldList` — copy `mergeEmailList`'s body verbatim, swap the
  type.
- Route `department`, `phoneticGivenName`, `phoneticFamilyName` through
  the existing `mergeStringField` — no new function needed, they're
  scalars just like `org`/`notes`/`birthday` already are.
- `pronouns`/`pgpKey`/`customFields` don't participate in device-merge at
  all if you take the Part 5 recommendation (app-only, Room is the only
  source of truth, no device round-trip to conflict with).

---

## Part 5: Fields with no device mapping (app-only)

`pgpKey`, `pronouns`, and `customFields` have no natural Android
`ContactsContract` data kind. Don't force one (a private `X-`-prefixed
MIMETYPE data row is possible but shows up nowhere in the system UI and
just adds sync-merge surface for no user-visible benefit). Recommendation:
- Store them on `ContactEntity`/`ContactDto` (Part 1) so they round-trip
  correctly through backend sync and are available to any future in-app
  contact detail/edit screen.
- Leave them **out** of `DeviceRawContactSnapshot`/`DeviceFieldSet` and
  every `DeviceContactRepository`/`DeviceContactFieldMerge` function —
  they simply don't participate in the device-contact half of this
  feature. This mirrors how the web frontend itself treats `pgpKey`
  (backend stores it opaquely, no attempt to make it a "real" vCard field
  beyond the base64 `KEY` property, which iOS/Android Contacts apps don't
  render meaningfully anyway).

If a future request wants PGP-key or pronouns visible in the native
Contacts app specifically, that's a separate, explicit ask — don't
speculatively build it now.

---

## Verification checklist

- [ ] Room migration `MIGRATION_3_4` applies cleanly on an existing
      installed DB (test via Room's schema-export + migration test
      harness, same convention as `MIGRATION_2_3`).
- [ ] Pull a contact with every new field set (create one via the web UI
      first, exactly as populated in the `llama-labels` PR that shipped
      this — groups, photo, PGP key, an IM entry, a website, a relation,
      an extra event, phonetic names, department, a custom field,
      pronouns) and confirm every field lands correctly in `ContactEntity`.
- [ ] Push a device-created contact with a new phone-native IM/website/relation
      entry and confirm it round-trips to the backend and back unchanged.
- [ ] Confirm a photo set via the web UI appears as the contact's photo in
      the phone's native Contacts app after a sync + device-write cycle.
- [ ] Confirm deleting a group on the backend removes the corresponding
      `GroupMembership` (or at minimum stops re-adding it) rather than
      leaving an orphaned Android group.
- [ ] Confirm `pgpKey`/`pronouns`/`customFields` survive a full
      pull→Room→push round trip even though they never touch the device
      Contacts Provider (Room is the only place they live on-device).
