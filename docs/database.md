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
| weekStart | int | 0 = Sunday, 1 = Monday, etc. |
| timeZone | varchar | IANA timezone string (e.g. `America/Denver`) |
| settingsLocationLat | double precision | For location-based settings lock |
| settingsLocationLon | double precision | For location-based settings lock |

### `app`
Canonical app registry. Bundle ID is the primary key — no generated integer ID needed.

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
| name | varchar | |
| color | text | |

### `app_category_members`
Join table for the many-to-many relationship between categories and apps.

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
| bundleId | varchar | Nullable FK → app(bundleId) |
| categoryId | bigint | Nullable FK → app_category(id) |
| targetType | enum | `app`, `category`, `total` |
| temporary | boolean | Whether this is a time-bounded goal |
| startTime | timestamptz | Only used when temporary = true |
| endTime | timestamptz | Only used when temporary = true |

**On `bundleId` vs `categoryId`:** Both are nullable. Exactly one should be set depending on `targetType` (enforced via check constraint). This gives real referential integrity vs. a single polymorphic `targetId` integer column which cannot have a FK constraint.

**On `frequency`:** The `limitSeconds` applies to the window defined by `frequency`. Evaluation queries `usage` summed over the appropriate window — today for `daily`, the current week (respecting `weekStart` from profiles) for `weekly`, the current calendar month for `monthly`.

**On `temporary`:** When `true`, `frequency` is ignored and the goal applies only between `startTime` and `endTime`.

### `why_reminder`
Motivational reminders sent as notifications to help users stay intentional. Not tied to specific goals — a random or round-robin active reminder is selected when sending a notification.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| userId | uuid | FK → auth.users(id) |
| message | varchar | The reminder text |

### `friends`
Self-referential friendship table. Directional at creation (requester → addressee), symmetric once accepted.

| Column | Type | Notes |
|---|---|---|
| requesterId | uuid | FK → auth.users(id) |
| addresseeId | uuid | FK → auth.users(id) |
| status | enum | `pending`, `accepted`, `blocked` |

**Naming note:** `addresseeId` is the person receiving the request. `status` tracks whether they've accepted — the column name does not imply acceptance.

### `nudges`
Shame and encouragement messages sent between friends.

| Column | Type | Notes |
|---|---|---|
| id | bigint | PK |
| senderId | uuid | FK → auth.users(id) |
| receiverId | uuid | FK → auth.users(id) |
| message | varchar | |
| timestamp | timestamptz | UTC |
| type | enum | `shame`, `encouragement` |

---

## Timezone Handling

**Rule: store everything in UTC, convert at display time.**

### Timestamp columns (`timestamptz`)
Use `timestamptz` for all moment-in-time values (`nudges.timestamp`, `goal.startTime`, `goal.endTime`). Postgres stores these as UTC internally and handles conversion correctly.

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
| Friend connections | App-defined | Yes |
| Social nudges | App-defined | Yes |
