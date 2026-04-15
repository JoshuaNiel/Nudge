# Phase 1 — DeviceActivity Pipeline

**Status:** `[ ] Ready to start`

---

## What We're Building and Why

Nudge's core value is automatic accountability — the app detects when a user is spending too much time on their phone and automatically notifies their friends, without the user having to do anything. To do that, the app needs two things:

1. **Real-time threshold detection** — know the moment a user has been on their phone for too long straight, or the moment they blow past their specif app/category goal.
2. **Usage history** — store daily per-app usage data in Supabase so the dashboard can show trends, the daily morning report can pull yesterday's stats, and goal progress can be tracked over time.

Phase 1 builds the plumbing for both. Without it, Phases 2–5E have no data to work with.

---

## Why Apple's Screen Time APIs Work the Way They Do

Apple treats Screen Time data as extremely sensitive — it reveals everywhere you've been, everything you've done, and how long you spent doing it. To prevent any app from silently exfiltrating this data to a server, Apple made a deliberate architectural decision: **no third-party app can directly read Screen Time data.** Ever.

Instead, Apple provides two controlled mechanisms:

- **`DeviceActivityMonitor` extension** — the OS calls your code when specific usage events occur (a schedule starts, a threshold is hit, a schedule ends). Your code reacts to these events but cannot query raw usage data.
- **`DeviceActivityReport` extension** — a SwiftUI view that Apple renders inside your app in a sandboxed process. It has access to raw usage data, but only to display it. It cannot make network calls or push data anywhere on its own.

The consequence for Nudge is that **the main app cannot directly read how long the user has been on their phone.** All data flows through these two extensions, which then hand off to the main app via a shared App Group container.

---

## The Two Extensions

### `DeviceActivityMonitor` — Primary: Real-Time Trigger Detection

This is the most important extension for Nudge's core feature. You create it as a new Xcode target. Apple's OS instantiates it and calls methods on it when events you've configured occur:

- `intervalDidStart` — the monitoring day has begun (midnight)
- `eventDidReachThreshold(event:activity:)` — a usage threshold you defined has been hit
- `intervalDidEnd` — the monitoring day has ended (midnight)

You configure thresholds using `DeviceActivityEvent` objects — for example, "30 minutes of total phone use" or "30 minutes on Instagram specifically." When `eventDidReachThreshold` fires, the extension knows which threshold was crossed (via the event name) and can act on it.

**This is how Nudge detects that it's time to send a nudge to a friend.**

