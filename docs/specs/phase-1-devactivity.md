# Phase 1 — DeviceActivity Pipeline

**Status:** `[~] In Progress`

---

## What We're Building and Why

Nudge's core value is automatic accountability — the app detects when a user is spending too much time on their phone and automatically notifies their friends, without the user having to do anything. Phase 1 builds the plumbing for that:

**Real-time threshold detection** — know the moment a user has been on their phone too long, or the moment they blow past a specific app/category goal, and fire a nudge to their friends.

Phase 2 handles usage display (see `specs/phase-2-dashboard.md`).

---

## Why Apple's Screen Time APIs Work the Way They Do

Apple treats Screen Time data as extremely sensitive — it reveals everywhere you've been, everything you've done, and how long you spent doing it. To prevent any app from silently exfiltrating this data to a server, Apple made a deliberate architectural decision: **no third-party app can directly read Screen Time data.** Ever.

Instead, Apple provides two controlled mechanisms:

- **`DeviceActivityMonitor` extension** — the OS calls your code when specific usage events occur (a schedule starts, a threshold is hit, a schedule ends). Your code reacts to these events but cannot query raw usage data.
- **`DeviceActivityReport` extension** — a SwiftUI view that Apple renders inside your app in a sandboxed process. It has access to raw usage data, but **only to display it on-device**. It cannot write to App Group containers, make network calls, or push data anywhere — this is enforced by the OS sandbox and cannot be worked around. See ADR-049.

The consequence for Nudge: **usage data cannot be synced to Supabase.** All cloud functionality is driven by threshold events from `DeviceActivityMonitor`. The `DeviceActivityReport` extension is used exclusively for the Phase 2 dashboard display.

---

## The Two Extensions

### `DeviceActivityMonitor` — Primary: Real-Time Trigger Detection

This is the most important extension for Nudge's core feature. Apple's OS instantiates it and calls methods on it when events you've configured occur:

- `intervalDidStart` — the monitoring day has begun (midnight)
- `eventDidReachThreshold(event:activity:)` — a usage threshold you defined has been hit
- `intervalDidEnd` — the monitoring day has ended (midnight)

You configure thresholds using `DeviceActivityEvent` objects — for example, "2 hours of total phone use" or "30 minutes on Instagram." When `eventDidReachThreshold` fires, the extension knows which threshold was crossed (via the event name) and can act on it.

**This is how Nudge detects that it's time to send a nudge to a friend.**

**What it CAN do:**
- Write to the App Group shared container (UserDefaults and FileManager both work)
- Initiate background `URLSession` transfers (OS manages after execution window closes)
- Post local `UNNotificationRequest`
- Interact with `ManagedSettingsStore` (app blocking — zero latency, no network)
- Schedule a `BGProcessingTask` for the main app

### `DeviceActivityReport` — Display Only (Phase 2)

This extension is a SwiftUI view that Apple renders in a sandboxed process inside your main app. It has access to raw Screen Time data (per-app durations, pickup counts, etc.) and can display it in any custom SwiftUI view. It **cannot** persist, export, or transmit this data — the sandbox blocks all I/O.

Phase 2 uses this extension to power the dashboard. See `specs/phase-2-dashboard.md` for its implementation.

---

## Full Data Flow

### Keeping Monitoring Armed (ADR-054)

A `DeviceActivityEvent` threshold fires **at most once per `startMonitoring` call**. iOS
does not reliably re-arm spent thresholds when a `repeats: true` daily interval rolls over
at midnight, so monitoring must be re-registered explicitly or the app goes silent after
its first triggered day.

Registration state lives in two App Group stamps written by `MonitoringPlan.register`:

| Key | Meaning |
|---|---|
| `nudge.monitoring.lastDay` | Local calendar day (`yyyy-MM-dd`) of the last successful `startMonitoring` |
| `nudge.monitoring.lastSignature` | Order-independent fingerprint of the monitored `GoalSummary` set |

Three independent paths re-arm, all bounded by those stamps so none can loop:

| Path | Runs when | Guard |
|---|---|---|
| Extension `intervalDidStart` | Midnight — **primary path; needs no app open** | `isRegistrationStale` |
| Extension `eventDidReachThreshold` | A trigger fires on a stale day | `isRegistrationStale` |
| App `refreshMonitoring` | Every foreground | `shouldRegister` (stamps **+** lapsed activities) |

The extension deliberately does *not* consult `DeviceActivityCenter.activities`: an
unreliable reading there would make it re-register on every callback forever. Restart
recovery is the app's job.

### Counting past activity + "fired today" dedup (ADR-054 amendment, 2026-11-23)

**Problem.** Without `includesPastActivity`, every mid-day re-registration (a goal edit,
a session-timeout change, restart recovery) restarts each threshold's count from zero.
A user 40 min into a 60 min limit who edits any goal gets another full 60 min.

