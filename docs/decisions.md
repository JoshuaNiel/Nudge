# Architecture Decision Log

Settled decisions and their rationale. Do not re-litigate these without good reason.

---

## Auth & Backend

### ADR-001: Supabase for backend
**Decision:** Supabase handles auth, database (Postgres), realtime subscriptions, and Edge Functions.
**Why:** Integrated solution — no separate auth server, DB, or function host. Supabase Swift SDK handles session persistence, snake_case ↔ camelCase decoding, and realtime subscriptions natively.

### ADR-002: Email + Sign in with Apple; no other providers
**Decision:** Two auth methods only: email/password and Sign in with Apple.
**Why:** Sign in with Apple is required by App Store guidelines when any third-party auth is offered. Email/password gives a cross-platform fallback for users who may switch to Android/Mac later.

### ADR-003: Account linking enabled
**Decision:** Supabase "Link accounts by email" is enabled.
**Why:** Allows a user who signed up with Apple (possibly with a private relay email) to later link an email/password credential on a different platform.

### ADR-004: Email confirmation disabled during development
**Decision:** Email confirmation is turned off in Supabase Auth settings for now.
**Why:** Speeds up dev/testing. Must be re-enabled before App Store submission. The deep link plumbing (`nudge://` URL scheme + callback handler) is a known TODO.

### ADR-005: All tables reference `auth.users.id` directly
**Decision:** Foreign keys from `usage`, `goal`, `app_category`, `friend`, `why_reminder` all reference `auth.users(id)`, not `profile.user_id`.
**Why:** `profile.user_id` is a mirror of `auth.users.id`. Going through `profile` adds a join. Supabase RLS operates on `auth.uid()` which is the `auth.users` ID — referencing it directly is natural and avoids an extra hop.

---

## Database Schema

### ADR-006: `app.bundle_id` is varchar PK, not an integer
**Decision:** The `app` table uses `bundle_id varchar(255)` as its primary key.
**Why:** Bundle IDs are strings (e.g. `com.instagram.Instagram`) and are the canonical identifier used by all Apple Screen Time APIs. An integer surrogate key would require a lookup table and add joins everywhere.

### ADR-007: `usage.date` uses Postgres `date` type (no timezone)
**Decision:** `usage.date` is `date`, not `timestamptz`.
**Why:** It represents the *local calendar date the user experienced*, not a UTC moment. A user at 11pm local time writing a snapshot would get the wrong date if stored as UTC. Date is derived on-device from the user's timezone before writing.

### ADR-008: IANA timezone identifiers, not abbreviations
**Decision:** `profile.time_zone` stores IANA strings (e.g. `America/Denver`), not abbreviations (e.g. `MST`).
**Why:** IANA identifiers handle daylight saving time correctly. Abbreviations are ambiguous and do not handle DST.

### ADR-009: Goal targets use two nullable FKs, not a polymorphic ID
**Decision:** `goal` has separate nullable `bundle_id` and `category_id` columns, with a check constraint enforcing exactly one is set (or neither, for `total` type).
**Why:** A single polymorphic `target_id integer` column cannot carry a real FK constraint. The two-column approach gives referential integrity at the database level.

### ADR-010: `goal` unique index only on non-temporary goals
**Decision:** Three partial unique indexes prevent duplicate non-temporary goals for the same target + frequency. Temporary goals are excluded.
**Why:** A user can have one permanent daily limit and one temporary daily limit for the same app simultaneously (e.g. a permanent 1hr limit and a stricter 30min limit for a focused week).

---

## Social Layer

### ADR-011: Friends are phone numbers — no Supabase account required
**Decision:** Friends are stored as (name, phone number) in the `friend` table. They receive nudges via SMS. They do not need the Nudge app or a Supabase account.
**Why:** Lowers the bar for accountability — a friend just needs a cell phone. Requiring the friend to install the app would kill adoption of the social feature.

### ADR-012: `friend.status` managed exclusively by Edge Functions
**Decision:** Client app cannot update `friend.status`. Status transitions are handled only by Edge Functions via service role. This is enforced via RLS (no client update policy for status) and a column-level grant (only `friend_name` is updatable by authenticated users).
**Why:** Allowing the client to set `status = accepted` would let a user bypass the consent requirement entirely, enabling non-consensual nudges.

### ADR-013: `nudge` rows created only by Edge Functions
**Decision:** No insert RLS policy on `nudge` for authenticated users. Nudges are created exclusively by the `send-nudge` Edge Function (service role).
**Why:** The Edge Function validates `friend.status = accepted` before inserting. Allowing direct client inserts would bypass that check.

### ADR-014: Friend rejection deletes the row; `blocked` is for STOP only
**Decision:** If a friend replies "NO" to a consent SMS, the friend row is deleted and the app user is notified. `blocked` status is reserved exclusively for Twilio STOP opt-outs.
**Why:** Regulatory compliance — Twilio STOP must be honored permanently. A "no" reply is a social preference, not a regulatory requirement, and retaining the row would permanently block re-adding the contact.

### ADR-015: Twilio for SMS
**Decision:** Twilio is the SMS provider for outbound consent and nudge messages.
**Why:** Well-documented API, webhook support for inbound replies, handles STOP/compliance automatically.

---

## iOS / Swift

### ADR-016: Minimum deployment target iOS 17
**Decision:** The app targets iOS 17 as the minimum supported version.
**Why:** All required APIs (DeviceActivity, FamilyControls, Swift Charts) are available on iOS 15+, so iOS 17 is a comfortable minimum that covers the vast majority of active devices without restricting API usage.

### ADR-018: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
**Decision:** All code is implicitly `@MainActor` unless explicitly marked otherwise (build setting).
**Why:** Simplifies SwiftUI state management — no explicit `@MainActor` annotations needed on ViewModels. CPU-heavy work must be explicitly dispatched off the main actor.

### ADR-019: Swift Package Manager only
**Decision:** No CocoaPods or Carthage. SPM only.
**Why:** SPM is the modern standard, first-class in Xcode, and sufficient for all dependencies.

### ADR-020: Supabase credentials via Config.xcconfig (gitignored)
**Decision:** `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` are stored in `Config.xcconfig` and injected into Swift via Info.plist build setting interpolation.
**Why:** Keeps credentials out of source control. The `.xcconfig` file is in `.gitignore`.

### ADR-021: MVVM + Service Layer
**Decision:** Views (SwiftUI, no logic) → ViewModels (state, data transformation) → Services (Supabase calls, DeviceActivity) → Models (plain Codable structs).
**Why:** Clean separation of concerns. Services are testable in isolation. Views are simple and declarative.
