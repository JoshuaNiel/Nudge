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

---

## Social / Nudge System

### ADR-022: Nudges are automatic — not user-initiated
**Decision:** The app automatically sends nudges to friends when triggers fire (time-on-phone threshold, goal breach, daily report). There is no "Send Nudge" button. The user configures which triggers are active and at what thresholds in Settings.
**Why:** The original design imagined a manual nudge button, but that defeats the purpose — the user would be choosing to interrupt themselves, which they could just do on their own. The value is in automatic accountability with zero friction.

### ADR-023: NudgeType is determined by the friend's reply — not set at send time
**Decision:** `nudge.type` is nullable in the DB. It is `NULL` when the nudge row is inserted and is set when the friend replies: `1` → `encouragement`, `2` → `shame`, any other text → `custom`.
**Why:** The type represents the friend's chosen response, not something the app user selects. The app user has no input on the type of message their friend sends back.

### ADR-024: APNs delivered via direct HTTP/2 from Edge Function
**Decision:** Push notifications are sent from the `receive-reply` Edge Function by making direct HTTP/2 calls to the APNs API using token-based auth (ES256 JWT generated from the .p8 key). Supabase's push notification dashboard is not used.
**Why:** Supabase's push dashboard requires extra setup and doesn't integrate with the inbound SMS reply flow. Calling APNs directly from the Edge Function is simpler and keeps all reply-delivery logic in one place.

### ADR-025: `device_tokens` is a separate table (not a column on `profile`)
**Decision:** Device tokens are stored in a `device_tokens` table with `(user_id, token, platform, updated_at)` and a unique constraint on `(user_id, token)`.
**Why:** Users may have multiple devices (iPhone + iPad). A single column on `profile` can only hold one token. A separate table with upsert on `(user_id, token)` handles multiple devices cleanly.

### ADR-026: Nudge rate limit is 10 per friend per day in the user's local timezone
**Decision:** The `send-nudge` Edge Function enforces a maximum of 10 nudges per friend per calendar day, where "day" is calculated using the user's `profile.time_zone` (IANA format).
**Why:** Prevents spam. 10/day is high enough to not block legitimate multi-trigger scenarios while preventing runaway sending. Local timezone is used so "today" matches the user's experience rather than UTC midnight.

### ADR-027: STOP opt-out sets `status = blocked`; no custom confirmation SMS is sent
**Decision:** When a friend replies with a STOP keyword, all their friend rows are set to `blocked` and no confirmation SMS is sent from the app.
**Why:** Twilio handles the regulatory STOP acknowledgment at the carrier level automatically. Sending an additional confirmation SMS from the app could interfere with the carrier-level STOP processing and creates a compliance risk.

### ADR-029: Edge Function secrets, not Supabase Vault, for runtime credentials
**Decision:** Twilio and APNs credentials are stored as Edge Function secrets (`supabase secrets set`) rather than in Supabase Vault.
**Why:** `Deno.env.get()` reads Edge Function environment variables — it cannot access Vault, which stores secrets in the database and is only accessible via SQL. Vault is the right choice when a Postgres function or trigger needs a secret at the DB layer. For secrets consumed exclusively by Edge Functions, Edge Function secrets are the correct mechanism. Both are encrypted at rest; the difference is access control layer, not security level.

### ADR-030: SMS sent via Twilio Messaging Service SID, not a direct phone number
**Decision:** `sendSms` uses `MessagingServiceSid` as the sender parameter instead of `From` with a direct phone number. The secret is `TWILIO_MESSAGING_SERVICE_SID`.
**Why:** A Messaging Service enables number pooling, sticky sender (same number per recipient), and better carrier deliverability. It also decouples the code from a specific phone number — numbers can be added or swapped in the Twilio console without any code or secret changes.

### ADR-031: `receive-reply` deployed with `--no-verify-jwt`; auth via Twilio HMAC-SHA1
**Decision:** The `receive-reply` Edge Function is deployed with JWT verification disabled (`supabase functions deploy receive-reply --no-verify-jwt`). Security is provided by validating the Twilio HMAC-SHA1 signature on every inbound request.
**Why:** Twilio's inbound webhook does not carry a Supabase JWT — it would fail the default JWT check before the function code even runs, returning a 401. Twilio's signature validation (HMAC-SHA1 of the request URL + body params, signed with the auth token) is the standard mechanism for authenticating Twilio webhooks and provides equivalent protection.

### ADR-032: Twilio signature validated against a reconstructed URL, not `req.url`
**Decision:** `validateTwilioSignature` accepts an optional explicit `url` parameter. `receive-reply` reconstructs the correct public URL using `x-forwarded-proto` (for the scheme) and the host from `req.url` (which is correct), prepending `/functions/v1` to the path that the proxy strips.
**Why:** Behind Supabase's proxy, `req.url` arrives with `http://` scheme instead of `https://`, and with the `/functions/v1` path prefix stripped. Twilio signs the exact public URL it POST-ed to (`https://<ref>.supabase.co/functions/v1/receive-reply`). Using `req.url` directly causes the HMAC comparison to always fail. The `host` header is also unreliable — it returns `edge-runtime.supabase.com` (the internal runtime host), not the project host.

### ADR-028: Two-init pattern for ViewModels with `@MainActor` service injection
**Decision:** ViewModels that inject services use two separate inits: a no-argument production init (`init() { self.service = RealService() }`) and a testing init (`init(service: ServiceProtocol) { self.service = service }`). Do not use a single init with a default parameter value.
**Why:** With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, writing `init(service: ServiceProtocol = RealService())` produces "Call to main actor-isolated initializer in a synchronous nonisolated context" — the default expression is evaluated in a nonisolated context. Two separate inits avoids this entirely.
