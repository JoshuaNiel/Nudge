# Notifications

Strategy for all notifications in the Nudge app — both local and push.

---

## Two Systems

| Type | Use Case | Mechanism |
|---|---|---|
| Local notifications | Usage thresholds, goal reminders, why reminders, unlock prompts | `UserNotifications` framework, scheduled on-device |
| Push notifications (APNs) | Social nudges from friends | APNs via Supabase Edge Functions |

Local notifications require no server. Push notifications require APNs setup and a server-side trigger.

---

## Local Notifications

### Usage Threshold Alerts
Triggered when the user hits a configured daily or session time limit for an app or category.

> TODO: Define how threshold monitoring works.
> - Is this done via `DeviceActivityMonitor` extension (Apple fires a callback when a threshold is hit)?
> - Or does the main app poll usage data and schedule notifications itself?
> - `DeviceActivityMonitor` is the correct Apple mechanism — document how to configure `DeviceActivitySchedule` and `DeviceActivityEvent` for this.

### Goal Reminder Notifications
Periodic reminders tied to active goals (e.g. "You've set a 1hr daily limit on Instagram").

> TODO: Define schedule and frequency.
> - When are these sent? Morning? When the app is opened?
> - Are they configurable by the user?

### Why Reminder Notifications
Motivational messages from the user's `why_reminders` table, sent periodically to reinforce intentions.

> TODO: Define trigger and selection logic.
> - How often are these sent?
> - Random selection, round-robin, or time-since-last-shown logic?
> - Are these scheduled at app launch, or via a background task?

### Unlock Prompt
A prompt shown when the user unlocks their phone asking whether they're being productive or browsing.

> TODO: Determine if this is technically feasible.
> - iOS does not allow apps to intercept the unlock event directly.
> - Closest mechanism: a notification that fires on a schedule (e.g. every morning) or via `DeviceActivityMonitor` when the screen turns on.
> - Research whether `LAContext` or any Screen Time API supports an unlock hook.

---

## Push Notifications (APNs)

Used exclusively for the social layer — shame and encouragement nudges between friends.

> TODO: Document APNs setup before Phase 6.
> - APNs certificate or token-based auth (p8 key)? Token-based is recommended.
> - How are device tokens collected and stored? (Likely a `device_tokens` table in Supabase)
> - What triggers a push? A Supabase Edge Function listening to inserts on the `nudges` table via a database webhook?

### Proposed Flow
1. User A taps "Nudge" on User B in the friends list
2. App inserts a row into `nudges` table
3. Supabase database webhook triggers an Edge Function
4. Edge Function sends APNs push to User B's device token(s)

> TODO: Design the Edge Function. What payload does the push notification carry? Does it deep-link into the app?

---

## Notification Permissions

> TODO: Document when and how notification permission is requested.
> - Request at onboarding or defer until the first feature that needs it?
> - What happens if the user denies permission — which features degrade?

---

## Open Questions

> TODO: Answer before Phase 4 (Notifications & Interventions):
> - Is the unlock prompt feasible, and if so, what's the exact mechanism?
> - How does `DeviceActivityMonitor` fire threshold callbacks — is the main app running, or does the extension handle it independently?
> - Can local notifications be scheduled from within a `DeviceActivityMonitor` extension?
