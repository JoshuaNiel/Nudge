# Notifications

Strategy for all notifications in the Nudge app — both local and push.

---

## Two Systems

| Type | Use Case | Mechanism |
|---|---|---|
| Local notifications | Usage thresholds, goal reminders, why reminders, unlock prompts | `UserNotifications` framework, scheduled on-device |
| Push notifications (APNs) | Delivering a friend's SMS reply to the app user | APNs via Supabase Edge Function |

Local notifications require no server. Push notifications require APNs setup and a server-side trigger.

**Note on social nudges:** Outbound nudges to friends are sent via SMS (Twilio), not push notifications — friends don't have the app. APNs is used only to deliver the friend's reply *back* to the app user. The app user also receives the reply as an SMS to their phone number stored in `profiles.phoneNumber`. See `social.md` for the full flow.

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

Used to deliver a friend's SMS reply back to the app user when the app is installed.

> TODO: Document APNs setup before Phase 6.
> - APNs certificate or token-based auth (p8 key)? Token-based is recommended.
> - How are device tokens collected and stored? (A `device_tokens` table in Supabase, or stored on `profiles`)
> - The `receive-reply` Edge Function (triggered by Twilio inbound webhook) sends the APNs push after updating the nudge row.

### Proposed Flow
1. Twilio inbound webhook fires when a friend replies to the SMS nudge
2. `receive-reply` Edge Function maps the reply to the correct nudge row
3. Edge Function sends APNs push to the app user's device token
4. Edge Function also sends SMS to `profiles.phoneNumber` as a fallback

> TODO: Design the push payload. Should it deep-link into the nudge history screen in the app?

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
