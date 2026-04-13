# Phase 1 — DeviceActivity Pipeline

**Status:** `[ ] Ready to start`

**Goal:** Get usage data flowing from Apple's Screen Time APIs into Supabase so that Phases 2–4 have real data to work with.

---

## Prerequisites

- [!] Family Controls entitlement approved by Apple (apply at developer.apple.com)
- [x] DB schema deployed (`usage` table, `app` table, RLS policies)
- [ ] App Group identifier defined and configured on both targets

---

## Tasks

### Entitlement & Project Setup
- [ ] Enroll in Apple Developer Program ($99/year) if not already
- [ ] Request Family Controls entitlement at developer.apple.com → Additional Capabilities. Required for development builds, not just App Store submission. Approval can take days.
- [ ] Once approved, add Family Controls capability in Xcode: Signing & Capabilities → + Capability → "Family Controls"
- [ ] Add Family Controls capability to main app target in Xcode
- [ ] Define App Group ID: `group.com.[yourname].nudge` — set it once, use everywhere
- [ ] Add App Groups capability to main app target
- [ ] Create DeviceActivityReport extension target
- [ ] Add Family Controls + App Groups capabilities to extension target
- [ ] Create DeviceActivityMonitor extension target (can be stubbed — needed in Phase 4)
- [ ] Add Family Controls + App Groups capabilities to monitor extension target

### Permission Request
- [ ] Implement `PermissionsView` Screen Time request using `AuthorizationCenter.shared.requestAuthorization(for: .individual)`
- [ ] Handle authorization errors and show appropriate messaging
- [ ] Wire up actual permission status to gate usage features in the app

### Monitoring Setup (main app)
- [ ] Create `UsageMonitorService` in main target
- [ ] Start a `DeviceActivitySchedule` covering midnight–midnight in the user's timezone
- [ ] Re-start the schedule daily (or on app foreground if monitoring has lapsed)
- [ ] Store monitoring state in App Group UserDefaults so extensions can read it

### DeviceActivityReport Extension
- [ ] Implement `DeviceActivityReportScene` with a custom `ActivityReportContext`
- [ ] Extract per-app data: `bundleIdentifier`, total `duration` (seconds), pickup count
- [ ] Write extracted data to the App Group shared container as JSON
- [ ] Format: array of `{ "bundle_id": String, "name": String, "seconds": Int, "pickups": Int }`

### Main App — Sync to Supabase
- [ ] Main app reads from App Group shared container on foreground / background refresh
- [ ] For each app in the payload:
  - Upsert into `app` table: `(bundle_id, name)`
  - Upsert into `usage` table: `(user_id, date, app_id, seconds, pickups)` on conflict `(user_id, date, app_id)`
- [ ] Derive `usage.date` from user's `time_zone` (from `profile` table), not UTC
- [ ] Handle sync failure gracefully — retry on next foreground

---

## Data Contracts

### App Group Container
- **Key:** `"nudge.usage.pending"` in shared UserDefaults
- **Value:** JSON-encoded array of `PendingUsageEntry`

```swift
struct PendingUsageEntry: Codable {
    let bundleId: String    // e.g. "com.instagram.Instagram"
    let name: String        // display name
    let seconds: Int        // total foreground seconds
    let pickups: Int        // device pickups
}
```

### Supabase — `app` table upsert
```swift
struct AppRecord: Codable {
    let bundleId: String   // maps to bundle_id
    let name: String
}
// upsert on bundle_id (PK), ignoreDuplicates: false (update name if changed)
```

### Supabase — `usage` table upsert
```swift
struct UsageRecord: Codable {
    let userId: UUID        // maps to user_id
    let date: String        // "YYYY-MM-DD" local date in user's timezone
    let appId: String       // maps to app_id (FK → app.bundle_id)
    let seconds: Int
    let pickups: Int
}
// upsert on unique constraint (user_id, date, app_id)
```

### `UsageMonitorService` interface
```swift
class UsageMonitorService {
    func requestAuthorization() async throws
    func startMonitoring(timeZone: TimeZone) throws
    func syncPendingUsage(userId: UUID, timeZone: TimeZone) async throws
}
```

---

## Open Questions

> **Must be resolved before implementation begins.**

1. **Can the DeviceActivityReport extension write to an App Group container?**
   The extension runs in a restricted sandbox. Confirm whether `UserDefaults(suiteName:)` or `FileManager` with the App Group URL works from within the extension. If not, another IPC mechanism is needed.

2. **Sync trigger strategy:**
   - Option A: `BGAppRefreshTask` — fires periodically in the background, reliable but infrequent
   - Option B: On app foreground (`scenePhase == .active`) — immediate but requires app to be opened
   - Option C: Both — foreground for freshness, background for overnight sync
   **Recommended:** Option C. Decide and document.

3. **Data granularity:** Does Apple provide per-app data per-day, or finer? The `usage` schema assumes daily granularity. Confirm with DeviceActivity docs.

4. **Monitoring lapse:** What happens if the device restarts or the app is force-quit? Does `DeviceActivityMonitor` continue, or does monitoring need to be restarted? Document restart behavior.

---

## Acceptance Criteria

- [ ] After granting Screen Time permission and using apps for a day, usage rows appear in Supabase `usage` table with correct `date` (local, not UTC), `seconds`, and `pickups`
- [ ] Running the sync twice on the same day does not create duplicate rows
- [ ] `app` table contains a row for every app that appeared in usage
- [ ] Denying Screen Time permission shows a graceful degraded state — app still opens, usage features show a "permission required" prompt
