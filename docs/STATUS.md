# Nudge — Project Status

> **Read this first every session.** Update it at the end of each session.
> Last updated: 2026-04-14

---

## Current Phase

**Phase 5 — Social (Friends + SMS Nudges)** `[~] In Progress`

Backend (Edge Functions) and iOS service/UI layer are complete. Remaining work:
- APNs iOS registration (enable capability, register, store device token)
- User phone number field in Settings
- Nudge trigger system (blocked on Phase 1 — Family Controls entitlement)
- Nudge trigger settings UI
- Real-time nudge status updates in UI

**Phase 1 — DeviceActivity Pipeline** `[~] In Progress`

Core service layer and extension stubs complete. Remaining: Xcode target setup (manual GUI work) and on-device validation.

**Testing infrastructure** `[x] Done` — `NudgeTests` target with **43 passing tests** across Social, Goals, and model suites. Run with:
```
xcodebuild test -project Nudge.xcodeproj -scheme Nudge \
  -destination 'platform=iOS Simulator,arch=arm64,id=19C7BD9B-6973-4F63-8492-C8D13401B835'
```

---

## Phase Summary

| Phase | Name | Status |
|---|---|---|
| 0 | Auth & Onboarding | `[x] Done` |
| 1 | DeviceActivity Pipeline | `[ ] Ready to start` — entitlement approved; all open questions resolved |
| 2 | Dashboard | `[ ]` — depends on Phase 1 data in Supabase |
| 3 | Goals | `[ ] Ready` — no DeviceActivity dependency |
| 4 | Notifications & Interventions | `[ ]` — depends on Phase 1 + 3 |
| 5 | Social (Friends + SMS) | `[~] In Progress` — backend done; trigger system ready to start (Phase 1 unblocked) |

---

## Phase 0 — Auth & Onboarding `[x] Done`

All core auth and onboarding work is complete.

**Completed:**
- [x] `AppState` — session listener, `isAuthenticated`, `currentUser`, `isLoading`
- [x] `SupabaseClient` — singleton, credentials via `Config.xcconfig`
- [x] `RootView` — gates on `isAuthenticated` + `onboardingComplete` (`@AppStorage`)
- [x] `AuthService` — email sign-up/in, Sign in with Apple, `updateProfile`
- [x] `AuthView` — email + Apple sign-in UI
- [x] `OnboardingCoordinator` — drives tour → auth → profile → permissions
- [x] `OnboardingTourView` — feature tour slides
- [x] `ProfileSetupView` — collects first/last name, patches profile row
- [x] `PermissionsView` — Screen Time + notification permission prompts (stubs)
- [x] DB schema (`supabase/schema.sql`) — all tables, RLS, triggers, indexes
- [x] Placeholder tab views (Dashboard, Apps, Goals, Social, Settings)
- [x] Explicit CodingKeys on all Supabase models

**Known gaps (not blocking):**
- [ ] Email confirmation deep link (`nudge://` URL scheme) — see `docs/auth.md`

---

## Phase 1 — DeviceActivity Pipeline `[~] In Progress`

Service layer and extension code complete (2026-04-14). Awaiting Xcode target setup on physical device.

### Completed (2026-04-14 → 2026-04-15)

**Shared infrastructure:**
- [x] `Core/AppGroupKeys.swift` — all App Group key constants + BGTask identifiers
- [x] `Models/DeviceActivity.swift` — `PendingUsageEntry`, `PendingTrigger`, `GoalSummary`, `UsageRecord`, `FriendSummary`
- [x] `Resources/NudgeMessages.swift` — all SMS message templates (goal breach, session timeout, daily report)
- [x] DB migration `003_profile_session_timeout.sql` — `session_timeout_minutes` column on `profile` (run in Supabase)

**Main app services:**
- [x] `Services/GoalService.swift` — `fetchGoalSummaries(userId:)` joins `app` and `app_category` tables for display names
- [x] `Services/MonitoringRegistrationService.swift` — `registerMonitoring`, `reregisterIfLapsed`, `goalDidChange` (10s debounce); always registers schedule even with empty events (required for DeviceActivityReport to have data)
- [x] `Services/UsageSyncService.swift` — reads App Group, upserts `app` + `usage` tables (idempotent)

**App wiring:**
- [x] `Core/AppState.swift` — writes App Group secrets + first name + friends on sign-in/token refresh; clears on sign-out; publishes `timeZone` and `sessionTimeoutMinutes` from profile
- [x] `NudgeApp.swift` — BGTask registration; foreground → reregisterIfLapsed + 3s delay + UsageSyncService; hosts 1×1 invisible DeviceActivityReport view with today's `DeviceActivityFilter`; `DeviceActivityReport.Context.nudgeSummary`
- [x] `Features/Auth/PermissionsView.swift` — `AuthorizationCenter.shared.requestAuthorization(for: .individual)` wired up
- [x] `Info.plist` — `BGTaskSchedulerPermittedIdentifiers` added