**Rule 1: every event counts the day's past activity.** `MonitoringPlan.events(for:)`
builds every `DeviceActivityEvent` with `includesPastActivity: true` (iOS 17.4+; the
deployment target is 17.6, so no availability check). Re-registering at 2pm counts usage
since the interval started at midnight. At the midnight re-arm the new interval has no
past activity, so behaviour there is unchanged.

**Consequence.** A threshold that was already passed earlier today fires again,
immediately, on every re-registration. Without a guard that duplicates the local
notification **and the friend SMS**.

**Rule 2: side effects run at most once per day per (event, threshold).**
- **Store:** `Shared/FiredEventStore.swift`, App Group key `nudge.fired.<yyyy-MM-dd>`
  (`AppGroupKeys.firedKey(day:)`, prefix `AppGroupKeys.firedKeyPrefix = "nudge.fired."`).
  The value is a JSON `[String]` (sorted) of dedup keys. The day is
  `MonitoringPlan.dayStamp(for: now, calendar: .current)` at callback time.
- **Dedup key:** `"<eventName>@<thresholdSeconds>"`, e.g. `total@3600`,
  `session.timeout@2700`. Including the threshold is deliberate (user decision 2026-11-23):
  - raising a limit after it fired (1h → 2h) → the new key fires again at 2h;
  - lowering it below today's usage after it fired → fires once, immediately (the user is
    over the new limit);
  - re-registering with an unchanged limit → suppressed.
- **Test-and-set:** `markFired(_:onDay:) -> Bool` returns `true` only for the call that
  recorded the key. It is serialised with a lock because several thresholds can cross in
  the same instant after a re-registration.
- **Extension `eventDidReachThreshold`:** after matching the goal, it calls `markFired`.
  If that returns `false`, it logs `duplicate … suppressed` and skips the notification,
  the enqueue and the BG task request. The stale-day re-register safety net still runs on
  both paths.
- **Unmatched events** ("Nudge misconfigured") are deduped the same way with the key
  `"<eventName>@unmatched"`, so the warning cannot repeat on every re-registration.
- **Unreadable store values** read as empty: worst case is one duplicate, never a crash.
- **Pruning:** `prune(keepingDaysFrom:calendar:)` removes `nudge.fired.*` keys more than
  2 days before today, plus malformed keys under that prefix. Other keys are never
  touched. It is called from `MonitoringPlan.register`, which runs at least daily.

