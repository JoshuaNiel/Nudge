# Social Layer

Design for friend contacts and SMS-based accountability nudges.

---

## Overview

Friends do not need to have the Nudge app. The app user stores a friend's name and phone number. When a usage threshold is hit, Nudge texts the friend via SMS with a prompt. The friend replies by text, and that reply is delivered back to the app user as both a push notification and an SMS.

---

## Data Model

### `friend`
Stores the app user's contacts. No Supabase account required for the friend.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) — the app user who added this contact |
| friendName | varchar | Display name |
| friendPhoneNumber | varchar | E.164 format (`+18015551234`) |
| status | enum | `pending`, `accepted`, `blocked` |
| invitationTimestamp | timestamptz | UTC — when the consent SMS was sent |

**On `status`:**
- `pending` — consent SMS has been sent, awaiting reply
- `accepted` — friend replied yes; nudges can be sent
- `blocked` — friend sent Twilio STOP; row is kept permanently, no nudges are sent

**On rejection:** If the friend replies no, a notification is sent to the app user and the row is deleted. `blocked` is reserved exclusively for Twilio STOP opt-outs where regulations require honoring the request permanently.

### `nudge`
Tracks each SMS nudge sent to a friend and their reply.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| friendId | bigint | FK → friend(id) |
| prompt | varchar | The message options sent to the friend |
| friendReply | varchar | The friend's reply text (populated by webhook) |
| type | enum | `shame`, `encouragement`, `custom` |
| status | enum | `sent_to_friend`, `replied`, `reply_delivered`, `failed` |
| sentTimestamp | timestamptz | UTC — when the nudge was sent |

**Note:** The app user is derivable via `friend.userId` — no separate `receiverId` column needed on `nudge`.

### `profiles.phoneNumber`
The app user's own phone number, stored so they can also receive the friend's reply as an SMS (in addition to a push notification).

---

## Friend Consent Flow

Before nudges can be sent, the friend must consent via SMS.

```
1. App user adds a friend (name + phone number)
         ↓
2. App inserts friend row with status = pending, timestamp = now
         ↓
3. send-consent Edge Function sends SMS to friend:
   "Hey, [User] wants to add you as an accountability buddy on Nudge.
    Reply YES to allow or NO to decline."
         ↓
4. Friend replies
         ↓
5. receive-reply Edge Function (inbound webhook) routes the reply:
   — Finds pending friend row for this phone number
   — YES → status = accepted
   — NO  → notify app user, delete friend row
   — STOP → status = blocked (permanent, per Twilio regulations)
```

---

## SMS Nudge Flow

Only runs for friends with `status = accepted`.

```
1. App user's usage threshold is hit
         ↓
2. App triggers a nudge (inserts nudge row with status = sent_to_friend)
         ↓
3. send-nudge Edge Function sends SMS to friend via Twilio
   — Message includes the prompt and reply options (1, 2, or custom)
         ↓
4. Friend replies by text
         ↓
5. receive-reply Edge Function (inbound webhook) routes the reply:
   — No pending friend row for this number → treat as nudge reply
   — A phone number may appear in multiple users' friend lists; the reply goes
     to the most recent sent_to_friend nudge across all matching friend rows
   — Updates nudge.friendReply and nudge.status = replied
         ↓
6. Edge Function delivers reply to app user:
   a. APNs push notification (if app is installed and notifications enabled)
   b. SMS to profiles.phoneNumber
   — Updates nudge.status = reply_delivered
```

---

## Inbound Reply Routing

The `receive-reply` Edge Function handles all inbound SMS and routes based on the sender's phone number:

1. Look up all `friend` rows matching `friendPhoneNumber` (a phone number may appear across multiple users' friend lists)
2. If any matching row has `friend.status = pending` → this is a consent reply → handle as friend request response for that user
3. Otherwise → this is a nudge reply → find the single most recent `nudge` with `status = sent_to_friend` across all matching friend rows; that nudge's owner receives the reply

This keeps routing unambiguous: a phone number can't have a pending consent and an active nudge at the same time (nudges are only sent to accepted friends). In the multi-user case, the most recent outstanding nudge wins.

---

## SMS Provider

**Twilio** is the recommended provider.

> TODO: Set up Twilio account and document:
> - The Twilio phone number used for outbound SMS
> - The webhook URL for inbound replies (points to the Supabase Edge Function)
> - How Twilio credentials are stored (Supabase secrets, not in code)

---

## Edge Functions Needed

| Function | Trigger | Purpose |
|---|---|---|
| `send-consent` | DB webhook on friend insert (status = pending) | Sends consent SMS to friend via Twilio |
| `send-nudge` | DB webhook on nudge insert (status = sent_to_friend) | Sends nudge SMS to friend via Twilio |
| `receive-reply` | Twilio inbound webhook | Routes reply — consent or nudge — updates status, delivers to app user |

> TODO: Design and implement all three Edge Functions before Phase 6.

---

## Phone Number Handling

- Store all phone numbers in E.164 format: `+18015551234`
- Validate format on input in the app before saving
- `profiles.phoneNumber` is nullable — users who don't want SMS delivery of replies don't need to provide it. Push notification is always the primary delivery mechanism.

---

## Privacy Considerations

- Friend phone numbers are stored in Supabase and used only for outbound nudges
- The friend is informed via the SMS message itself what the app is and who is sending it
- App user's phone number is used only for reply delivery, never shared with friends

> TODO: Write the SMS message copy carefully — it must be clear to the friend what they're responding to and who the sender is, to avoid being flagged as spam.

---

## Open Questions

> TODO: Answer before Phase 6 (Social Layer):
> - Twilio account setup and number provisioning
> - Rate limiting — how many nudges can be sent to a friend per day to avoid spam?
> - What happens if a friend replies after a long delay (nudge is already `delivered_to_user`)?
> - Should the app user be able to customize the prompt options sent to the friend?
> - Opt-out mechanism — what if the friend texts "STOP"? Twilio handles this automatically but it needs to be handled gracefully in the app.
