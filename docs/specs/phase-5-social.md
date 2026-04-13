# Phase 5 — Social (Friends + SMS Nudges)

**Status:** `[ ] Not started`

**Goal:** Let users add friends (by phone number), get consent via SMS, and send accountability nudges when usage thresholds are hit. Replies are delivered back to the app user via push notification and SMS.

---

## Prerequisites

- [x] Auth complete
- [x] DB schema deployed (`friend`, `nudge` tables, RLS, column-level grants)
- [ ] Twilio account set up — phone number provisioned, credentials stored as Supabase secrets
- [ ] Phase 1 complete (usage thresholds trigger nudges)
- [ ] APNs configured (token-based auth with .p8 key uploaded to Supabase)

---

## Tasks

### Models
- [ ] Add `Friend` model:
  ```swift
  struct Friend: Codable, Identifiable {
      let id: Int
      let userId: UUID              // user_id
      let friendName: String        // friend_name
      let friendPhoneNumber: String // friend_phone_number (E.164)
      let status: FriendStatus
      let invitationTimestamp: Date // invitation_timestamp
  }
  
  enum FriendStatus: String, Codable { case pending, accepted, blocked }
  ```

- [ ] Add `Nudge` model:
  ```swift
  struct Nudge: Codable, Identifiable {
      let id: Int
      let friendId: Int       // friend_id
      let prompt: String
      let friendReply: String?  // friend_reply
      let type: NudgeType
      let status: NudgeStatus
      let sentTimestamp: Date   // sent_timestamp
  }
  
  enum NudgeType: String, Codable { case shame, encouragement, custom }
  enum NudgeStatus: String, Codable {
      case sentToFriend = "sent_to_friend"
      case replied
      case replyDelivered = "reply_delivered"
      case failed
  }
  ```

### Service Layer
- [ ] Create `FriendService`:
  ```swift
  class FriendService {
      func fetchFriends(userId: UUID) async throws -> [Friend]
      func addFriend(userId: UUID, name: String, phoneNumber: String) async throws
      func deleteFriend(id: Int) async throws
      func updateFriendName(id: Int, name: String) async throws
      func fetchNudgeHistory(friendId: Int) async throws -> [Nudge]
  }
  ```
  **Note:** `addFriend` inserts a row with `status = pending`. The DB trigger enforces this. The `send-consent` Edge Function fires automatically via a DB webhook on insert.

- [ ] Create `NudgeService`:
  ```swift
  class NudgeService {
      // Triggers nudge by calling the send-nudge Edge Function
      // (client does NOT insert directly into nudge table — no insert RLS policy)
      func sendNudge(friendId: Int, type: NudgeType, prompt: String) async throws
  }
  ```