**Phase 3 note.** `feat/goals-core` (#18) already has an equivalent `nudge.fired.<day>`
store inside `GoalProgressStore`. When #13 is merged into #18, #18 adopts this store and
key format rather than keeping two.

**Done when:**
- Unit tests cover: `includesPastActivity` is true on every built event; the dedup key
  format; `markFired` test-and-set; per-day isolation; a changed threshold yields a new
  key; unreadable values read as empty; pruning keeps today and the 2 previous days and
  leaves unrelated keys alone.
- On device: use 30+ min toward a 1h goal, edit any goal → the goal fires at ~1h total
  usage, not 1h after the edit. After it fires, edit another goal → no second
  notification or SMS. Raise the limit to 2h → it fires again at 2h.

**Never re-register from data that failed to load (ADR-055).** `onForeground` re-registers
only when both the profile and goal fetches succeed. A failed fetch collapsing into an
empty goal list would register zero events and overwrite the App Group goal set — silently
disarming every trigger.

**Rule for future changes:** anything that decides *what* is monitored belongs in
`Shared/MonitoringPlan.swift`, which is compiled into both the app and the extension
(ADR-056). Do not re-declare it in either target.

### Nudge Trigger Flow (real-time)
```
User opens Instagram and uses it for 30 minutes
    ↓
DeviceActivityMonitor.eventDidReachThreshold fires
    ↓
Extension reads GoalSummary + friend list + secrets from App Group
Extension builds message: "Joshua just hit his 30-minute limit on Instagram."
Extension posts local notification
Extension writes PendingTrigger to App Group and schedules a BGProcessingTask
    (Strategy 1 — background URLSession from the extension — was validated
     non-functional on device 2026-09-06; see ADR-034)
    ↓
Main app drains the queue on foreground or via the nudge-trigger BGProcessingTask
    ↓
send-nudge Edge Function validates friend consent + rate limit
    ↓
Twilio sends SMS to friend: "Joshua just hit his 30-minute limit on Instagram."
```

---

## Nudge Trigger Strategy: Why Two Strategies

Because the monitor extension cannot make synchronous network calls, we have two approaches for getting the nudge sent, tested in order:

**Strategy 1 (preferred) — Background URL Session from monitor extension**

The extension initiates a `URLSession` with a background configuration. The OS manages the transfer and it can complete even after the extension's execution window closes. This gives near-instant nudge delivery — seconds after the threshold fires.

This must be validated on a physical device. If transfers complete reliably, Strategy 1 is the implementation.

**Strategy 2 (fallback) — App Group + BGProcessingTask**

If Strategy 1 does not work reliably:
1. Extension writes `PendingTrigger { eventName, timestamp }` to App Group
2. iOS wakes the main app in the background (typically 1–15 minutes)
3. Main app reads pending triggers, calls `send-nudge` for each, clears the list

**Latency expectations:**

| Scenario | Strategy 1 | Strategy 2 |
|---|---|---|
| Normal conditions | Seconds | 1–15 minutes |
| Battery/CPU pressure | Seconds | Up to 30 minutes |
| App force-quit | Seconds (extension still runs) | Until app reopens |

---

## App Group: Why It's Needed

The monitor extension runs in a separate sandboxed process from the main app. By default, it cannot communicate with the main app at all.

**App Groups** solve this. An App Group is a shared container that any target enrolled in the same group can read and write.

App Group ID: **`group.com.joshuaqn.Nudge`**

This ID must appear in the `.entitlements` file of:
- Main app target
- `NudgeActivityMonitor` extension target
- `NudgeActivityReport` extension target (needed for its entitlement even though it cannot write)

---

## App Group Secrets: Why and What

The monitor extension needs to call the Supabase Edge Function. It cannot access `Config.xcconfig`. Instead, the main app writes credentials to App Group UserDefaults at login, and the extension reads them at runtime.

**What to store:**
- `nudge.auth.supabaseUrl` — the project URL
- `nudge.auth.anonKey` — the Supabase anon key
- `nudge.auth.jwt` — the user's current session JWT

**Never store the service role key in App Group.** The monitor extension calls Edge Functions as the authenticated user. The service role key grants unrestricted DB access and must never leave the server.

The main app must refresh `nudge.auth.jwt` in App Group whenever the Supabase session token refreshes.

---

## Monitoring Re-Registration: Why It's Needed

`DeviceActivityCenter.startMonitoring` registers a schedule and a set of events. If the device restarts, monitoring stops and must be re-registered. If goals change, the event set must be rebuilt.

**`MonitoringRegistrationService`** owns this. It:
- Re-registers monitoring on every app foreground if `DeviceActivityCenter.shared.activities` is empty (catches restarts)
- Uses a **10-second debounce** when goals change — so rapid edits don't hammer `DeviceActivityCenter`
- Always registers a schedule even with an empty events dict — required so `DeviceActivityReport` (Phase 2) has a monitored period to query against

---

## Event Naming Scheme

`DeviceActivityEvent.Name` is a string token. When `eventDidReachThreshold` fires, the event name tells the extension which goal or trigger caused it:

| Goal / Trigger Type | Event name format | Example |
|---|---|---|
| App-specific goal | `app.<bundle_id>` | `app.com.instagram.Instagram` |
| Category goal | `category.<category_id>` | `category.7` |
| Total screen time goal | `total` | `total` |
| Session timeout (continuous use) | `session.timeout` | `session.timeout` |

The session timeout event fires based on the user's configured timeout setting (e.g. "send a nudge if I've been on my phone for 45 minutes straight"), not a DB goal.

---

## Nudge Message Format

Messages are built inside the monitor extension from `GoalSummary` data (read from App Group). The limit value and app name are both available at threshold-fire time:

| Trigger type | Message |
|---|---|
| App goal (60 min, Instagram) | "Joshua just hit his 60-minute limit on Instagram." |
| Total screen time (2hr) | "Joshua just hit his 2-hour daily screen time limit." |
| Session timeout (30 min) | "Joshua has been on his phone for 30 minutes straight." |

**Note:** Exact current usage beyond the threshold is not available inside `eventDidReachThreshold`. The threshold value is used as the effective usage figure. "Top apps" breakdown is not included in trigger messages.

---

## Prerequisites

- [x] Family Controls entitlement approved by Apple
- [x] DB schema deployed (`goal` table, RLS policies)
- [x] Physical device available (simulator does not support DeviceActivity APIs)
- [x] App Group identifier configured on all three targets

---

## Tasks

### Entitlement & Project Setup
- [x] Family Controls capability on main app target
- [x] App Groups (`group.com.joshuaqn.Nudge`) on main app target
- [x] `NudgeActivityMonitor` extension target created — Family Controls + App Groups
- [x] `NudgeActivityReport` extension target created — Family Controls + App Groups
- [x] Screen Time permission granted on device via `AuthorizationCenter`

### App Group Secrets
- [x] On login and token refresh, write `supabaseUrl`, `anonKey`, `jwt` to App Group

### `MonitoringRegistrationService`
- [x] `registerMonitoring(goals:sessionTimeoutMinutes:)` — builds events, calls `startMonitoring`
- [x] `reregisterIfLapsed()` — re-registers if `activities` is empty; call on every foreground
- [x] `goalDidChange()` — 10s debounced re-registration
- [x] Writes `[GoalSummary]` to `nudge.goals.active` in App Group after every registration

### `NudgeActivityMonitor` Extension
- [x] `eventDidReachThreshold`:
  1. Parses event name → matches `GoalSummary` from App Group
  2. Builds message from goal's `targetLabel` and `limitSeconds`
  3. Posts local `UNNotificationRequest` immediately
  4. Strategy 1: background `URLSession` POST to `send-nudge` for each accepted friend
  5. Strategy 2 fallback: writes `PendingTrigger` to App Group
- [x] `intervalDidEnd`: writes `midnightSyncNeeded` flag to App Group
- [x] `intervalDidStart`: clears day-scoped state

### Main App — NudgeTriggerService (Strategy 2 path)
- [ ] On `BGProcessingTask` wake, read `nudge.triggers.pending` from App Group
- [ ] For each pending trigger, call `send-nudge` Edge Function
- [ ] Clear processed triggers from App Group

### Validation (on-device)
- [ ] Strategy 1 confirmed: background URLSession POST from monitor extension reaches Supabase Edge Function logs
- [ ] If Strategy 1 fails: Strategy 2 path validated end-to-end

---

## Data Contracts

### App Group Container Keys

| Key | Type | Written by | Read by |
|---|---|---|---|
| `nudge.auth.supabaseUrl` | `String` | Main app (login / token refresh) | Monitor extension |
| `nudge.auth.anonKey` | `String` | Main app (login) | Monitor extension |
| `nudge.auth.jwt` | `String` | Main app (login / token refresh) | Monitor extension |
| `nudge.triggers.pending` | JSON `[PendingTrigger]` | Monitor extension (Strategy 2) | Main app `NudgeTriggerService` |
| `nudge.goals.active` | JSON `[GoalSummary]` | Main app (after registration) | Monitor extension |
| `nudge.friends.accepted` | JSON `[FriendSummary]` | Main app (on login / friend changes) | Monitor extension |
| `nudge.sync.midnightNeeded` | `Bool` | Monitor extension (`intervalDidEnd`) | Main app (on foreground) |
| `nudge.monitoring.lastDay` / `.lastSignature` | `String` | `MonitoringPlan.register` | Extension + app (staleness) |
| `nudge.fired.<yyyy-MM-dd>` | JSON `[String]` of `"<event>@<thresholdSeconds>"` | Monitor extension (`FiredEventStore`) | Monitor extension (dedup) |

```swift
struct PendingTrigger: Codable {
    let eventName: String   // e.g. "app.com.instagram.Instagram"
    let timestamp: Date
}

struct GoalSummary: Codable {
    let goalId: Int
    let eventName: String           // matches DeviceActivityEvent.Name raw value
    let limitSeconds: Int
    let targetLabel: String         // e.g. "Instagram", "Social Media", "All Apps"
    let appBundleId: String?        // nil for category / total / session.timeout goals
}

struct FriendSummary: Codable {
    let id: Int
}
```

---

## Testing Strategy

### Unit Tests
- `NudgeMessages.swift` — all message format methods with known inputs
- `PendingTrigger` / `GoalSummary` — Codable encode/decode round-trips
- `MonitoringRegistrationService` debounce — rapid `goalDidChange()` calls produce only one registration
- Event name parsing — `"app.com.instagram.Instagram"` → correct goal type and bundle ID extracted

### Device Testing (manual)
1. **Permission request** — `AuthorizationCenter.shared.requestAuthorization` shows system prompt; granted/denied handled correctly
2. **Monitoring registration** — `startMonitoring` succeeds; events appear in `DeviceActivityCenter.shared.activities`
3. **Threshold detection** — set a short threshold (e.g. 1 min), use an app, confirm `eventDidReachThreshold` fires
4. **Strategy 1 validation** — confirm background URLSession POST reaches Supabase Edge Function logs
5. **Nudge message content** — confirm message contains correct app name and limit minutes
6. **Restart recovery** — register monitoring, restart device, open app, confirm re-registration

---

## Acceptance Criteria

- [ ] When a `DeviceActivityEvent` threshold fires, `eventDidReachThreshold` is called in the monitor extension
- [ ] Monitor extension sends a nudge (Strategy 1) OR writes to App Group for pickup (Strategy 2) — confirmed via Supabase Edge Function logs
- [ ] Nudge SMS message contains the correct app/goal name and limit duration
- [ ] Denying Screen Time permission shows a graceful degraded state — no crash
- [ ] Monitoring resumes automatically after device restart
- [ ] Goal changes trigger re-registration within 15 seconds of the user finishing edits
