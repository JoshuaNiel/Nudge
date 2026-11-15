# Database Design

Architecture and decision log for the Nudge app Supabase/PostgreSQL schema.

---

## What We Store vs. What Apple Provides

### Apple's DeviceActivity APIs provide (on-device only):
- App foreground time per bundle ID per time interval
- Pickup count and notification count
- Apple's built-in app category classifications
- App names and icons

### Key constraint:
You cannot read raw usage numbers directly in the main app target. Data is accessed through a `DeviceActivityReport` extension that renders SwiftUI views. Apple also does not expose arbitrary historical data — you only have access to active monitoring windows.

### Therefore, we store in Supabase:
- Historical usage snapshots (synced daily from DeviceActivity — this is the entire data pipeline for charts and the insights engine)
- User goals and motivational reminders
- Custom app categories (separate from Apple's built-in ones)
- Friend connections and social nudges
- User preferences and settings

---

## Schema SQL

The full schema (tables, enums, indexes, RLS policies, and profile trigger) is in `supabase/schema.sql`. Run it in the Supabase SQL editor to set up the database.

---

## Column Naming Convention

All database columns use **snake_case** (e.g. `first_name`, `bundle_id`, `limit_seconds`). The Supabase Swift SDK automatically converts snake_case → camelCase when decoding, so Swift models use camelCase properties without needing explicit `CodingKeys` — as long as the property names match the camelCase equivalents exactly.

The column names in the schema tables below use camelCase for readability. The actual SQL uses snake_case. For example:
- Doc shows: `firstName` → SQL has: `first_name` → Swift sees: `firstName`

The existing `AppUsage.swift` and `Goal.swift` models were written before the schema was finalized and **do not yet match the DB column names**. They will need to be updated when the data layer is built in Phase 2.

---

## Auth Strategy

Supabase Auth manages authentication via its own internal `auth.users` table (UUID primary key, email, hashed password). We do not build our own auth table.

We maintain a `profiles` table for additional user metadata. Its `user_id` is a FK to `auth.users.id`.

**All other tables reference `auth.users.id` directly, not `profiles.user_id`.**

Reason: `profiles.user_id` is just a mirror of `auth.users.id`. Going through `profiles` adds an unnecessary join. Supabase RLS policies also operate against `auth.uid()` which is the `auth.users` ID, so referencing it directly is more natural.

---

## Schema

### `profiles`
Extends Supabase Auth with user-specific settings.

| Column | Type | Notes |
|---|---|---|
| user_id | uuid | FK → auth.users(id), PK |
| firstName | varchar | |
| lastName | varchar | |
| phoneNumber | varchar | E.164 format — used to receive friend SMS replies |
| weekStart | int | 0 = Sunday, 1 = Monday, etc. |
| timeZone | varchar | IANA timezone string (e.g. `America/Denver`) |
| settingsLocationLat | double precision | For location-based settings lock |
| settingsLocationLon | double precision | For location-based settings lock |

**`session_timeout_minutes`** (migration 003) — **DEPRECATED since migration 008**: backfilled into `nudge_settings` and no longer read or written by the app. Kept until a later cleanup migration drops it.

### `nudge_settings` (migration 008, Phase 5E)
One row per user: the global nudge trigger toggles (ADR-039). **No row = defaults**; the app upserts on `user_id` at first save.

| Column | Type | Notes |
|---|---|---|
| user_id | uuid | PK, FK → auth.users(id) `on delete cascade` |
| session_timeout_enabled | boolean | default `true` |
| session_timeout_minutes | int | default `60`; CHECK in (15, 30, 60, 90, 120) |
| goal_breach_enabled | boolean | default `false` — nudge friends when a goal hits 100% |
| daily_report_enabled | boolean | default `false` (sending: Phase 5E-2) |
| daily_report_time | time | default `08:00`, the user's local wall-clock time. App sends/accepts `HH:mm:ss`. |
| updated_at | timestamptz | set by trigger `nudge_settings_set_updated_at` on update |

RLS enabled + forced; select / insert / update own row only (`(select auth.uid()) = user_id`); no delete policy. The monitor extension reads the goal-breach and daily-report toggles from the App Group mirror `nudge.settings` (missing → all off), not from the DB.

### `app` — DEPRECATED (unused since migration 006)
Canonical app registry. Bundle ID is the primary key — no generated integer ID needed.
Never populated (the usage pipeline it was meant for is impossible, ADR-049) and no longer
read or written by the app: goals identify apps by `FamilyActivitySelection` tokens, not
bundle IDs (ADR-042, Phase 3 G1). Kept in the schema, like `usage`.

| Column | Type | Notes |
|---|---|---|
| bundleId | varchar | PK — e.g. `com.instagram.Instagram` |
| name | varchar | Display name |

**`bundleId` must be `varchar`, not an integer.** Bundle IDs are strings and are the canonical identifier used by all Apple Screen Time APIs (DeviceActivity, ManagedSettings, FamilyControls).

### `app_category`
User-defined custom app groupings, separate from Apple's built-in categories.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) |
| name | varchar | Unique per user, non-blank |
| color | text | `#RRGGBB` |
| selection | text | Nullable. Base64 of a PropertyList-encoded `FamilyActivitySelection` (≥1 app or Apple-category token). Added in migration 006; ≤ 131072 chars. |

### `app_category_members` — DEPRECATED (unused since migration 006)
Join table for the many-to-many relationship between categories and apps. Replaced by
`app_category.selection`; kept in the schema but no longer read or written.

| Column | Type | Notes |
|---|---|---|
| bundleId | varchar | FK → app(bundleId) |
| categoryId | bigint | FK → app_category(id) |

### `usage`
Daily usage snapshots synced from Apple's DeviceActivity. This is the core data pipeline — without it there is no historical data, no trend charts, and no insights engine.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) |
| date | date | Local date in user's timezone (see timezone rules below) |
| appId | varchar | FK → app(bundleId) |
| seconds | bigint | Total foreground screen time |
| pickups | bigint | Number of device pickups |

### `goal`
Time limit goals per app or category.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) |
| limitSeconds | bigint | The time limit for the given frequency window |
| frequency | enum | `daily`, `weekly`, `monthly` |
| bundleId | varchar | **Deprecated** (migration 006) — nullable, never written. |
| categoryId | bigint | Nullable FK → app_category(id), `on delete cascade` |
| selection | text | App goals only: base64 PropertyList `FamilyActivitySelection` with exactly one app token. Null for category/total. ≤ 131072 chars. |
| label | varchar(100) | User-typed display name. Required (non-blank) for app goals; tokens have no readable name outside a SwiftUI `Label`. |
| targetType | enum | `app`, `category`, `total` |
| temporary | boolean | Whether this is a time-bounded goal |
| startDate | date | Only used when temporary = true |
| endDate | date | Only used when temporary = true |

