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

---

## DeviceActivity & Monitoring

### ADR-033: `DeviceActivityMonitor` is the primary extension; `DeviceActivityReport` is for display only
**Decision:** `DeviceActivityMonitor` handles all real-time threshold detection and drives nudge triggers. `DeviceActivityReport` is used only for extracting per-app usage data to write to the App Group container for Supabase sync.
**Why:** `DeviceActivityReport` is a SwiftUI view rendered on demand — it has no trigger capability. `DeviceActivityMonitor` receives OS callbacks when scheduled thresholds fire and is the only mechanism for real-time detection.

### ADR-034: Nudge sending from monitor extension — Strategy 2 (Strategy 1 validated non-functional)
**Decision:** The `DeviceActivityMonitor` extension does **not** perform the network call. On threshold it posts a local notification and writes a `PendingTrigger` (including the pre-built report text) to the App Group; the **main app** performs the `send-nudge` call when it next runs the `nudge-trigger` `BGProcessingTask` **or** is foregrounded (immediate drain). Implemented in `NudgeTriggerService` (`drainPendingTriggers`), wired in `NudgeApp` (BG handler + `.background` scheduling + foreground drain). The extension also best-effort submits a `BGProcessingTaskRequest` to prompt an earlier wake.
**Why:** Strategy 1 (background `URLSession` from the extension) was **validated as non-functional on-device (2026-09-06)** — the request never reached Supabase (no edge-log entry at all). This matches Apple's guidance: an Apple Frameworks Engineer states DeviceActivityMonitor extensions are lightweight and terminate as soon as the synchronous override returns, so async network work "will likely exit before it finishes." The only "instant" workaround (a `DispatchSemaphore`/`DispatchGroup`-blocked synchronous call) is explicitly caveated by Apple as unreliable — the system can still kill the extension first, response reads often fail, and multiple sequential requests (one per friend) frequently don't complete. Apple's recommended pattern and comparable production apps both defer off-device work to the main app. Trade-off accepted: delivery is instant on app-open and otherwise within minutes via the background task (real-time third-party delivery is not reliably achievable with the current Screen Time API). Research: developer.apple.com/forums/thread/724649, riedel.wtf/state-of-the-screen-time-api-2024.

### ADR-035: Debounced monitoring re-registration on goal changes
**Decision:** `MonitoringRegistrationService.goalDidChange()` cancels any pending re-registration task and restarts a 1.5-second idle timer. Monitoring is only re-registered after the user stops making changes.
**Why:** `DeviceActivityCenter.startMonitoring` is a system call that should not be hammered on every keystroke. Debouncing prevents redundant calls when a user rapidly edits a threshold.

### ADR-036: `DeviceActivityEvent` naming scheme
**Decision:** Event token identifiers follow a structured format: `app.<bundle_id>` for app-specific goals, `category.<category_id>` for category goals, `total` for total screen time, and `session.timeout` for the continuous-use session timer.
**Why:** The event name is passed as context to `eventDidReachThreshold`. A structured, readable format makes it straightforward to determine which trigger fired without a lookup table.

### ADR-037: Usage sync on foreground + midnight + BGProcessingTask (Option C)
**Decision:** Usage data is synced to Supabase on three triggers: (1) every app foreground, (2) `intervalDidEnd` at midnight, (3) `BGProcessingTask` safety net.
**Why:** Foreground sync gives intra-day progress tracking for free (each app open refreshes totals). Midnight sync captures final daily totals even if the app is never opened. BGProcessingTask covers edge cases. The upsert pattern makes running all three idempotent.

### ADR-038: App Group secrets — anon key + JWT only; never service role key
**Decision:** The main app writes three values to App Group UserDefaults: the Supabase URL, the anon key, and the current user's JWT. The service role key is never written to App Group.
**Why:** The monitor extension calls Edge Functions as the authenticated user (JWT + anon key). The Edge Function uses its own service role for DB operations server-side. The service role key grants unrestricted DB access — it must never leave the server boundary.

### ADR-039: Global trigger toggles for nudge recipients; per-friend config as future enhancement
**Decision:** All accepted friends receive all active trigger types. The user controls which trigger types are active globally in Settings (session timeout on/off + threshold, goal breach on/off, daily report on/off + time). There is no per-friend configuration in the current implementation.
**Why:** Covers the common case with minimal UI and DB complexity. Per-friend configuration (e.g. different friends for different trigger types) is a natural enhancement but requires a `friend_trigger` junction table and additional UI — deferred to backlog.

### ADR-040: Message constants split across `NudgeMessages.swift` (iOS) and `_shared/messages.ts` (Edge Functions)
**Decision:** All iOS report string templates live in `Nudge/Resources/NudgeMessages.swift`. The reply options suffix lives in `supabase/functions/_shared/messages.ts` and is imported by `send-nudge`. These are the only two files that need to change to update SMS copy.
**Why:** iOS and Edge Functions are different runtimes (Swift vs TypeScript/Deno) — a single shared file is not possible. Two co-located, clearly named constants files achieve the same goal of easy discoverability and editability.

### ADR-041: SMS messages — no emojis, app names in goal breach, top 3 apps in daily report
**Decision:** All SMS messages use plain text without emojis. Goal breach messages name the specific app (not "your goal"). Daily report messages list the top 3 apps by usage time.
**Why:** Matches the tone established in the consent SMS (plain, conversational). App names make goal breach messages immediately actionable. Top 3 is enough context without making messages unwieldy.

