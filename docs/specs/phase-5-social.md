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
- Builds full SMS: `report + REPLY_OPTIONS` (imported from `_shared/messages.ts` — no emojis)
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

### 5E — Nudge Trigger System `[ ] In progress`

> **Settings + daily report are specified in [`phase-5e-trigger-settings.md`](phase-5e-trigger-settings.md)**
> (approved v2 spec; it supersedes this section where they differ — e.g. settings live in
> `nudge_settings`, not `profile`, and the daily report is total-only). 5E-1 (settings
> table, Settings "Nudges" section, session-timeout + goal-breach toggles) is implemented
> on `feat/nudge-trigger-settings`; 5E-2 (daily report sending) is next.

**Blocked on Phase 1** — requires `DeviceActivityMonitor` extension and Family Controls entitlement. Now unblocked (entitlement approved, physical device available).

The app automatically sends nudges to all accepted friends when any of the following triggers fire. Users configure which triggers are active and at what thresholds in Settings.

#### Trigger Types

| Trigger | Description | Default |
|---|---|---|
| Session timeout | User has been on their phone continuously for N minutes | On (60 min) |
| Goal breached | User exceeded a specific goal's limit (app, category, or total) | Off |
| Daily report | Morning SMS summary of previous day's usage sent to all friends | Off |

#### Architecture

Triggers are detected by the `DeviceActivityMonitor` extension (Phase 1). When a threshold fires, the extension sends the nudge via one of two strategies:

**Strategy 1 (preferred) — Background URL Session from monitor extension:**
The extension initiates a `URLSession` with a background configuration to call the `send-nudge` Edge Function directly. Near-instant delivery (seconds after threshold). Must be validated on physical device — test this first.

**Strategy 2 (fallback) — App Group + BGProcessingTask:**
If Strategy 1 is unreliable in the monitor sandbox: extension writes `PendingTrigger` to App Group, schedules a `BGProcessingTask`. Main app wakes in background (typically 1–15 min) and calls the Edge Function. See Phase 1 spec for full data contract.

#### Which Friends Receive Nudges

**All accepted friends receive all active trigger types** (global trigger toggles). This is the simplest model and covers the common case. The user controls which trigger types are on/off globally in Settings; friends have no individual configuration.

> **Future enhancement:** Per-friend trigger configuration (e.g. Mom gets daily report, Jake gets goal breach only). This requires a `friend_trigger` junction table and additional Settings UI. Not in current scope — see backlog.

#### Message Constants Architecture

Report strings are assembled on the iOS side and passed as the `report` parameter to `send-nudge`. **All report string templates live in `Nudge/Resources/NudgeMessages.swift`** so they are easy to find and edit without touching Edge Function code.

The reply options suffix lives in **`supabase/functions/_shared/messages.ts`** and is imported by `send-nudge`. These are the only two files that need to change to update message copy.

**`NudgeMessages.swift`:**
```swift
enum NudgeMessages {
    static func sessionTimeout(firstName: String, minutes: Int) -> String {
        "\(firstName) has been on their phone for \(minutes) minutes straight."
    }

    static func goalBreach(firstName: String, minutes: Int, appName: String) -> String {
        "\(firstName) just passed their \(minutes)-minute daily limit on \(appName)."
    }

    static func dailyReport(
        firstName: String,
        totalMinutes: Int,
        topApps: [(name: String, minutes: Int)]
    ) -> String {
        let total = Self.formatDuration(totalMinutes)
        let apps = topApps.prefix(3)
            .map { "\($0.name) (\(Self.formatDuration($0.minutes)))" }
            .joined(separator: ", ")
        return "\(firstName)'s screen time yesterday: \(total) total. Top apps: \(apps)."
    }

    private static func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
```

**`supabase/functions/_shared/messages.ts`** (update existing `REPLY_OPTIONS` — remove emojis):
```typescript
export const REPLY_OPTIONS =
  '\n\nReply 1 to send encouragement\n' +
  'Reply 2 to give them a reality check\n' +
  'Or reply with your own message';
```

Import in `send-nudge/index.ts` instead of defining inline.

**Full SMS examples:**
- Session: "Josh has been on their phone for 47 minutes straight.\n\nReply 1 to send encouragement\nReply 2 to give them a reality check\nOr reply with your own message"
- Goal breach: "Josh just passed their 30-minute daily limit on Instagram.\n\nReply 1..."
- Daily report: "Josh's screen time yesterday: 3h 12m total. Top apps: Instagram (1h 4m), TikTok (52m), YouTube (31m).\n\nReply 1..."

#### Concurrency