**Target check (migration 006):** `app` → `selection` set, `category_id` null; `category` → `category_id` set, `selection` null (the tokens live on the category row); `total` → both null. Display labels: app → `label`, category → `app_category.name`, total → "All Apps".

**Duplicate guard (ADR-010):** partial unique indexes on non-temporary goals — `total` on (`user_id`, `frequency`); `category` on (`user_id`, `category_id`, `frequency`); `app` on (`user_id`, `md5(selection)`, `frequency`) (`goal_unique_active_app_selection`, replacing the bundle-ID index, which NULL `bundle_id`s would have bypassed). The app guard is best effort: re-picking the same app can yield byte-different token data.

**Progress is not stored here.** Usage never leaves the device (ADR-049). The monitor extension records 10%-step milestones in the App Group (`nudge.progress.<day>`), see `docs/specs/phase-3-goals.md`.

**On `frequency`:** The `limitSeconds` applies to the window defined by `frequency`. Only `daily` goals are monitored today (Phase 3 G6); `weekly`/`monthly` are stored but skipped by `MonitoringPlan`.

**On `temporary`:** When `true`, the goal is monitored only on local days between `startDate` and `endDate` (inclusive); the filter runs on-device in `MonitoringPlan` so the extension applies it at midnight without the app.

### `why_reminder`
Motivational reminders sent as notifications to help users stay intentional. Not tied to specific goals — a random or round-robin active reminder is selected when sending a notification.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) |
| message | varchar | The reminder text |