**Critical constraint:** The monitor extension **cannot make outbound network calls.** Apple enforces this at the OS level — it's not a guideline, it's a hard sandbox restriction. This means the extension cannot call the Supabase `send-nudge` Edge Function directly. Instead, it either uses a background URL session (which the OS manages outside the extension's execution window) or writes a pending trigger to a shared container for the main app to pick up. See "Nudge Trigger Strategy" below.

**What it CAN do directly:**
- Post local notifications (confirmed supported from monitor extensions)
- Write to the App Group shared container
- Interact with `ManagedSettingsStore` (e.g. block an app immediately when a goal is hit — zero latency, OS-level, no network needed)
- Schedule a `BGProcessingTask` for the main app

### `DeviceActivityReport` — Secondary: Usage Data Extraction

This extension is a SwiftUI view that Apple renders in a sandboxed process inside your main app. It has access to raw Screen Time data (per-app durations, pickup counts, etc.). When your main app hosts this view, the extension reads that data and can write a structured summary to the App Group container for the main app to pick up and upload to Supabase.

**This is how Nudge gets per-app daily usage data into Supabase** for the dashboard, goal progress, and the daily report nudge.

The main app hosts a zero-size `DeviceActivityReport` view that always renders silently in the background. Every time the extension renders, it writes fresh usage data to the App Group. The main app then reads it and upserts to Supabase.

---

## Full Data Flow

### Nudge Trigger Flow (real-time)
```
User opens Instagram and uses it for 30 minutes
    ↓
DeviceActivityMonitor.eventDidReachThreshold fires
    ↓
Extension reads friend list + secrets from App Group
Extension posts local notification (and sends text if user has given phone number) to alert the user
Extension attempts Strategy 1: background URLSession → send-nudge Edge Function
    (if Strategy 1 fails on device) → writes PendingTrigger to App Group,
                                       schedules BGProcessingTask
    ↓
send-nudge Edge Function validates friend consent + rate limit
    ↓
Twilio sends SMS to friend: "Josh just passed his 30-minute limit on Instagram..."
```

### Usage History Flow (for dashboard + daily report)
```
User uses apps throughout the day
    ↓
App foregrounds (or midnight fires, or BGProcessingTask wakes app)
    ↓
Main app hosts DeviceActivityReport view (renders silently, even zero-size)
    ↓
DeviceActivityReport extension reads Apple's usage data,
writes [PendingUsageEntry] JSON to App Group container
    ↓
Main app reads from App Group
    ↓
Upserts into Supabase: app table + usage table (per-app, per-day totals)
    ↓
Dashboard, goal progress, and daily report nudge all query this data
```

---

## Nudge Trigger Strategy: Why Two Strategies

Because the monitor extension cannot make synchronous network calls, we have two approaches for getting the nudge sent, tested in order:

**Strategy 1 (preferred) — Background URL Session from monitor extension**

The extension initiates a `URLSession` with a background configuration. The OS manages the transfer and it can complete even after the extension's execution window closes. This gives near-instant nudge delivery — seconds after the threshold fires.

This must be validated on a physical device. The `DeviceActivityMonitor` sandbox may restrict background URL sessions. If transfers complete reliably, Strategy 1 is the implementation.

**Strategy 2 (fallback) — App Group + BGProcessingTask**

If Strategy 1 does not work reliably:
1. Extension writes `PendingTrigger { eventName, timestamp }` to App Group
2. Extension schedules a `BGProcessingTask`
3. iOS wakes the main app in the background (typically 1–15 minutes)
4. Main app reads pending triggers, calls `send-nudge` for each, clears the list

Both strategies are implemented. Strategy 1 is tested first. If it works, Strategy 2 code stays as a fallback but is never hit in practice.

**Latency expectations:**

| Scenario | Strategy 1 | Strategy 2 |
|---|---|---|
| Normal conditions | Seconds | 1–15 minutes |
| Battery/CPU pressure | Seconds | Up to 30 minutes |
| App force-quit | Seconds (extension still runs) | Until app reopens |

A 5–15 minute delay on an accountability nudge is less than ideal — the more instant, the more effective. Strategy 2 is a fallback if we cannot get that to work.

---

## App Group: Why It's Needed

The monitor extension and the report extension both run in separate sandboxed processes from the main app. By default, they cannot communicate with each other or with the main app at all.

**App Groups** solve this. An App Group is a shared container on disk that any target enrolled in the same group can read and write. It's provisioned through Apple's developer portal (Xcode handles this automatically via the capability). Only targets signed with your certificate and enrolled in the group can access it.

App Group ID: **`group.com.joshuaqn.Nudge`**

This ID must appear in the `.entitlements` file of:
- Main app target
- `DeviceActivityMonitor` extension target
- `DeviceActivityReport` extension target

---

## App Group Secrets: Why and What

The monitor extension needs to call the Supabase Edge Function. It cannot access `Config.xcconfig` (that's only available at build time in the main app). Instead, the main app writes the necessary credentials to App Group UserDefaults at login, and the extension reads them at runtime.

**What to store:**
- `nudge.auth.supabaseUrl` — the project URL
- `nudge.auth.anonKey` — the Supabase anon key (public by design — already in the app bundle)
- `nudge.auth.jwt` — the user's current session JWT

**Why this is safe:** App Groups are locked to your app's certificate and entitlement. No other app on the device can read them. JWTs expire, so even if the device were compromised, the window of exposure is limited.

**Never store the service role key in App Group.** The monitor extension calls Edge Functions as the authenticated user. The Edge Function uses its own service role for DB operations server-side. The service role key grants unrestricted DB access and must never leave the server.

The main app must refresh `nudge.auth.jwt` in App Group whenever the Supabase session token refreshes.

---

## Monitoring Re-Registration: Why It's Needed

`DeviceActivityCenter.startMonitoring` registers a schedule and a set of events. If the device restarts, monitoring stops and must be re-registered. If goals change, the event set must be rebuilt and monitoring re-started with the new thresholds.

**`MonitoringRegistrationService`** owns this. It:
- Re-registers monitoring on every app foreground if `DeviceActivityCenter.shared.activities` is empty (catches restarts)
- Uses a **10-second debounce** when goals change — so a user rapidly updating goals doesn't hammer `DeviceActivityCenter` on every frame

---

## Event Naming Scheme

`DeviceActivityEvent.Name` is a string token. When `eventDidReachThreshold` fires, the event name tells the extension which goal or trigger caused it. We use a structured format:

| Goal / Trigger Type | Event name format | Example |
|---|---|---|
| App-specific goal | `app.<bundle_id>` | `app.com.instagram.Instagram` |
| Category goal | `category.<category_id>` | `category.7` |
| Total screen time goal | `total` | `total` |
| Session timeout (continuous use) | `session.timeout` | `session.timeout` |

The session timeout event is special — it's not tied to a goal in the DB. It fires based on the user's "friend notification timeout" setting (e.g. "send a nudge if I've been on my phone for 45 minutes straight").

---

## Usage Sync: When and How Often

Usage data is synced to Supabase on three triggers (Option C — all three):

| Trigger | Why |
|---|---|
| App foreground | Fresh intra-day data for dashboard + goal progress. Running the same upsert twice is harmless. |
| `intervalDidEnd` at midnight | Captures final daily totals even if the app was never opened that day. |
| `BGProcessingTask` (safety net) | Covers edge cases where neither of the above fires reliably. |

The upsert pattern (`on conflict (user_id, date, app_id) do update`) makes all three idempotent — running the sync multiple times per day always produces the correct result.

**This gives intra-day progress tracking for free.** Every time the user opens the app, the usage totals are refreshed. "You've used 22 of your 30 minutes on Instagram today" is accurate as of the last app open.

---

## Prerequisites

- [x] Family Controls entitlement approved by Apple
- [x] DB schema deployed (`usage` table, `app` table, RLS policies)
- [x] Physical device available (simulator does not support DeviceActivity APIs)
- [ ] App Group identifier configured on all targets (`group.com.joshuaqn.Nudge`)

---

## Tasks

### Entitlement & Project Setup
- [x] Family Controls entitlement approved
- [ ] Add **Family Controls** capability to main app target (Signing & Capabilities → + Capability → "Family Controls")
- [ ] Add **App Groups** capability to main app target; set ID: `group.com.joshuaqn.Nudge`
- [ ] Create **`DeviceActivityMonitor`** extension target
  - Add Family Controls + App Groups (`group.com.joshuaqn.Nudge`) capabilities
- [ ] Create **`DeviceActivityReport`** extension target
  - Add Family Controls + App Groups (`group.com.joshuaqn.Nudge`) capabilities
- [ ] Confirm all three `.entitlements` files contain `group.com.joshuaqn.Nudge` under `com.apple.security.application-groups`

### Permission Request
- [ ] Implement Screen Time permission request using `AuthorizationCenter.shared.requestAuthorization(for: .individual)`
- [ ] Wire up to `PermissionsView` — show "Screen Time access required" if denied
- [ ] Gate usage-dependent features on authorization status

### App Group Secrets Setup
- [ ] On login and on every session token refresh, write to App Group UserDefaults:
  ```swift
  let defaults = UserDefaults(suiteName: "group.com.joshuaqn.Nudge")
  defaults?.set(supabaseUrl, forKey: "nudge.auth.supabaseUrl")
  defaults?.set(anonKey,     forKey: "nudge.auth.anonKey")
  defaults?.set(jwt,         forKey: "nudge.auth.jwt")
  ```
- [ ] Never write the service role key to App Group

### `MonitoringRegistrationService`
- [ ] Create `MonitoringRegistrationService` in the main app target
- [ ] `registerMonitoring(goals: [GoalSummary], sessionTimeoutMinutes: Int?)` — builds the full `DeviceActivityEvent` set and calls `DeviceActivityCenter.shared.startMonitoring`
- [ ] `reregisterIfLapsed()` — checks `DeviceActivityCenter.shared.activities`; if empty and permission granted, re-registers. Call on every app foreground.
- [ ] `goalDidChange()` — debounced 10s; cancels and restarts a Task that calls `registerMonitoring`
- [ ] Write current `[GoalSummary]` to `nudge.goals.active` in App Group after every registration so the monitor extension can read goal metadata

### `DeviceActivityMonitor` Extension
- [ ] Subclass `DeviceActivityMonitorExtension`
- [ ] `eventDidReachThreshold`:
  1. Parse the event name to identify which goal/trigger fired
  2. Read friend list, secrets, and goal summary from App Group
  3. Post a local `UNNotificationRequest` immediately (instant — no network needed)
  4. Attempt **Strategy 1**: initiate background `URLSession` POST to `send-nudge` Edge Function with `{ friend_id, report }` for each accepted friend
  5. If Strategy 1 is not viable: write `PendingTrigger` to `nudge.triggers.pending` in App Group; schedule `BGProcessingTask`
- [ ] `intervalDidEnd`: write "capture needed" flag to App Group; schedule `BGProcessingTask` for midnight sync
- [ ] `intervalDidStart`: clear any day-scoped state in App Group

### `DeviceActivityReport` Extension
- [ ] Implement `DeviceActivityReportScene` with a custom `ActivityReportContext`
- [ ] Read per-app usage: `bundleIdentifier`, total `duration` (seconds), pickup count
- [ ] Write `[PendingUsageEntry]` JSON to `nudge.usage.pending` in App Group

### Main App — Host Report View
- [ ] Add a zero-size `DeviceActivityReport` view to the root view hierarchy so it renders silently on every app launch and triggers the extension to write fresh data

### Main App — `UsageSyncService`
- [ ] On app foreground, read `nudge.usage.pending` from App Group; upsert to Supabase; clear the key
- [ ] On `BGProcessingTask` wake, perform the same sync
- [ ] Upsert `app` table: `(bundle_id, name)`
- [ ] Upsert `usage` table: `(user_id, date, app_id, seconds, pickups)` — conflict on `(user_id, date, app_id)`
- [ ] Derive `usage.date` from user's IANA timezone (`profile.time_zone`), not UTC
- [ ] On sync failure, leave `nudge.usage.pending` intact — retry on next foreground

### Main App — `NudgeTriggerService` (Strategy 2 path)
- [ ] On `BGProcessingTask` wake, read `nudge.triggers.pending` from App Group
- [ ] For each pending trigger, call `send-nudge` Edge Function
- [ ] Clear processed triggers from App Group

---

## Data Contracts

### App Group Container Keys

| Key | Type | Written by | Read by |
|---|---|---|---|
| `nudge.auth.supabaseUrl` | `String` | Main app (login / token refresh) | Monitor extension |
| `nudge.auth.anonKey` | `String` | Main app (login) | Monitor extension |
| `nudge.auth.jwt` | `String` | Main app (login / token refresh) | Monitor extension |
| `nudge.usage.pending` | JSON `[PendingUsageEntry]` | DeviceActivityReport extension | Main app `UsageSyncService` |
| `nudge.triggers.pending` | JSON `[PendingTrigger]` | Monitor extension (Strategy 2) | Main app `NudgeTriggerService` |
| `nudge.goals.active` | JSON `[GoalSummary]` | Main app (after registration) | Monitor extension |

```swift
struct PendingUsageEntry: Codable {
    let bundleId: String    // e.g. "com.instagram.Instagram"
    let name: String        // display name
    let seconds: Int        // total foreground seconds for the day
    let pickups: Int        // device pickup count
}

struct PendingTrigger: Codable {
    let eventName: String   // e.g. "app.com.instagram.Instagram"
    let timestamp: Date
}

struct GoalSummary: Codable {
    let goalId: Int
    let eventName: String           // matches DeviceActivityEvent.Name raw value
    let limitSeconds: Int
    let targetLabel: String         // e.g. "Instagram", "Social Media", "All Apps"
    let appBundleId: String?        // nil for category / total goals
}
```

### Supabase — `app` table upsert
```swift
struct AppRecord: Codable {
    let bundleId: String
    let name: String
}
// upsert on bundle_id (PK); update name if changed
```

### Supabase — `usage` table upsert
```swift
struct UsageRecord: Codable {
    let userId: UUID
    let date: String        // "YYYY-MM-DD" in user's local timezone (from profile.time_zone)
    let appId: String       // FK → app.bundle_id
    let seconds: Int
    let pickups: Int
}
// upsert on unique constraint (user_id, date, app_id)
```

### `MonitoringRegistrationService` interface
```swift
class MonitoringRegistrationService {
    func registerMonitoring(goals: [GoalSummary], sessionTimeoutMinutes: Int?) throws
    func reregisterIfLapsed() async
    func goalDidChange()
}
```

---

## Testing Strategy

### Unit Tests (write first — can run in simulator)
- `NudgeMessages.swift` — all three message format methods with known inputs
- `PendingUsageEntry` / `PendingTrigger` / `GoalSummary` — Codable encode/decode round-trips
- `UsageRecord` date derivation — given IANA timezone and a known UTC moment, assert correct local date string
- `MonitoringRegistrationService` debounce — rapid `goalDidChange()` calls produce only one registration
- Event name parsing — `"app.com.instagram.Instagram"` → correct goal type and bundle ID extracted

### Device Testing (manual — cannot run in simulator)
The following must be verified manually on a physical device with the Family Controls entitlement:

1. **Permission request** — `AuthorizationCenter.shared.requestAuthorization` shows the system prompt; granting/denying is handled correctly
2. **Monitoring registration** — `DeviceActivityCenter.shared.startMonitoring` succeeds without throwing; events appear in `DeviceActivityCenter.shared.activities`
3. **Threshold detection** — set a short threshold (e.g. 1 minute on any app), use an app for that duration, confirm `eventDidReachThreshold` fires in the monitor extension
4. **Strategy 1 validation** — confirm a background URLSession POST from the monitor extension reaches the Supabase Edge Function. Check Supabase logs for the request. If it arrives: Strategy 1 works. If not: fall back to Strategy 2.
5. **Usage data extraction** — after using apps, open Nudge and confirm `nudge.usage.pending` is populated in App Group and rows appear in Supabase `usage` table
6. **Midnight sync** — set device clock to 11:59pm, let it tick to midnight, confirm `intervalDidEnd` fires and data syncs
7. **Restart recovery** — register monitoring, restart device, open app, confirm monitoring is re-registered automatically

---

## Acceptance Criteria

- [ ] After granting Screen Time permission and using apps, usage rows appear in Supabase with correct local `date`, `seconds`, and `pickups`
- [ ] Running the sync twice on the same day does not create duplicate rows
- [ ] `app` table contains a row for every app that appeared in usage
- [ ] Denying Screen Time permission shows a graceful degraded state — no crash, "permission required" prompt shown
- [ ] When a `DeviceActivityEvent` threshold fires, `eventDidReachThreshold` is called in the monitor extension
- [ ] Monitor extension successfully sends a nudge (Strategy 1) OR writes to App Group for pickup (Strategy 2) — confirmed via Supabase Edge Function logs
- [ ] Monitoring resumes automatically after device restart
- [ ] Goal changes trigger re-registration within 15 seconds of the user finishing edits