If multiple triggers fire simultaneously (e.g. session timeout + goal breach at the same time), **send a separate nudge for each trigger.** The rate limit (10 nudges/friend/day) prevents runaway sending. No de-duplication or batching needed for MVP.

#### Settings UI for Nudge Triggers

- Toggle: Session timeout nudges (default on); threshold picker (15 / 30 / 60 / 90 / 120 min)
- Toggle: Goal-breach nudges (default off)
- Toggle: Daily report (default off); time picker for delivery time

#### Implementation Tasks

- [ ] Create `NudgeMessages.swift` with all report string builders
- [ ] Create `_shared/messages.ts` with `REPLY_OPTIONS` (no emojis); import in `send-nudge`
- [ ] Implement `DeviceActivityMonitor` extension `eventDidReachThreshold` with Strategy 1 + Strategy 2 fallback
- [ ] Create `NudgeTriggerService` in main app — reads pending triggers from App Group (Strategy 2 path) and calls `send-nudge`
- [ ] Add trigger settings to Settings screen (toggles + threshold pickers)
- [ ] Store trigger settings in App Group so the monitor extension can read them
- [ ] Wire `MonitoringRegistrationService` to include `session.timeout` event when enabled

### 5F — APNs iOS Registration + Push Deep Link `[~] Implemented — pending on-device validation`

Required before push notifications work end-to-end.

