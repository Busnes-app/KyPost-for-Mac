# Answering invitations through KyCalendar

The Mac/iOS client's copy of the contract it implements, and the durable one
for this repo. Sources: Ky Suite integrations wave 1 contract section F
(third bullet), KyPost-Server `docs/NATIVE-RSVP.md` and `docs/KYCALENDAR.md`
"Respond", and the web card (`frontend/src/pages/read/invite.ts`,
`InviteCard.tsx`, KyPost-Server #606). Code: `Domain/Calendar/`,
`InviteCardModel`, `RelayMailSource.answerThroughKyCalendar`.

## When answers are offered

All of these hold, else the card shows no Accept, Maybe or Decline:

- `GET /api/mail/attachments` lists the part with `mimeType` `text/calendar`
  and `calendarMethod` `REQUEST`. Its `index` is kept.
- The part (1 byte to 256 KiB) parses as one VCALENDAR with `METHOD:REQUEST`
  and a series master VEVENT with a UID, a `mailto:` ORGANIZER and a readable
  SEQUENCE.
- A `METHOD:CANCEL` part shows "Cancelled" and never offers answers, Add to
  Calendar or Join.

## 1. KyCalendar first

```
POST /api/calendar/rsvp
X-Kypost-Device-Id / X-Kypost-Device-Secret     (no cookie, so no CSRF)
Content-Type: application/json

{"messageId":"<exact, incl. n1:…>","mailbox":"<folder, \"\" = INBOX>","index":<n>,"partstat":"ACCEPTED|TENTATIVE|DECLINED"}
```

No `X-KyPost-Mailbox` (this client answers for the primary mailbox only), no
`recurrenceId` (always the series master), never ics. Sent at the tap, before
any confirmation: nothing leaves as mail here.

| Answer | Card does |
|---|---|
| 200 `{"outcome":"answered"}` | "Answered through KyCalendar." No mail. Revision done. |
| 200, any other body | "KyCalendar did not confirm the answer; try again." Buttons re-armed. No mail. |
| 409 `kycalendar_off` | Mail fallback (2), after the confirmation. |
| 404 `no_event` | Mail fallback (2), after the confirmation. |
| 409 `conflict` | "The event changed since this invitation…", a Reload invitation button. No mail. |
| anything else, or a network error | The server's `error` text (controls and format characters stripped, ≤ 300), else "KyCalendar could not be reached; try again." Buttons re-armed. No mail. |

A fallback code counts only on its documented status, and the code must be
`[a-z0-9_]{1,64}`.

## 2. Mail fallback

The existing iTIP REPLY on `POST /api/mail/send` (`calendarReply`), unchanged:
always unencrypted and unsigned, and confirmed first. The confirmation starts
"KyCalendar has no event for this invitation" (`no_event`) or "KyCalendar is
not in use for this mailbox" (`kycalendar_off`), then ", so your answer goes
to <organizer> as an unencrypted, unsigned email." Only `"calendarReply":
true` is an RSVP; every 4xx and a 503 are refusals that re-arm the buttons;
other 5xx and network errors may have been sent.

## Card states (KyPost-Server #606)

- **Update to an answered invitation.** `RsvpTracker` remembers the answered
  revision per organizer + UID as SHA-256 digests of time, place and title.
  A REQUEST with a higher SEQUENCE, or the same SEQUENCE and a later DTSTAMP,
  says "Changed since you answered: …. You had accepted; answer again." and
  offers the buttons. The same revision says "You accepted."
- **Cancelled.** "Cancelled" under the title; no answer buttons, no Add, no
  Join.
- **Join meeting.** The first `CONFERENCE` property, only as `https:` with a
  host, no credentials, printable ASCII, ≤ 2048 bytes. "Join meeting (<host>)"
  opens it with the system's URL handler (the default browser). Any other
  scheme or shape is ignored.

## Deviation from the web client

The answered-revision memory is **in memory only** and dropped on
`.kyPostSessionReset` (wipe, failed-unlock reset, unpair) and at quit; the web
client keeps it in localStorage. A persisted copy would be one more store for
Hostile Location Protection and the wipe to erase, for an optional feature.
After a relaunch, an update to an answered invitation shows the existing
"This invite was updated" notice instead of the change list.
