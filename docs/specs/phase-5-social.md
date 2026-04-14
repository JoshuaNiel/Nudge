# Phase 5 — Social (Friends + SMS Nudges)

**Status:** `[~] In Progress`

**Goal:** Let users add friends (by phone number), get consent via SMS, and automatically send accountability nudges when usage thresholds are hit, goals are broken, or daily reports fire. Friends reply via SMS; replies are delivered back to the app user via push notification and optional SMS.

---

## Key Design Decisions

### Nudges Are Automatic — Not User-Initiated

**This is the most important thing to understand about this feature.**

The app automatically detects when a nudge should be sent (the user has been on their phone too long, broke a goal, or it's time for a daily report) and sends the nudge to a friend without the user choosing to send it. There is **no "Send Nudge" button**. The user configures nudge triggers in Settings; from there it's automatic.

The friend receives an SMS explaining the situation and is given reply options:
- Reply `1` → send a pre-canned encouragement message to the app user
- Reply `2` → send a pre-canned shame/reality-check message
- Reply with any other text → that text is delivered as a custom message

**NudgeType is not known at send time** — it is `null` when the nudge row is inserted and is set only when the friend replies. A `NudgeType` value represents the *friend's chosen response*, not a request the user initiated.

### Friends Are Phone Numbers

Friends do not need the Nudge app or a Supabase account. They are stored by name and phone number. Consent is obtained via SMS before any nudges are sent.

---

## Prerequisites

- [x] Auth complete
- [x] DB schema deployed (`friend`, `nudge` tables, RLS, column-level grants)
- [x] `device_tokens` table deployed (migration `001_device_tokens.sql`)
- [x] `nudge.type` made nullable (migration `002_nudge_type_nullable.sql`)
- [x] Twilio account set up — trial mode with verified numbers; credentials stored as **Edge Function secrets** (not Vault): `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_MESSAGING_SERVICE_SID`. SMS is sent via Messaging Service SID (`MessagingServiceSid`), not a direct phone number (`From`).
- [x] APNs configured — token-based auth (.p8 key); secrets stored as **Edge Function secrets** (not Vault): `APNS_PRIVATE_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_SANDBOX`

---

## Phase 5 Task Breakdown

### 5A — Models `[x] Done`

- [x] `FriendStatus` enum: `pending`, `accepted`, `blocked`
- [x] `NudgeType` enum: `shame`, `encouragement`, `custom`
- [x] `NudgeStatus` enum: `sentToFriend`, `replied`, `replyDelivered`, `failed`
- [x] `Friend` model — explicit CodingKeys, all fields
- [x] `FriendInsert` struct — Encodable, snake_case CodingKeys
- [x] `Nudge` model — `type: NudgeType?` (nullable until friend replies), explicit CodingKeys
- [x] All model tests written in `NudgeTests/SocialTests.swift`

**Critical detail — NudgeType is nullable:**
```swift
struct Nudge: Codable, Identifiable {
    let id: Int
    let friendId: Int
    let prompt: String
    let friendReply: String?   // nil until friend replies
    let type: NudgeType?       // nil at insert; set when friend replies (1→encouragement, 2→shame, other→custom)
    let status: NudgeStatus
    let sentTimestamp: Date
}
```

### 5B — Service Layer `[x] Done`

- [x] `FriendServiceProtocol` + `FriendService` (fetch, add, delete, update name, fetch nudge history)
- [x] `NudgeServiceProtocol` + `NudgeService` (send nudge — calls Edge Function)

**NudgeService contract:**
```swift
protocol NudgeServiceProtocol {
    func sendNudge(friendId: Int, report: String) async throws
}
```

The `report` parameter is a human-readable description the app generates describing the user's situation (e.g., "Josh has been on his phone for 2 hours today"). The Edge Function builds the full SMS (report + reply options) and sets `type = null` at insert. **There is no `type` or `prompt` parameter** — the type is determined by the friend's reply.

### 5C — Social UI `[x] Done`

- [x] `SocialViewModel` with two inits (production no-arg, test injection via protocol)
- [x] `SocialView` — friends list, pending section, empty state, error state
- [x] `AcceptedFriendRow` — name + phone, NavigationLink to NudgeHistoryView
- [x] `PendingFriendRow` — name + phone + "Awaiting consent" badge
- [x] `AddFriendSheet` — name + E.164 phone number, validation regex `^\+[1-9]\d{7,14}$`
- [x] `NudgeHistoryView` — per-friend list of past nudges
- [x] `NudgeHistoryRow` — shows prompt, `type?.displayName ?? "Awaiting reply"`, friend's reply, status badge

**What is NOT in the UI:**
- No "Nudge" button per friend — nudges are sent automatically by the trigger system (see Phase 5E)
- No nudge compose sheet — users do not write nudge content

### 5D — Supabase Edge Functions `[x] Done`

All three Edge Functions are written and deployed.

#### `send-consent`
- Triggered by a **DB Webhook on INSERT to `public.friend`**
- Fires only when `status = pending` (other statuses ignored)
- Looks up app user's first name from `profile` (non-fatal — falls back to "Someone")
- Sends consent SMS: "Hey, [Name] wants your help being more accountable with their screen time. Can we send you updates on their progress? Reply yes or no. You can opt out at any time"
- **Setup:** Supabase Dashboard → Database → Webhooks → Create. Table: `public.friend`. Event: INSERT. Method: **Edge Function** (not HTTP Request) → select `send-consent`. The Edge Function type handles auth automatically — no `Authorization` header needed.

#### `send-nudge`
- Called by the iOS app automatically when a nudge trigger fires (never user-initiated)
- Authenticates the app user via JWT
- Validates friend exists and has `status = accepted` (404 vs 403 — separate errors)
- Rate limits: max **10 nudges per friend per day**, calculated in the **user's local timezone** (from `profile.time_zone`)
- Payload: `{ friend_id: Int, report: String }`
- Builds full SMS: `report + "\n\nReply 1 to send encouragement 💪\nReply 2 to give them a reality check 📵\nOr reply with your own message"`
- Inserts nudge row with `type = null` (nullable column), `status = sent_to_friend`
- Marks nudge `failed` if SMS throws
- Returns `{ nudge_id: Int }`

#### `receive-reply`
- **Twilio inbound webhook** — configure in Twilio Console → Phone Numbers → Messaging → "A message comes in" → POST → this function's URL (`https://<project-ref>.supabase.co/functions/v1/receive-reply`)
- **Deployed with `--no-verify-jwt`** — Twilio webhooks don't carry a Supabase JWT. Security is handled by Twilio HMAC-SHA1 signature validation instead.
- **URL reconstruction for signature validation:** Supabase's proxy delivers requests with `http://` scheme and strips the `/functions/v1` path prefix, so `req.url` does not match the URL Twilio signed. The function reconstructs the correct URL using `x-forwarded-proto` (scheme) + host from `req.url` (correct) + `/functions/v1` prepended to the path. `validateTwilioSignature` accepts an optional explicit URL for this purpose.
- Validates Twilio HMAC-SHA1 signature on every request (no bypass)
- Routing:
  1. If sender has any **pending** friend rows → consent reply (applies to all pending rows for that phone)
  2. Otherwise if sender has accepted rows → nudge reply (goes to single most recent open nudge)
- **Consent YES:** sets all pending rows to `accepted`; sends thank-you SMS with app user's first name and STOP reminder
- **Consent NO:** deletes pending rows; sends reassurance SMS ("No worries! Your number has been removed...")
- **STOP keyword:** sets all rows (pending + accepted) to `blocked`; **no confirmation SMS** (Twilio handles the regulatory acknowledgment automatically at the carrier level)
- **Nudge reply:** finds the single most recent nudge with `status = sent_to_friend` across all friends with that phone number (not all users — one user's nudge gets the reply). Resolves: `1` → encouragement (pre-canned), `2` → shame (pre-canned), anything else → custom. Updates `nudge.type`, `nudge.friend_reply`, `status = replied`. Delivers APNs push + optional SMS to app user. Updates `status = reply_delivered`.

**Pre-canned messages:**
- Encouragement: "You're stronger than the algorithm! I believe in you, now get off your phone and go do something that will make you happy!"
- Shame: "4 hours a day is 25% of your waking hours. Do you really want to waste another day of your life accomplishing nothing?"

### 5E — Nudge Trigger System `[ ] Not started` ⚠️ SPEC INCOMPLETE

**This is the system that actually decides when to send nudges automatically. It is the core of the social feature and needs a full spec before implementation.**

The app should send nudges to the user's friends (those with `status = accepted`) when any of the following triggers fire. Users can configure which triggers are active in Settings.

#### Trigger Types

| Trigger | Description | Default |
|---|---|---|
| Time-on-phone | User has been on their phone continuously for N minutes | On (60 min) |
| Daily total | User's total screen time for the day exceeds N hours | Off |
| Goal breached | User exceeded a specific goal's limit | Off |
| Daily report | Send a daily usage summary to friends at a set time | Off |

#### Open Questions — Must Resolve Before Building

1. **How does the iOS app detect continuous phone usage?** DeviceActivity's `DeviceActivityMonitor` extension fires when thresholds are hit, but this requires Phase 1 (Family Controls entitlement). Until Phase 1 is complete, nudge triggers cannot be implemented.

2. **Which friends get nudges?** Does every `accepted` friend get every nudge? Or does the user configure which friends receive which types of nudges? (Simpler: all accepted friends get all triggers; more powerful: per-trigger friend selection.)

3. **What is the `report` string?** Define exactly what text the app generates for each trigger type. Example formats:
   - Time-on-phone: "[Name] has been on their phone for [N] hours straight. Maybe check in on them?"
   - Goal breached: "[Name] exceeded their [App/Category] goal today ([actual] vs [limit])."
   - Daily report: "[Name]'s screen time today: [total]. Goal status: [met/missed]."

4. **How does the trigger read screen time without Phase 1?** The trigger system depends on DeviceActivity data. This entire subsystem is effectively blocked until Family Controls approval.

5. **Concurrency:** If multiple triggers fire simultaneously (e.g., continuous-time + goal breach), is one nudge sent or multiple?

#### Architecture Decision Needed

The trigger system needs to run even when the app is in the background or not running. Options:
- **DeviceActivityMonitor extension** (preferred) — fires callbacks when thresholds are hit. Calls `send-nudge` Edge Function from within the extension. Requires Phase 1.
- **Background app refresh** — less reliable, iOS throttles it heavily. Not recommended.

**This phase is blocked until Phase 1 (Family Controls entitlement) is approved.**

#### Settings UI for Nudge Triggers

- Toggle: Enable time-on-phone nudges (default on); threshold picker (30 / 60 / 90 / 120 min)
- Toggle: Enable daily total nudges; threshold picker (hours)
- Toggle: Enable goal-breach nudges
- Toggle: Enable daily report; time picker
- (Future) Per-friend trigger configuration

### 5F — APNs iOS Registration `[ ] Not started`

Required before push notifications work end-to-end.

- [ ] Enable **Push Notifications** capability on main app target in Xcode (Signing & Capabilities → + Capability → Push Notifications)
- [ ] In `NudgeApp.swift`, request permission and register:
  ```swift
  UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else { return }
      DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
      }
  }
  ```
- [ ] Create `DeviceTokenService` to store token in Supabase:
  ```swift
  protocol DeviceTokenServiceProtocol {
      func registerToken(_ token: Data, userId: UUID) async throws
  }

  @MainActor
  class DeviceTokenService: DeviceTokenServiceProtocol {
      func registerToken(_ token: Data, userId: UUID) async throws {
          let tokenString = token.map { String(format: "%02x", $0) }.joined()
          try await supabase.from("device_tokens")
              .upsert(["user_id": userId, "token": tokenString, "platform": "apns"])
              .execute()
      }
  }
  ```
- [ ] Handle `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` — call `DeviceTokenService.registerToken`
- [ ] Handle incoming push payload — deep-link to `NudgeHistoryView` for the relevant friend
  - Payload shape: `{ nudge_id: Int }` (set by `receive-reply` in `sendApnsPush`)

### 5G — User Phone Number in Settings `[ ] Not started`

The app user can optionally add their own phone number so they receive the friend's reply as an SMS (in addition to the APNs push).

- [ ] Add phone number field to Settings → Profile section
- [ ] Validate E.164 on input
- [ ] Save to `profile.phone_number` via `AuthService.updateProfile`
- [ ] Display note: "Used only to receive your friend's replies as a text message. You can opt out at any time."

---

## Data Contracts

### Edge Function — send-nudge invocation
```swift
// Called by the iOS app when a trigger fires — NOT user-initiated
try await supabase.functions.invoke(
    "send-nudge",
    options: .init(body: [
        "friend_id": friendId,
        "report": reportString   // generated by the app based on trigger type
    ])
)
```

### Supabase — fetch friends
```swift
supabase
    .from("friend")
    .select()
    .eq("user_id", value: userId)
    .neq("status", value: "blocked")
    .order("invitation_timestamp", ascending: false)
    .execute()
    .value as [Friend]
```

### Supabase — insert friend (triggers send-consent automatically)
```swift
try await supabase
    .from("friend")
    .insert(FriendInsert(userId: userId, friendName: name, friendPhoneNumber: phoneNumber))
    .execute()
```

### Supabase — fetch nudge history
```swift
supabase
    .from("nudge")
    .select()
    .eq("friend_id", value: friendId)
    .order("sent_timestamp", ascending: false)
    .execute()
    .value as [Nudge]
```

### `device_tokens` table (deployed via migration `001_device_tokens.sql`)
```sql
create table public.device_tokens (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  token      text not null,
  platform   text not null default 'apns',
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);
alter table public.device_tokens enable row level security;
-- Users can manage their own tokens
create policy "users manage own device tokens"
  on public.device_tokens for all
  using (auth.uid() = user_id);
```

---

## Open Questions (Resolved)

| Question | Resolution |
|---|---|
| Twilio account setup | Trial mode — only verified numbers receive SMS. Upgrade when ready for production. |
| APNs token storage | Separate `device_tokens` table. Supports multiple devices per user. Deployed. |
| Rate limiting | Max 10 nudges per friend per day. Calculated in user's local timezone from `profile.time_zone`. |
| Late reply handling | `receive-reply` does not check nudge status before updating — late replies update the nudge normally. |
| NudgeType at send time | NULL — type is set by the friend's reply (`1`→encouragement, `2`→shame, other→custom). |
| STOP confirmation SMS | None — Twilio handles the regulatory acknowledgment at the carrier level. Do not send a custom confirmation. |
| APNs delivery method | Direct HTTP/2 calls from Edge Function using token-based auth (.p8 key + ES256 JWT). No Supabase dashboard push required. |
| Where is Deno LS configured | `.vscode/settings.json` at repo root, `deno.enablePaths: ["supabase/functions"]`. IDE-only — no effect on Supabase deployment. |
| Twilio secrets location | Edge Function secrets (`supabase secrets set`), not Supabase Vault. Vault is for DB-layer secrets; `Deno.env.get()` reads Edge Function secrets only. |
| SMS sender identity | Twilio Messaging Service SID (`MessagingServiceSid` param), not a direct phone number (`From`). Enables number pooling and better deliverability. |
| `receive-reply` JWT verification | Disabled (`--no-verify-jwt`) — Twilio can't send a Supabase JWT. Twilio HMAC-SHA1 signature validation is the auth mechanism instead. |
| Twilio signature validation URL | Reconstructed from `x-forwarded-proto` + host from `req.url` + `/functions/v1` prefix — not `req.url` directly, which has wrong scheme and stripped prefix behind Supabase's proxy. |

## Open Questions (Still Unresolved)

| Question | Needed By |
|---|---|
| Nudge trigger architecture — which DeviceActivity callbacks to use | Phase 5E |
| Which friends receive which trigger types | Phase 5E |
| Report string format per trigger type | Phase 5E |
| Per-friend trigger configuration vs all-friends | Phase 5E |
| Concurrency — multiple triggers at once | Phase 5E |

---

## Acceptance Criteria

### Done
- [x] User can add a friend by name + E.164 phone number; consent SMS is sent automatically
- [x] Friend list shows accepted and pending sections; blocked friends are hidden
- [x] Tapping an accepted friend shows nudge history
- [x] Nudge history shows prompt, type, friend's reply, and status
- [x] App user receives APNs push when friend replies
- [x] App user receives SMS if phone number is set in profile
- [x] Blocking (STOP) is handled — blocked friends cannot receive further nudges
- [x] Friend can reply YES (accept) or NO (decline) to consent request
- [x] Consent YES sends a personalised thank-you SMS to the friend with STOP reminder
- [x] Consent NO deletes the row and sends a reassurance SMS
- [x] Rate limit: max 10 nudges per friend per local day

### Still Needed
- [ ] APNs push registered on device; token stored in `device_tokens` table
- [ ] Incoming push deep-links to NudgeHistoryView for the relevant friend
- [ ] App user's phone number field in Settings
- [ ] Nudge trigger system implemented (blocked on Phase 1 / Family Controls entitlement)
- [ ] Nudge trigger settings UI (threshold configuration)
- [ ] Real-time nudge status update in UI when `replied` / `reply_delivered` fires
