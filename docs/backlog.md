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

## Known Bugs / Tech Debt

- **Email confirmation deep link not wired up** — Supabase sends a `localhost` confirmation URL. Fix: register `nudge://` URL scheme, set Site URL + Redirect URLs in Supabase dashboard, handle `.onOpenURL` in `NudgeApp.swift` calling `supabase.auth.session(from: url)`. Email confirmation is currently disabled in Supabase for development.