### `friend`
Stores the app user's contacts. Friends do not need a Supabase account or the app installed.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) — the app user who added this contact |
| friendName | varchar | Display name |
| friendPhoneNumber | varchar | E.164 format (`+18015551234`) |
| status | enum | `pending`, `accepted`, `blocked` |
| invitationTimestamp | timestamptz | UTC — when the consent SMS was sent |

**On `status`:** `pending` while awaiting consent reply; `accepted` once friend confirms; `blocked` for Twilio STOP opt-outs only. Friends who reply no are deleted outright — no row retained.

### `nudge`
Tracks each SMS nudge sent to a friend and the friend's reply.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| friendId | bigint | FK → friend(id) |
| prompt | varchar | The message options sent to the friend via SMS |
| friendReply | varchar | The friend's reply text (populated by Twilio webhook) |
| type | enum | `shame`, `encouragement`, `custom` |
| status | enum | `sent_to_friend`, `replied`, `reply_delivered`, `failed` |
| sentTimestamp | timestamptz | UTC — when the nudge was sent |

**Note:** The app user is derivable via `friend.userId` — no separate receiver column is needed on `nudge`.

---

## Timezone Handling

**Rule: store everything in UTC, convert at display time.**

### Timestamp columns (`timestamptz`)
Use `timestamptz` for all moment-in-time values (e.g. `nudge.sentTimestamp`, `friend.invitationTimestamp`). Postgres stores these as UTC internally and handles conversion correctly.

### Usage dates (`date`)
`usage.date` uses Postgres `date` type (no timezone). This is intentional — it represents the **local calendar date the user experienced**, not a UTC date.

When writing a usage snapshot, derive the date from the user's timezone on-device before writing to Supabase:

```swift
// Correct — use the user's timezone to determine what "today" is
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: userTimeZone)!
let today = calendar.startOfDay(for: Date())
```

If you used UTC here, a user at 11pm local time would write their snapshot to the wrong date.

### `profiles.timeZone`
Store as an IANA timezone identifier (`America/Denver`, `America/New_York`), not an abbreviation (`MST`, `EST`). IANA identifiers handle daylight saving time correctly; abbreviations do not.

### Weekly goal boundaries
When evaluating a weekly goal, compute the week's start and end as UTC timestamps on-device using the user's `timeZone` and `weekStart` preference, then pass those bounds to the Supabase query. Do not compute week boundaries in SQL without the user's timezone context.

---

## What Apple Provides vs. What We Store (Summary Table)

| Data | Source | Stored in Supabase? |
|---|---|---|
| App foreground time | DeviceActivity | Yes — synced daily to `usage` |
| Pickup count | DeviceActivity | Yes — synced daily to `usage` |
| Notification count | DeviceActivity | No — not currently captured |
| App bundle IDs | DeviceActivity / App Store | Yes — in `app` table |
| Apple's app categories | DeviceActivity | No — we use custom categories |
| Real-time today's usage | DeviceActivity | No — read on-device only |
| Auth / identity | Supabase Auth | Managed by Supabase |
| Goals and reminders | App-defined | Yes |
| Friend contacts | App-defined (name + phone) | Yes — friends don't need the app |
| SMS nudges and replies | Twilio webhook | Yes — in `nudge` table |