### ADR-043: DeviceActivityReport extension must be in Extensions/, not PlugIns/

**Decision:** The `NudgeActivityReport` extension is embedded in the main app bundle's `Extensions/` directory, not `PlugIns/`.
**Why:** `DeviceActivityReport` uses ExtensionKit, not the older NSExtension system. ExtensionKit extensions must live in `Extensions/`. Embedding in `PlugIns/` (Xcode's default for app extensions) causes `ClientError Code=2` at runtime — the system cannot discover the extension. Fix: in main app Build Phases, set the copy destination to "Extensions" not "Plug-ins".

### ADR-044: DeviceActivityReport view must be non-zero size

**Decision:** The hidden `DeviceActivityReport` view in `NudgeApp` uses `.frame(width: 1, height: 1).opacity(0)` rather than `.frame(width: 0, height: 0).clipped()`.
**Why:** SwiftUI skips rendering views with zero frame size. A clipped zero-size view causes the DeviceActivityReport extension process to never be launched and `makeConfiguration` is never called.

### ADR-045: DeviceActivityFilter requires today's DateInterval

**Decision:** `DeviceActivityReport` is initialized with `DeviceActivityFilter(segment: .daily(during: Calendar.current.dateInterval(of: .day, for: Date())))`. The default `DeviceActivityFilter()` uses a zero-length `DateInterval` which returns no data.
**Why:** The filter's `segment` determines which time window of data is passed to `makeConfiguration`. A zero-length interval passes nothing. Today's full day interval passes today's usage data.

### ADR-046: Monitoring schedule must always be registered (even with no goal events)

**Decision:** `MonitoringRegistrationService.registerMonitoring` always calls `DeviceActivityCenter.startMonitoring`, even when the events dictionary is empty.
**Why:** `DeviceActivityReport` only has data for periods covered by a registered `DeviceActivitySchedule`. If no monitoring is registered, `makeConfiguration` receives an empty `DeviceActivityResults` regardless of actual phone usage. An empty events dictionary is valid — it registers the schedule for data collection without any threshold alerts.

### ADR-047: UsageSyncService must wait for DeviceActivityReport extension

**Decision:** `onForeground()` in `NudgeApp` waits 3 seconds after triggering the `DeviceActivityReport` re-render before calling `UsageSyncService.sync()`.
**Why:** The extension runs in a separate OS process. `makeConfiguration` is async and takes 1–3 seconds to iterate `DeviceActivityResults` and write to the App Group. Without a delay, the sync always reads an empty App Group because it runs before the extension finishes writing.

### ADR-048: ApplicationActivity bundle ID via app.application.bundleIdentifier

**Decision:** In the DeviceActivityReport extension, the app bundle identifier is read as `app.application.bundleIdentifier` (returns `String?`) on `DeviceActivityData.ApplicationActivity`.
**Why:** `ApplicationActivity` does not have a `.token: ApplicationToken` property. The application is accessed via the `.application` property (type `Application` from FamilyControls), which exposes `.bundleIdentifier: String?`. Apps with a nil bundle identifier (internal system processes) are skipped with `guard let`.

### ADR-049: DeviceActivityReport extension is display-only; cannot write to App Group

**Decision:** The `NudgeActivityReport` extension is used exclusively to render usage data on-device in the Phase 2 dashboard. It does not write to the App Group container or sync data to Supabase.

**Why:** The `DeviceActivityReport` extension runs in a hardened OS sandbox that blocks all persistence and network I/O — including `UserDefaults(suiteName:)`, `FileManager` writes to the shared container, network calls, and Darwin notifications. This restriction is intentional (Apple prevents Screen Time data exfiltration to third-party servers) and is not a configuration issue. Confirmed via runtime error: "You don't have permission to save the file in the folder \<App Group UUID\>" even with correct entitlements and provisioning profile. An Apple DTS specialist has publicly confirmed this behavior on developer forums.

**Consequence:** Per-app usage data (seconds, pickups per bundle ID per day) cannot be synced to Supabase. The `usage` table in Supabase is unused by the current implementation and is left in the schema for potential future use. All cloud functionality is driven by `DeviceActivityMonitor` threshold events.

---

### ADR-042: App-specific DeviceActivity monitoring deferred to Phase 3

**Decision:** `MonitoringRegistrationService` only registers events for `total` and `session.timeout` goals in Phase 1. App-specific and category goals are skipped.
**Why:** `DeviceActivityEvent.applications` requires `ApplicationToken` (an opaque type), which can only be obtained via `FamilyActivityPicker`. There is no public `Application(bundleIdentifier:)` API in the available SDK. The Phase 3 Goals UI will add `FamilyActivityPicker` for app selection and store the `FamilyActivitySelection` (encoded as PropertyList) to App Group so the registration service can read tokens at runtime.

### ADR-028: Two-init pattern for ViewModels with `@MainActor` service injection
**Decision:** ViewModels that inject services use two separate inits: a no-argument production init (`init() { self.service = RealService() }`) and a testing init (`init(service: ServiceProtocol) { self.service = service }`). Do not use a single init with a default parameter value.
**Why:** With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, writing `init(service: ServiceProtocol = RealService())` produces "Call to main actor-isolated initializer in a synchronous nonisolated context" — the default expression is evaluated in a nonisolated context. Two separate inits avoids this entirely.
