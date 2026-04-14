# Nudge — Project Status

> **Read this first every session.** Update it at the end of each session.
> Last updated: 2026-04-13

---

## Current Phase

**Phase 5 — Social (Friends + SMS Nudges)** `[~] In Progress`

Backend (Edge Functions) and iOS service/UI layer are complete. Remaining work:
- APNs iOS registration (enable capability, register, store device token)
- User phone number field in Settings
- Nudge trigger system (blocked on Phase 1 — Family Controls entitlement)
- Nudge trigger settings UI
- Real-time nudge status updates in UI

**Phase 1 — DeviceActivity Pipeline** `[! Blocked]`

Family Controls entitlement applied for — awaiting Apple approval. Required for all DeviceActivity work and nudge trigger system.

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
| 1 | DeviceActivity Pipeline | `[! Blocked]` — needs Family Controls entitlement approval |
| 2 | Dashboard | `[ ]` — depends on Phase 1 data in Supabase |
| 3 | Goals | `[ ] Ready` — no DeviceActivity dependency |
| 4 | Notifications & Interventions | `[ ]` — depends on Phase 1 + 3 |
| 5 | Social (Friends + SMS) | `[~] In Progress` — backend done; trigger system blocked on Phase 1 |

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

## Phase 1 — DeviceActivity Pipeline `[! Blocked]`

**Blocker:** Family Controls entitlement applied for but not yet approved. Required for all DeviceActivity and ManagedSettings work. Must test on real device — simulator does not support these APIs.

**Action required:** Wait for Apple approval. Approval can take days to weeks.

See `specs/phase-1-devactivity.md` for full spec.

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
- [x] `supabase/functions/_shared/twilio.ts` — `sendSms`, `validateTwilioSignature` (HMAC-SHA1), `parseFormBody`, STOP/YES/NO keyword sets
- [x] `supabase/functions/_shared/apns.ts` — `sendApnsPush`, `generateApnsJwt` (ES256 JWT with Web Crypto), direct HTTP/2 to APNs
- [x] `supabase/functions/send-consent/index.ts` — DB webhook handler, consent SMS with first name lookup
- [x] `supabase/functions/send-nudge/index.ts` — auto-trigger handler, timezone-aware rate limit, nullable type insert
- [x] `supabase/functions/receive-reply/index.ts` — Twilio inbound webhook, consent + nudge reply routing, APNs + SMS delivery
- [x] `supabase/functions/deno.json` — compiler options for Deno LSP
- [x] `.vscode/settings.json` — Deno language server for `supabase/functions/` (IDE only)

**DB Migrations:**
- [x] `supabase/migrations/001_device_tokens.sql` — `device_tokens` table with RLS
- [x] `supabase/migrations/002_nudge_type_nullable.sql` — `nudge.type` column made nullable

**Deployment:**
- [x] All three Edge Functions deployed to Supabase
- [x] DB migrations run in Supabase SQL editor

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
| DeviceActivity sync trigger (background task vs on-foreground) | Phase 1 | Open — in spec |
| Can DeviceActivityReport extension write to App Group container? | Phase 1 | Open — in spec |
| Notification schedule for why reminders | Phase 4 | Open — in spec |
| Unlock prompt feasibility | Phase 4 | `specs/phase-4-notifications.md` |
| Nudge trigger architecture (which DeviceActivity callbacks) | Phase 5E | Open — in spec |
| Which friends receive which trigger types | Phase 5E | Open — in spec |
| Report string format per trigger type | Phase 5E | Open — in spec |
| Per-friend trigger configuration vs all-friends-all-triggers | Phase 5E | Open — in spec |
| Account deletion flow | Pre-submission | Open |

**Resolved this session:**
- ~~Twilio account setup~~ → Trial mode, verified numbers only
- ~~APNs token storage~~ → Separate `device_tokens` table (deployed)
- ~~Rate limiting~~ → 10 nudges/friend/day, user's local timezone
- ~~NudgeType at send time~~ → NULL; set by friend's reply
- ~~STOP confirmation SMS~~ → None; Twilio handles it
