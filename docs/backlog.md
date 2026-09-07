# Backlog

Parking lot for future features and known bugs. Nothing here is actively scheduled — move items into a phase spec when they become real work.

---

## Phase 5 — Remaining Social Work

- **APNs iOS registration** — Enable Push Notifications capability in Xcode, call `registerForRemoteNotifications()` in `NudgeApp.swift`, implement `DeviceTokenService` that upserts the token into `device_tokens`. Handle incoming push payload to deep-link to `NudgeHistoryView` for the relevant friend (nudge_id in payload).

- **User phone number in Settings** — Add phone number field to Settings → Profile. E.164 validation. Save to `profile.phone_number` via `AuthService.updateProfile`. Display note explaining it's used only for SMS reply delivery.

- **Nudge trigger system** — The core of the social feature. Automatically sends nudges when: (a) continuous phone usage exceeds a threshold (e.g. 60 min), (b) a goal is breached, (c) daily report time fires. Requires Phase 1 (Family Controls entitlement). Needs its own spec before implementation — see open questions in `specs/phase-5-social.md` §5E.

- **Nudge trigger settings UI** — Settings screen for configuring which triggers are active, thresholds (time-on-phone minutes, daily total hours), and daily report time. Per-friend trigger configuration is a stretch goal.

- **Real-time nudge status updates** — Subscribe to `nudge` table changes via Supabase Realtime so `NudgeHistoryView` updates automatically when `status` changes to `replied` or `reply_delivered`.

---

## Future Features

- **Per-friend trigger configuration** — Let users configure which trigger types each friend receives independently (e.g. Mom gets daily report only, Jake gets goal breach only). Requires a `friend_trigger` junction table `(friend_id, trigger_type, enabled)` and additional Settings UI per friend. Current implementation uses global trigger toggles (all friends receive all active triggers). Design for this migration by keeping trigger settings in a separate table from the start.
- **Mac sync** — sync usage data and goals across Mac using the same Supabase backend
- **WidgetKit** — home/lock screen widget showing today's total usage or goal progress
- **App blocking** — hard-block apps when a goal limit is hit (requires ManagedSettings entitlement, separate Apple approval)
- **Location-based settings lock** — lock app settings when the user is at a specified location (e.g. work); implemented via CoreLocation check when settings screen opens
- **Notification customization** — let users configure why reminder frequency and time of day
- **Nudge trigger: daily total** — Send nudge when user's total screen time for the day exceeds N hours. Requires a `DeviceActivityEvent` scoped to all apps with a daily threshold. Not in initial trigger set but fits the existing architecture cleanly.

---

## Infrastructure Tasks

- **Service protocol + mock infrastructure** — Add a `Protocol` alongside each service (`GoalServiceProtocol`, `UsageServiceProtocol`, `CategoryServiceProtocol`, `GoalEvaluationServiceProtocol`). Update ViewModel inits to accept the protocol type, defaulting to the real service. This unlocks ViewModel unit tests (loading state, error handling, delete behavior) as described in `docs/conventions.md` → Service Protocols and Mocking.

---

## Phase 1 — DeviceActivity

- **App-specific goal monitoring (Phase 3 dependency)** — `MonitoringRegistrationService` skips `app.*` and `category.*` goals because `DeviceActivityEvent` requires `ApplicationToken`, which can only be obtained from `FamilyActivityPicker`. Phase 3 (Goals UI) must store the `FamilyActivitySelection` to App Group after the user picks apps, and extend `GoalSummary` with `applicationTokensData: Data?` so the registration service can use them.

- **Category goal monitoring (Phase 3 dependency)** — Our categories are user-defined groups of apps, not Apple's built-in ActivityCategoryTokens. The `DeviceActivityEvent` needs `applications: Set<ApplicationToken>` with all member apps' tokens. `GoalSummary` needs a `categoryBundleIds: [String]` field populated from `app_category_member` so the monitor service can create events covering all member apps.

- **True continuous-session detection** — The current `session.timeout` event fires when accumulated daily total usage hits the threshold, not when continuous unbroken usage hits the threshold. True "45 minutes straight" detection requires tracking screen-lock/unlock events or using multiple short schedules. Explore using `DeviceActivitySchedule.warningTime` or multiple overlapping schedules in a future iteration.

- **Extension shared types** — `GoalSummary`, `FriendSummary`, message formatting logic, and App Group key constants are duplicated between the main app and `NudgeMonitor/MonitorExtension.swift`. Should be moved to a shared Swift framework target when the extension targets are created.