**Xcode targets (set up on physical device):**
- [x] Main app: Family Controls + App Groups (`group.com.joshuaqn.Nudge`) capabilities added
- [x] `NudgeActivityMonitor` extension target created — Family Controls + App Groups; `MonitorExtension.swift` added; `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).NudgeMonitor`
- [x] `NudgeActivityReport` extension target created — Family Controls + App Groups; `NudgeActivityReport.swift`, `TotalActivityReport.swift`, `TotalActivityView.swift` contain Nudge implementation; embedded in main app's **Extensions** directory (not PlugIns)
- [x] Screen Time permission granted on device via `AuthorizationCenter`

**Extension implementation (NudgeActivityReport target):**
- [x] `NudgeActivityReport.swift` — `@main` entry point using `NudgeUsageReport` scene
- [x] `TotalActivityReport.swift` — `NudgeUsageReport: DeviceActivityReportScene`; `makeConfiguration` iterates `DeviceActivityResults<DeviceActivityData>` with nested `for await` loops; reads `app.application.bundleIdentifier`; writes `[PendingUsageEntry]` JSON to App Group
- [x] `TotalActivityView.swift` — `NudgeUsageCaptureView` (zero-size, receives entries from makeConfiguration)

**Tests:**
- [x] 24 new tests in `DeviceActivityTests.swift` — all 67 tests passing (no regressions)

### Architecture change — DeviceActivityReport is display-only

**Root cause confirmed (2026-04-15):**
`DeviceActivityReport` extensions run in a hardened Apple sandbox that blocks all App Group writes and network calls. The permission denial ("You don't have permission to save the file") is OS-enforced and cannot be worked around via entitlements or provisioning. See ADR-049.

**Consequence:** Per-app usage data cannot be synced to Supabase. The architecture has been updated:
- `DeviceActivityReport` → display only (Phase 2 dashboard, local on-device)
- `DeviceActivityMonitor` → all cloud/nudge functionality (already working)
- `usage` table in Supabase → unused, retained in schema for future consideration
- `UsageSyncService` → to be removed
- Hidden `DeviceActivityReport` in `NudgeApp.swift` → to be removed (served no purpose once write is dropped)

**What works:**
- Monitoring registers on launch (`active activities: 1` confirmed in logs)
- `makeConfiguration` confirmed called with real data (22 unique apps confirmed via Console.app)
- Threshold fires on-device → `eventDidReachThreshold` runs + local notification path (2026-09-06)

