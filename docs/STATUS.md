# Nudge — Project Status

> **Read this first every session.** Update it at the end of each session.
> Last updated: 2026-04-13

---

## Current Phase

**Phase 1 — DeviceActivity Pipeline** `[ ] Ready to start`

Family Controls is a restricted entitlement requiring both a paid Apple Developer account ($99/year) and explicit Apple approval — required for development builds too, not just App Store submission. Request at developer.apple.com → Additional Capabilities. Must test on a real device; simulator does not support these APIs.

**Parallel track: Phase 3 — Goals** `[ ] Ready to start`

---

## Phase Summary

| Phase | Name | Status |
|---|---|---|
| 0 | Auth & Onboarding | `[x] Done` |
| 1 | DeviceActivity Pipeline | `[! Blocked]` — needs paid developer account + Family Controls approval |
| 2 | Dashboard | `[ ]` — depends on Phase 1 data in Supabase |
| 3 | Goals | `[ ] Ready` — no DeviceActivity dependency |
| 4 | Notifications & Interventions | `[ ]` — depends on Phase 1 + 3 |
| 5 | Social (Friends + SMS) | `[ ]` — depends on Twilio setup |

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

**Known gaps (not blocking):**
- [ ] Email confirmation deep link (`nudge://` URL scheme) — see `specs/phase-0-auth-gaps.md` TODO list
- [ ] `AppUsage.swift` and `Goal.swift` models don't yet match DB column names — fix in Phase 2 and 3 respectively

---

## Phase 1 — DeviceActivity Pipeline `[! Blocked]`

**Blocker:** Family Controls entitlement not yet applied for. Required for all DeviceActivity and ManagedSettings work.

**Action required:** Apply for entitlement at developer.apple.com. Approval can take days to weeks.

See `specs/phase-1-devactivity.md` for full spec.

---

## Phase 3 — Goals `[ ] Ready to start`

No DeviceActivity dependency. Can be built against mock usage data for now; goal evaluation against real data hooks in when Phase 1 is complete.

See `specs/phase-3-goals.md` for full spec.

---

## Open Decisions

These need to be resolved before the relevant phase begins. See `decisions.md` for settled decisions.

| Decision | Needed By | Logged In |
|---|---|---|
| DeviceActivity sync trigger (background task vs on-foreground) | Phase 1 | `specs/phase-1-devactivity.md` |
| Can DeviceActivityReport extension write to App Group container? | Phase 1 | `specs/phase-1-devactivity.md` |
| Notification schedule for why reminders (random vs round-robin, frequency) | Phase 4 | `specs/phase-4-notifications.md` |
| Unlock prompt feasibility | Phase 4 | `specs/phase-4-notifications.md` |
| Twilio account setup + number provisioning | Phase 5 | `specs/phase-5-social.md` |
| APNs token storage (device_tokens table vs profiles column) | Phase 5 | `specs/phase-5-social.md` |
| Account deletion flow | Pre-submission | `docs/auth.md` |