- [ ] Enable **Push Notifications** capability on main app target in Xcode (Signing & Capabilities → + Capability → Push Notifications) — **user does this in Xcode** (adds `aps-environment`)
- [x] `AppDelegate` via `@UIApplicationDelegateAdaptor` (`Core/AppDelegate.swift`): token / registration-failure callbacks (failure is logged with `os.Logger`, never crashes) and `UNUserNotificationCenterDelegate`
  - `willPresent` → `[.banner, .sound, .list]` while foregrounded (also applies to the monitor extension's local notifications)
  - `didReceive` (default tap action only) → parse `nudge_id` → `PushRouter`
- [x] **Registration never prompts.** `PermissionsView` (onboarding) remains the only place that requests notification permission. `PushRegistration.registerIfAuthorized()` calls `registerForRemoteNotifications()` only when the status is `.authorized` / `.provisional` / `.ephemeral`. Called on every foreground once a user is authenticated (`NudgeApp.onForeground`) and right after `PermissionsView` obtains permission. (Supersedes the earlier `requestAuthorization` snippet in `NudgeApp`.)
- [x] `DeviceTokenService` (`DeviceTokenServiceProtocol` + `@MainActor` class):
  ```swift
  protocol DeviceTokenServiceProtocol {
      func registerToken(_ token: String, userId: UUID) async throws   // upsert, onConflict "user_id,token"
      func deleteToken(_ token: String, userId: UUID) async throws
  }
  ```
  - Takes the **hex string**, not `Data`: hex-encoding happens once at the UIKit boundary (`DeviceToken.hexString(from:)`, pure + unit-tested) and the same string is persisted and used for delete.
  - Upserts `DeviceTokenInsert { user_id, token, platform = "apns", updated_at = now }` (Encodable + CodingKeys) with `returning: .minimal`. `updated_at` is sent explicitly so a re-upsert refreshes stale rows.
- [x] **Token lifecycle** — `PushTokenManager` (`Core/PushTokenManager.swift`, owned by `AppState`):
  - Latest token persisted in standard `UserDefaults` (`apnsDeviceToken`) — it is device-scoped, not user-scoped.
  - A token that arrives before auth is ready is uploaded as soon as a user signs in (`AppState.onSignedIn`).
  - Each (user, token) pair is uploaded at most once per process; a failed upload retries on the next token callback / sign-in.
  - **Sign-out** goes through `AppState.signOut()`: best-effort delete of this device's row *before* `supabase.auth.signOut()` (RLS needs the JWT). The delete is time-boxed (5 s) and its failure is logged and ignored — sign-out always proceeds. The local token is kept for the next sign-in.
- [x] **Deep link** — tapping a reply push opens that friend's `NudgeHistoryView`:
  - Payload: `apns.ts` spreads custom data at the **top level** beside `aps`: `{ "aps": {...}, "nudge_id": 17 }`. `PushPayload.nudgeId(from:)` accepts Int / NSNumber (incl. integral float) / numeric String; rejects missing, booleans, fractional, non-positive and garbage values.
  - `PushRouter` (`ObservableObject`, owned by `AppDelegate`, injected via `.environmentObject`) holds `pendingNudgeId`; `consumePendingNudgeId()` returns-and-clears so exactly one consumer acts on a tap.
  - `ContentView`'s `TabView` is selection-driven (`AppTab`); while an id is pending it switches to **Friends** (`onChange(initial: true)` covers cold start).
  - `SocialView` uses value-based navigation (`NavigationStack(path:)` + `SocialRoute.nudgeHistory(Friend)`). After its friend list loads (cold start / tab switch) or when a new id arrives (warm start), it consumes the id, resolves it via `SocialViewModel.friendForNudge(id:userId:)` → `FriendService.fetchFriendId(forNudgeId:)` (RLS restricts to the user's own nudges), refetches the friend list once if the friend isn't loaded, and sets `path = [.nudgeHistory(friend)]`.
  - Nudge not found / not the user's / friend not accepted / network error → stays on the Friends list. **No error alert.**
  - Pending id lives in memory only. If the user isn't signed in / hasn't finished onboarding, it waits until `ContentView` appears.
- [x] Tests: `NudgeTests/APNsTests.swift` (hex encoding, `DeviceTokenInsert` keys, payload parsing incl. nesting, router transitions, registration status gate, `PushTokenManager` lifecycle incl. pre-auth token / dedupe / retry / sign-out delete + timeout, deep-link resolution with a mock `FriendServiceProtocol`).

**APNs environment (server):** `_shared/apns.ts` already selects the host from the `APNS_SANDBOX` secret — `"true"` → `api.sandbox.push.apple.com`, anything else → `api.push.apple.com`. Xcode/development builds get **sandbox** tokens, so `APNS_SANDBOX=true` must be set while testing dev builds; TestFlight/App Store builds need it unset/`false`. The flag is global, so one project can't serve dev and production tokens at the same time (see backlog idea: store the environment per token).

**Known limitations (deferred):**
- ~~Tapping a push for the friend whose history is already on screen doesn't refetch that history (path value unchanged).~~ Fixed by 5H (realtime UPDATE + foreground refetch).
- Rows for rotated/uninstalled tokens, or for a user whose session expired without signing out on a shared device, aren't removed client-side (RLS only allows deleting your own rows). Server-side pruning on APNs `410 Unregistered` / `400 BadDeviceToken` would fix this.

### 5G — User Phone Number in Settings `[ ] Not started`

The app user can optionally add their own phone number so they receive the friend's reply as an SMS (in addition to the APNs push).

- [ ] Add phone number field to Settings → Profile section
- [ ] Validate E.164 on input
- [ ] Save to `profile.phone_number` via `AuthService.updateProfile`
- [ ] Display note: "Used only to receive your friend's replies as a text message. You can opt out at any time."

### 5H — Real-time Nudge Status `[~] Implemented — pending migration + on-device validation`

The nudge history screen updates live when a nudge is sent or a friend replies — no manual refresh.

- [x] **Migration `supabase/migrations/006b_realtime_nudge.sql`** — idempotently adds `public.nudge` to the `supabase_realtime` publication (`do $$` block checks `pg_publication_tables`). Named `006b` because another branch adds a `006`; the two are independent and can run in either order. **No RLS change**: Realtime Postgres Changes evaluates the existing "Users can read their own nudges" select policy as the subscribing user, so each user only receives their own nudges.
- [x] **`NudgeRealtimeService`** (`Services/NudgeRealtimeService.swift`, `NudgeRealtimeServiceProtocol` + `@MainActor` class):
  ```swift
  enum NudgeChange: Equatable { case inserted(Nudge), updated(Nudge), subscribed }
  protocol NudgeRealtimeServiceProtocol {
      func changes(friendId: Int) -> AsyncStream<NudgeChange>
  }
  ```
  - One channel per call, unique topic `nudge-history-<friendId>-<uuid>` (`supabase.channel(_:)` returns an existing channel for a reused topic, which could be one a previous screen is still leaving).
  - Two bindings registered before `subscribeWithError()`: `postgresChange(InsertAction.self, …)` and `postgresChange(UpdateAction.self, …)` on `public.nudge` with `filter: .eq("friend_id", value: friendId)`. DELETE is not subscribed (nudges are only deleted by FK cascade when the friend is removed).
  - Records decode with `JSONObject.decode(as: Nudge.self, decoder: PostgrestClient.Configuration.jsonDecoder)` — the same decoder as history fetches, so the existing snake_case `CodingKeys` apply and microsecond `+00:00` timestamps parse. An undecodable record is logged and skipped.
  - Yields `.subscribed` on every transition into `RealtimeChannelStatus.subscribed` — the first join and each automatic rejoin after a socket reconnect.
  - Stream termination (consumer stops / task cancelled) cancels the listener tasks, waits for any in-flight join to settle, then `supabase.removeChannel(channel)` (sends `leave`; the socket disconnects when no channels remain). No channel survives leaving the screen.
  - Subscribe failure (`RealtimeError.maxRetryAttemptsReached`, etc.) is logged with `os.Logger` and non-fatal — the stream just yields nothing.
- [x] **`NudgeHistoryViewModel`** (`Features/Social/NudgeHistoryViewModel.swift`, two-init pattern; production init takes `friendId`, test init injects `FriendServiceProtocol` + `NudgeRealtimeServiceProtocol`). Replaces the `@State` that lived in `NudgeHistoryView`.
  - `start()` (run from `.task`): opens the stream first (join overlaps the fetch; events buffer), then `load()` if the list is empty, else a silent `refresh()` (re-appearing keeps the list, no spinner), then applies each change until cancelled / the stream ends.
  - `load()`: spinner + error state, as before. `refresh()`: silent; failure keeps the current list (logged), and is shown only when there is nothing on screen.
  - `.subscribed` → `refresh()` (covers anything missed while disconnected, including the gap between the first fetch and the join).
  - `sceneDidBecomeActive()` → `refresh()` only while `start()` is running (screen visible).
  - Stale-response guard: every fetch and every applied realtime change bumps a generation counter; a fetch that returns after a newer fetch/change is discarded.
- [x] **Merge rules** (`NudgeHistoryMerge`, pure): order is newest `sent_timestamp` first, tie → higher id first (same as the query, made deterministic). INSERT of a new id → added in order. INSERT of an id already present → **no-op** (the held row is at least as new, e.g. already `replied`). UPDATE of a known id → replaced. UPDATE of an **unknown id → inserted** (its INSERT was missed while disconnected / before load; the UPDATE is the freshest state; RLS + the filter guarantee it is this friend's). Records whose `friend_id` differs → ignored (defensive).
- [x] **View** (`NudgeHistoryView` in `SocialView.swift`): `@StateObject` view model; `.task { await viewModel.start() }` (auto-cancelled on disappear — subscription only lives while the history is visible); `.onChange(of: scenePhase)` → `sceneDidBecomeActive()`; `.refreshable` on the list, and the empty / error states are scrollable so pull-to-refresh retries from them too.
- [x] Fixes the 5F limitation: tapping a reply push while that friend's history is already open now shows the reply — via the realtime UPDATE, and via the foreground refetch when the tap brings the app back from the background.
- [x] Tests: `NudgeTests/RealtimeNudgeTests.swift` — merge rules (insert new / older / duplicate, update existing / unknown, other friend, `.subscribed`, ordering + tie-break), Realtime record decoding (insert with nulls + microsecond timestamp, replied update, `reply_delivered`, missing column throws), view model load / error / retry / refresh-keeps-list, and the stream (insert + update applied, other friend ignored, `.subscribed` refetches, stream end returns cleanly, cancel terminates the stream, re-appear opens exactly one new stream without spinner, foreground refetch only while observing).

**Known limitations:**
- If the socket is already dead when the screen closes, `removeChannel` → `unsubscribe()` waits for a server ack that may never come; the detached cleanup task then lingers (no UI effect; the channel is not re-used because topics are unique).
- Realtime does not replay events missed while disconnected — covered by the refetch on every rejoin.

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

## Open Questions (Resolved This Session)

| Question | Resolution |
|---|---|
| Nudge trigger architecture | `eventDidReachThreshold` for goal/session; BGProcessingTask for daily report. Strategy 1 (background URLSession) preferred; Strategy 2 (App Group + BGProcessingTask) as fallback. |
| Which friends receive nudges | All accepted friends receive all active trigger types (global toggles). Per-friend config is a future enhancement. |
| Report string format | `NudgeMessages.swift` (iOS) + `_shared/messages.ts` (Edge Functions). No emojis. App names in goal breach. Top 3 apps in daily report. |
| Per-friend trigger configuration | Global toggles for now. Per-friend config deferred — see backlog. |
| Concurrency | Send a separate nudge per trigger. Rate limit handles excess. No batching. |

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
- [~] APNs push registered on device; token stored in `device_tokens` table (code done — needs Push capability + on-device check)
- [~] Incoming push deep-links to NudgeHistoryView for the relevant friend (code done — needs on-device check)
- [ ] App user's phone number field in Settings
- [ ] Nudge trigger system implemented (blocked on Phase 1 / Family Controls entitlement)
- [ ] Nudge trigger settings UI (threshold configuration)
- [~] Real-time nudge status update in UI when `replied` / `reply_delivered` fires (code done — needs migration `006b_realtime_nudge.sql` + on-device check)