**Strategy 1 validated NON-functional (2026-09-06):** background `URLSession` from the monitor extension never reaches Supabase (no edge-log entry). Replaced by **Strategy 2** per ADR-034: extension enqueues a `PendingTrigger` to the App Group; main app sends via `NudgeTriggerService.drainPendingTriggers` on BG task + foreground. Awaiting on-device re-test (see PR #11).

**Remaining Phase 1 work:**
- [ ] On-device re-test of Strategy 2 (threshold → PendingTrigger enqueued → main app drains → SMS delivered on foreground / BG task)
- [ ] Remove `UsageSyncService` and related dead code (note: already absent on this branch)
- [ ] Remove hidden `DeviceActivityReport` view from `NudgeApp.swift`

### Known limitations / Phase 3 work

- App-specific and category goal monitoring deferred to Phase 3 (need `ApplicationToken` from `FamilyActivityPicker`)
- `session.timeout` uses accumulated daily total, not true continuous-session detection
- `GoalSummary` needs a `categoryBundleIds: [String]` field added in Phase 3 for category events

---

## Phase 3 — Goals `[ ] Ready to start`

No DeviceActivity dependency. Can be built against mock usage data for now; goal evaluation against real data hooks in when Phase 1 is complete.

See `specs/phase-3-goals.md` for full spec.

---

## Phase 5 — Social `[~] In Progress`

### Completed This Session

**iOS Layer:**
- [x] `Social.swift` — all models with explicit CodingKeys: `FriendStatus`, `NudgeType`, `NudgeStatus`, `Friend`, `FriendInsert`, `Nudge` (`type: NudgeType?` — nullable)
- [x] `FriendService.swift` — protocol + `@MainActor` class: fetch, add, delete, update name, fetch nudge history
- [x] `NudgeService.swift` — protocol + class: `sendNudge(friendId:report:)` calls `send-nudge` Edge Function
- [x] `SocialViewModel.swift` — two-init pattern (production + test injection)
- [x] `SocialView.swift` — full replacement: friend list (accepted + pending sections), empty state, error state, AddFriendSheet (E.164 validation), NudgeHistoryView, NudgeHistoryRow
- [x] `SocialTests.swift` — 43 tests covering all model coding, enum raw values, ViewModel loading/error/delete behavior

**Supabase Edge Functions:**
- [x] `supabase/functions/_shared/twilio.ts` — `sendSms` (Messaging Service SID), `validateTwilioSignature` (HMAC-SHA1, accepts explicit URL), `parseFormBody`, STOP/YES/NO keyword sets
- [x] `supabase/functions/_shared/apns.ts` — `sendApnsPush`, `generateApnsJwt` (ES256 JWT with Web Crypto), direct HTTP/2 to APNs
- [x] `supabase/functions/send-consent/index.ts` — DB webhook (Edge Function type) handler, consent SMS with first name lookup
- [x] `supabase/functions/send-nudge/index.ts` — auto-trigger handler, timezone-aware rate limit, nullable type insert
- [x] `supabase/functions/receive-reply/index.ts` — Twilio inbound webhook (`--no-verify-jwt`), URL reconstruction for signature validation, consent + nudge reply routing, APNs + SMS delivery
- [x] `supabase/functions/deno.json` — compiler options for Deno LSP
- [x] `.vscode/settings.json` — Deno language server for `supabase/functions/` (IDE only)

**DB Migrations:**
- [x] `supabase/migrations/001_device_tokens.sql` — `device_tokens` table with RLS
- [x] `supabase/migrations/002_nudge_type_nullable.sql` — `nudge.type` column made nullable

**Deployment:**
- [x] All three Edge Functions deployed to Supabase
- [x] `receive-reply` deployed with `--no-verify-jwt`
- [x] DB migrations run in Supabase SQL editor
- [x] DB Webhook configured (Edge Function type → `send-consent`) on `public.friend` INSERT
- [x] Twilio + APNs secrets set as Edge Function secrets (not Vault)
- [x] Twilio Messaging Service SID configured; `TWILIO_PHONE_NUMBER` removed
- [x] Consent SMS flow tested end-to-end — friend receives consent request and reply is processed

### Remaining

- [ ] APNs iOS registration (enable Push Notifications capability, `registerForRemoteNotifications`, `DeviceTokenService`, token upsert)
- [ ] Handle incoming push payload — deep-link to NudgeHistoryView
- [ ] User phone number field in Settings → Profile
- [ ] Nudge trigger system — **blocked on Phase 1**
- [ ] Nudge trigger settings UI
- [ ] Real-time nudge status updates (Supabase Realtime subscription on `nudge` table)

---

## Open Decisions

| Decision | Needed By | Status |
|---|---|---|
| Notification schedule for why reminders | Phase 4 | Open — in spec |
| Unlock prompt feasibility | Phase 4 | `specs/phase-4-notifications.md` |
| Account deletion flow | Pre-submission | Open |

**Resolved this session (2026-04-14):**
- ~~DeviceActivity sync trigger~~ → Option C: foreground + `intervalDidEnd` + BGProcessingTask (ADR-037)
- ~~Can DeviceActivityReport write to App Group?~~ → Yes — `UserDefaults(suiteName:)` works from extensions (ADR-033)
- ~~Nudge sending from monitor extension~~ → Strategy 1 (background URLSession); fallback Strategy 2 (App Group + BGProcessingTask) (ADR-034)
- ~~Monitoring re-registration on goal changes~~ → Debounced 1.5s (ADR-035)
- ~~DeviceActivityEvent naming~~ → `app.<bundle_id>`, `category.<id>`, `total`, `session.timeout` (ADR-036)
- ~~App Group secrets~~ → Anon key + JWT only; never service role key (ADR-038)
- ~~Which friends receive nudges~~ → All accepted friends, global trigger toggles (ADR-039)
- ~~Report string format~~ → `NudgeMessages.swift` + `_shared/messages.ts`; no emojis; app names; top 3 (ADR-040, ADR-041)
- ~~Per-friend trigger config~~ → Global toggles now; per-friend in backlog (ADR-039)
- ~~Concurrency (multiple triggers at once)~~ → Send separately; rate limit handles excess

**Previously resolved:**
- ~~Twilio account setup~~ → Trial mode, verified numbers only
- ~~APNs token storage~~ → Separate `device_tokens` table (deployed)
- ~~Rate limiting~~ → 10 nudges/friend/day, user's local timezone
- ~~NudgeType at send time~~ → NULL; set by friend's reply
- ~~STOP confirmation SMS~~ → None; Twilio handles it
- ~~Secrets location~~ → Edge Function secrets, not Vault. `Deno.env.get()` cannot read Vault.
- ~~SMS sender identity~~ → Messaging Service SID, not direct phone number
- ~~`receive-reply` 401~~ → Deploy with `--no-verify-jwt`; Twilio HMAC-SHA1 is the auth mechanism
- ~~Twilio signature validation failing~~ → `req.url` has wrong scheme + stripped path prefix behind Supabase proxy; reconstruct URL from `x-forwarded-proto` + host from `req.url` + `/functions/v1` prefix
