# Phase 4 — Notifications & Interventions

**Status:** `[ ] Not started`

**Goal:** Alert the user when they hit a usage goal threshold. Send periodic motivational reminders. (App blocking is out of scope for now — it requires a separate ManagedSettings entitlement.)

---

## Prerequisites

- [x] Auth complete
- [ ] Phase 1 complete — DeviceActivity monitoring running (thresholds require `DeviceActivityMonitor`)
- [ ] Phase 3 complete — goals exist to trigger against
- [ ] `why_reminder` table deployed (part of base schema — already done)
- [ ] `DeviceActivityMonitor` extension target created (stub created in Phase 1)
- [ ] Notification permission granted by user

---

## Tasks

### Why Reminders — CRUD
- [ ] Add `WhyReminder` model:
  ```swift
  struct WhyReminder: Codable, Identifiable {
      let id: Int
      let userId: UUID   // user_id
      let message: String
  }
  ```

- [ ] Create `ReminderService`:
  ```swift
  class ReminderService {
      func fetchReminders(userId: UUID) async throws -> [WhyReminder]
      func addReminder(userId: UUID, message: String) async throws
      func deleteReminder(id: Int) async throws
  }
  ```

- [ ] Why Reminders UI in Settings:
  - List of existing reminders
  - Add reminder (text field + save)
  - Delete reminder (swipe-to-delete)

### Local Notification Service
- [ ] Create `NotificationService`:
  ```swift
  class NotificationService {
      func requestPermission() async throws -> Bool
      func scheduleWhyReminder(message: String, at: DateComponents) async throws
      func cancelWhyReminders() async
      func scheduleGoalReminder(goalId: Int, message: String, at: DateComponents) async throws
  }
  ```

- [ ] Schedule why reminders:
  - On app launch, schedule (or re-schedule) why reminder notifications
  - Select reminder: **round-robin** — track last-shown index in UserDefaults, advance by 1 each time
  - Frequency: **once daily at 9am local time** (configurable in future)
  - Cancel and reschedule when reminders are added/deleted

### Goal Reminder Notifications
- [ ] Schedule a periodic local notification per active goal reminding the user of their intention
  - Example: "You've set a 1hr daily limit on Instagram. Stay intentional."
  - Fires once daily (morning) for each active goal
  - Cancel and reschedule when goals are added or deleted

> **Open question:** When exactly should these fire — fixed morning time, or when the app is opened for the day? Should the user be able to disable them per goal? Decide before building.

### `DeviceActivityMonitor` Extension — Threshold Alerts
- [ ] Implement `DeviceActivityMonitorExtension` (target created in Phase 1)
- [ ] Override `intervalDidStart`, `intervalDidEnd`, `eventDidReachThreshold`
- [ ] In `eventDidReachThreshold`:
  - Read the goal's `limitSeconds` and a why reminder from App Group UserDefaults
  - Fire a local `UNNotificationRequest` immediately
  - Notification body: "You've hit your [App Name] limit. [Why Reminder]"
- [ ] Main app writes active goals + why reminders to App Group UserDefaults so the extension can read them without a Supabase call
- [ ] Configure `DeviceActivityEvent` per goal when a goal is created/deleted — update monitoring schedule

### Notification Permission
- [ ] Wire up `PermissionsView` notification request to `NotificationService.requestPermission()`
- [ ] In Settings: show current permission status, deep-link to iOS Settings if denied

---

## Data Contracts

### App Group UserDefaults keys
| Key | Type | Written by | Read by |
|---|---|---|---|
| `nudge.goals.active` | JSON `[GoalSummary]` | Main app | `DeviceActivityMonitor` extension |
| `nudge.reminders.roundrobin` | JSON `[String]` (messages) + `Int` (next index) | Main app | `DeviceActivityMonitor` extension |

```swift
struct GoalSummary: Codable {
    let goalId: Int
    let appBundleId: String?   // nil for category/total goals
    let limitSeconds: Int
    let targetLabel: String    // e.g. "Instagram", "Social Media", "All Apps"
}
```

### `DeviceActivityEvent` setup per goal
```swift
// Called when a goal is created or loaded at app startup
let event = DeviceActivityEvent(
    applications: [ApplicationToken],  // from goal's bundleId
    threshold: DateComponents(second: goal.limitSeconds)
)
let eventName = DeviceActivityEvent.Name("goal-\(goal.id)")
// Register with DeviceActivityCenter
```

---

## Open Questions

> **Must be resolved before implementation begins.**

1. **Can local notifications be scheduled from within a `DeviceActivityMonitor` extension?**
   Extensions run in a restricted sandbox. Confirm whether `UNUserNotificationCenter` is accessible from the monitor extension. If not, the extension may need to write a flag to the App Group container and let the main app fire the notification.

2. **Unlock prompt feasibility:**
   iOS does not expose an unlock event to third-party apps. Options:
   - A scheduled morning notification ("Starting a new day — are you being intentional?")
   - Not implemented — remove from scope if no viable mechanism exists
   Decision required before starting this task.

3. **Why reminder frequency:** Once daily at 9am is the proposed default. Should this be user-configurable in Settings? Decide before building the scheduling logic.

---

## Acceptance Criteria

- [ ] User can add, view, and delete why reminders in Settings
- [ ] Why reminder notifications fire daily (round-robin through the list)
- [ ] When a goal's usage threshold is hit, a local notification fires with the app name and a why reminder
- [ ] Notifications respect user's notification permission status
- [ ] Revoking notification permission in iOS Settings gracefully degrades — no crash, no silent failures