### Social UI
- [ ] Replace `SocialView` stub:
  - Accepted friends list — name, "Nudge" button per friend
  - Pending friends section — name, phone, "waiting for consent" label
  - Blocked friends hidden (don't surface in UI)
  - "Add Friend" button → sheet

- [ ] Add friend sheet:
  - Name field + phone number field (E.164 validation on input: must start with `+`, digits only after)
  - Submit → `FriendService.addFriend` → shows "Consent request sent" confirmation
  - Error handling: duplicate phone number (`unique (user_id, friend_phone_number)`)

- [ ] Nudge sheet (opens from "Nudge" button on accepted friend):
  - Select nudge type: Shame / Encouragement / Custom
  - Pre-filled prompt text (editable for Custom)
  - Send → `NudgeService.sendNudge`

- [ ] Nudge history view (per friend):
  - List of past nudges with status, timestamp, friend's reply (if any)

- [ ] Real-time updates via Supabase Realtime:
  - Subscribe to `nudge` table changes for the current user's friends
  - When a nudge status changes to `replied`, update the UI automatically

### APNs — Push Notification for Reply Delivery
- [ ] Enable Push Notifications capability on main app target in Xcode
- [ ] Register for remote notifications in `NudgeApp.swift`:
  ```swift
  UIApplication.shared.registerForRemoteNotifications()
  ```
- [ ] Implement `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` in `AppDelegate` or via SwiftUI lifecycle
- [ ] Store device token in Supabase:
  ```swift
  // Upsert into a device_tokens table: (user_id, token, platform = 'apns', updated_at)
  ```
  **Decision needed:** Use a separate `device_tokens` table (supports multiple devices per user) vs. a single column on `profile`. **Recommendation:** Separate table.
- [ ] Handle incoming push payload — deep-link to nudge history

### Supabase Edge Functions
- [ ] `send-consent` — triggered by DB webhook on `friend` insert (status = pending)
  - Sends SMS via Twilio: "Hey, [User First Name] wants to add you as an accountability buddy on Nudge. Reply YES to allow or NO to decline."
  - Twilio credentials read from Supabase secrets

- [ ] `receive-reply` — triggered by Twilio inbound webhook (POST from Twilio)
  - Validates Twilio signature
  - Looks up `friend` rows matching `friend_phone_number`
  - Routes: if any row has `status = pending` → consent reply; otherwise → nudge reply
  - Consent YES: updates `friend.status = accepted` via service role
  - Consent NO: notifies app user, deletes `friend` row via service role
  - Consent STOP: updates `friend.status = blocked` via service role
  - Nudge reply: updates `nudge.friend_reply` + `status = replied`, then sends APNs push + SMS to app user

- [ ] `send-nudge` — triggered by client calling Edge Function directly (not by DB webhook, since client can't insert nudges)
  - Validates `friend.status = accepted`
  - Inserts `nudge` row via service role
  - Sends SMS to friend via Twilio

### SMS Message Copy
- [ ] Write and finalize the consent SMS copy before launch
  - Must clearly state: who is sending it (the app user's name), what the app is (Nudge), and what the friend is consenting to
  - Must include clear YES/NO reply instructions
  - Proposed template: "Hey, [First Name] wants to add you as an accountability buddy on Nudge, a screen time app. Reply YES to allow nudges or NO to decline."
  - **Important:** Poorly worded copy gets flagged as spam by carriers. Test with Twilio's message feedback tools before shipping.

### User Phone Number (for SMS reply delivery)
- [ ] Add phone number field in Settings → Profile
- [ ] Validate E.164 format on input
- [ ] Save to `profile.phone_number` via `AuthService.updateProfile` (extend to include phone)
- [ ] Show note: "Used only to receive your friend's replies as a text message"

---

## Data Contracts

### Supabase — fetch friends
```swift
supabase
    .from("friend")
    .select()
    .eq("user_id", value: userId)
    .neq("status", value: "blocked")  // hide blocked from UI
    .order("invitation_timestamp", ascending: false)
    .execute()
```

### Supabase — insert friend
```swift
supabase
    .from("friend")
    .insert([
        "user_id": userId,
        "friend_name": name,
        "friend_phone_number": phoneNumber
        // status defaults to "pending" in DB; trigger enforces this
    ])
    .execute()
```

### Edge Function — send-nudge invocation
```swift
// Client calls the Edge Function directly (not a DB insert)
supabase.functions.invoke(
    "send-nudge",
    options: .init(body: ["friend_id": friendId, "type": type.rawValue, "prompt": prompt])
)
```

### Realtime subscription
```swift
// Subscribe to nudge changes for the current user's friends
supabase.realtime.channel("nudges")
    .on(.postgresChanges, filter: .init(event: .update, schema: "public", table: "nudge")) { payload in
        // refresh nudge list
    }
    .subscribe()
```

### `device_tokens` table (to be added to schema)
```sql
create table public.device_tokens (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  token      text not null,
  platform   text not null default 'apns',
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);
-- RLS: users can manage their own tokens
```

---

## Open Questions

> **Must be resolved before implementation begins.**

1. **Twilio setup:** Account, phone number, and webhook URL must be provisioned. Credentials stored as Supabase secrets (`TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_PHONE_NUMBER`).

2. **APNs token storage:** Separate `device_tokens` table (recommended, supports multiple devices) vs. single column on `profile`. Decide before building.

3. **Rate limiting:** How many nudges can be sent to the same friend per day? Prevent spam. Suggest: max 3 nudges per friend per day, enforced in `send-nudge` Edge Function.

4. **Late reply handling:** What if a friend replies after the nudge is already `reply_delivered`? Log it anyway or ignore? Decide before `receive-reply` implementation.

5. **Custom prompt options:** Should the app user be able to customize the reply options sent to the friend (e.g. "1. Keep going! 2. Take a break")? Defer to post-launch if needed.

---

## Acceptance Criteria

- [ ] User can add a friend by name + phone number; consent SMS is sent automatically
- [ ] Friend list shows accepted, pending, and hides blocked
- [ ] Accepted friend receives a nudge SMS when user taps "Nudge"
- [ ] App user receives a push notification when friend replies
- [ ] App user receives an SMS reply if phone number is set in profile
- [ ] Nudge history shows all past nudges and replies per friend
- [ ] Blocking (STOP) is handled — blocked friends cannot receive further nudges
- [ ] Phone number input validates E.164 format before saving
- [ ] Duplicate phone number in the same user's friend list is rejected with an error