- **App display names in usage data** — The `DeviceActivityReport` extension currently derives app names as the last component of the bundle ID (e.g. "Instagram" from "com.instagram.Instagram"). Consider building a lookup table of known app names or querying the App Store API for better names in Phase 2.

## Security

- **`send-consent` trusts its webhook payload — SMS-abuse vector.** `send-consent` sends the consent SMS based purely on the POST body (`type === "INSERT"`, `status === "pending"`), and does not verify the request actually came from the Supabase DB webhook. Its gateway `verify_jwt` accepts any valid project token, including the **public anon key** (shipped in the app). So a caller with the anon key could POST a crafted payload and make the function text arbitrary phone numbers — SMS spam, Twilio cost, and A2P-compliance risk. (Not a DB breach: the function only reads a friend row + profile name and sends an SMS; the service_role key stays server-side.) **Note:** `send-nudge` is *not* affected — it validates the user via `getUser()` and checks friend ownership, so it's safe even with `--no-verify-jwt`.
  **Fix (pick one, in order of preference):**
  1. **Re-validate against the DB before sending** — with the service client, re-fetch the friend row by `record.id` and confirm it exists and is `status = 'pending'`; send only then. Defeats spoofed/invented recipients using data already trusted.
  2. **Shared-secret header** — configure the webhook to send a secret header (e.g. `x-webhook-secret`) and reject the request if it doesn't match an Edge Function secret. Simple, blocks direct anon-key calls.
  3. Add lightweight per-user/per-number rate limiting as defense-in-depth against abuse volume.

## Auth

- **No in-app "Forgot Password" flow + no reset deep link.** A user who forgets their email/password has no in-app recovery path (surfaced when a test user signed out and couldn't get back in). Build: a "Forgot password?" action on `AuthView` calling `supabase.auth.resetPasswordForEmail(email, redirectTo:)`, register the `nudge://` URL scheme, configure Site URL + Redirect URLs in Supabase, and handle `.onOpenURL` in `NudgeApp` to complete recovery (set session → prompt for a new password). Pairs with the email-confirmation deep-link item below. Interim recovery: reset a password via the Auth Admin API with the service_role key.
- **Sign in with Apple is not configured on the Supabase backend.** `AuthView` shows a "Sign in with Apple" button and `AuthService.signInWithApple` is implemented, but the Apple provider isn't enabled/configured in Supabase Auth (Dashboard → Authentication → Providers → Apple: Service ID, Team ID, Key ID, `.p8` key), so it fails at runtime. Either configure the provider or hide the button until it's set up. Note: App Store guidelines require Apple sign-in if other third-party auth is offered (ADR-002).

## Security (tracked debt)

- **Re-enable `send-nudge` gateway `verify_jwt` once Supabase fixes ES256 support.** `send-nudge` is deployed with `--no-verify-jwt` because the Edge Functions gateway currently can't verify asymmetric (ES256) user tokens — a known Supabase platform bug (supabase/supabase #44530, #42244) where the gateway hard-expects legacy HS256. Auth is enforced in-function via `getUser()` + friend-ownership (secure; matches ADR-031/receive-reply and Supabase's own recommendation). When Supabase ships gateway ES256 verification, redeploy `send-nudge` with `verify_jwt` on to restore defense-in-depth.

## Known Bugs / Tech Debt

- **Settings Save bar rides up with the keyboard.** The pinned Save button (`SettingsView.saveBar` via `.safeAreaInset(edge: .bottom)`) moves up above the keyboard when a field is focused. Desired behavior: pin it like the tab bar — stays at the physical bottom (keyboard covers it) while the Form still scrolls the focused field into view. A ZStack + `.ignoresSafeArea(.keyboard)` on the bar was attempted but didn't pin reliably and added layout churn (NaN/List-margin warnings), so it was reverted. Options to try: `.toolbar(placement: .bottomBar)`, a `UIViewRepresentable`/keyboard-height observer to offset manually, or a custom `safeAreaInset` that measures keyboard height. Needs device iteration.

- **Email confirmation deep link not wired up** — Supabase sends a `localhost` confirmation URL. Fix: register `nudge://` URL scheme, set Site URL + Redirect URLs in Supabase dashboard, handle `.onOpenURL` in `NudgeApp.swift` calling `supabase.auth.session(from: url)`. Email confirmation is currently disabled in Supabase for development.
