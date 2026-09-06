# Phase 2 — Dashboard

**Status:** `[ ] Not started`

**Goal:** Show the user their usage data — today's summary and per-app breakdown — displayed on-device using `DeviceActivityReport`. No Supabase queries needed for display; all data comes directly from Apple's Screen Time system via the extension.

---

## Prerequisites

- [x] Auth complete (user ID available via `AppState.currentUser`)
- [x] Phase 1 complete — `DeviceActivityCenter` monitoring registered (required so `DeviceActivityReport` has a monitored period to query)
- [x] `NudgeActivityReport` extension target created with Family Controls + App Groups entitlements

---

## Why No Supabase for the Dashboard

`DeviceActivityReport` extensions run in a hardened Apple sandbox that blocks all data persistence and network calls. This is intentional privacy protection — Screen Time data never leaves the device through a third-party app. See ADR-049.

The consequence: per-app usage data (seconds, pickups per bundle ID) **cannot be synced to Supabase**. The dashboard reads this data directly from Apple's system inside the extension's sandboxed process and renders it as a custom SwiftUI view.

What this means in practice: usage data is always up-to-date (live from the OS), private (never leaves the device), and requires no server round-trip.

---

## Architecture

```
DashboardView (main app)
    └── DeviceActivityReport(.nudgeSummary, filter: selectedFilter)
            ↓ OS launches NudgeActivityReport extension process
            ↓ makeConfiguration() receives DeviceActivityResults
            ↓ returns [DailyUsageSummary]
            └── DashboardReportView(summary:)  ← custom SwiftUI view in extension
                    • Total screen time header
                    • Per-app list sorted by seconds
                    • Pickups count
```

The `DashboardView` in the main app owns the filter (today, yesterday, custom date). The extension renders the data view. The main app adds chrome around it (navigation, date picker, tab bar).

---

## Filter Options

The user can view usage for any single day. The filter passed to `DeviceActivityReport` determines what data the extension receives:

- **Today** (default) — `Calendar.current.dateInterval(of: .day, for: Date())`
- **Yesterday** — same, offset by -1 day
- **Custom date** — date picker, limited to the past 30 days

> **Note:** `DeviceActivityReport` only has data for periods covered by a registered `DeviceActivitySchedule`. Monitoring was registered in Phase 1 starting from the user's first app launch. Dates before first launch show empty state.

---

## Tasks

### Extension — `NudgeActivityReport` target

- [ ] Define `DailyUsageSummary` struct (in extension target):
  ```swift
  struct DailyUsageSummary {
      let totalSeconds: Int
      let totalPickups: Int
      let apps: [AppUsageEntry]
  }

  struct AppUsageEntry {
      let bundleId: String
      let displayName: String
      let seconds: Int
      let pickups: Int
  }
  ```

- [ ] Update `TotalActivityReport.swift` — `makeConfiguration` returns `DailyUsageSummary` instead of `[PendingUsageEntry]`
  - Aggregate seconds and pickups per bundle ID
  - Sort apps by seconds descending
  - Derive `displayName` from bundle ID last component (e.g. `"com.instagram.Instagram"` → `"Instagram"`)

- [ ] Implement `DashboardReportView` in `TotalActivityView.swift`:
  - Total time header: `"2h 34m"` (use `Int.formattedDuration`)
  - Pickups count: `"47 pickups"`
  - Per-app list: app name + formatted duration + simple relative bar (width proportional to `seconds / totalSeconds`)
  - Empty state: `"No usage data for this day"` — shown when `totalSeconds == 0`

### Main App — `DashboardView`

- [ ] Replace `DashboardView` stub with real implementation:
  - `@State private var selectedDate: Date = Date()`
  - Hosts `DeviceActivityReport(.nudgeSummary, filter: filterForDate(selectedDate))`
  - Date navigation: `<` / `>` buttons to step through days; disable `>` when `selectedDate` is today
  - Title shows selected date: `"Today"` when current, `"Apr 14"` otherwise
  - Pull-to-refresh: increment/decrement a `@State var refreshId: UUID` and pass as `.id()` to force the report to re-render

- [ ] `filterForDate(_ date: Date) -> DeviceActivityFilter`:
  ```swift
  private func filterForDate(_ date: Date) -> DeviceActivityFilter {
      let interval = Calendar.current.dateInterval(of: .day, for: date)
          ?? DateInterval(start: date, duration: 86400)
      return DeviceActivityFilter(segment: .daily(during: interval))
  }
  ```

- [ ] Add `Int.formattedDuration` extension (shared between main app and extension):
  ```swift
  // e.g. 5400 → "1h 30m", 600 → "10m", 3660 → "1h 1m", 45 → "< 1m", 0 → "0m"
  ```
  Define it in a file included in both the main app target and the extension target, or duplicate it (move to a shared framework in Phase 3+ if needed).

---

## Data Contracts

### `DeviceActivityReport.Context`
Defined in both the main app and extension targets (must use identical raw string):
```swift
extension DeviceActivityReport.Context {
    static let nudgeSummary = Self("NudgeSummary")
}
```

### `DailyUsageSummary` (extension target only)
```swift
struct DailyUsageSummary {
    struct AppUsageEntry {
        let bundleId: String
        let displayName: String
        let seconds: Int
        let pickups: Int
    }
    let totalSeconds: Int
    let totalPickups: Int
    let apps: [AppUsageEntry]   // sorted by seconds descending
}
```

### `NudgeUsageReport` scene
```swift
struct NudgeUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .nudgeSummary
    let content: (DailyUsageSummary) -> DashboardReportView

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> DailyUsageSummary
}
```

---

## UI Spec

### DashboardReportView (rendered by extension)

```
┌─────────────────────────────────────────────┐
│  Total Screen Time                           │
│  2h 34m  ·  47 pickups                      │
│─────────────────────────────────────────────│
│  Instagram          1h 12m  ████████░░░░    │
│  Safari               34m   ████░░░░░░░░    │
│  YouTube              28m   ███░░░░░░░░░    │
│  Messages             20m   ██░░░░░░░░░░    │
│  ...                                        │
└─────────────────────────────────────────────┘
```

- No minimum threshold — show all apps with any usage
- Bar width is proportional to `seconds / totalSeconds`, minimum 2pt visible
- Display name derived from bundle ID last component (Phase 3 can improve with `LocalizedApplicationName` if available)

### DashboardView (main app chrome)

```
┌─────────────────────────────────────────────┐
│  < Today >                                  │
│─────────────────────────────────────────────│
│  [DeviceActivityReport view]                │
│                                             │
└─────────────────────────────────────────────┘
```

---

## Empty States

| Condition | What to show |
|---|---|
| No Screen Time permission | "Screen Time access required" with Settings deep link |
| No monitoring registered (Phase 1 not set up) | "Usage tracking not active" |
| Day with no usage data | "No usage recorded for this day" |
| Extension loading | SwiftUI renders the extension async — show a `ProgressView` until the extension provides its view |

---

## Acceptance Criteria

- [ ] Dashboard shows today's total screen time and per-app breakdown
- [ ] Apps sorted by time spent, most used first
- [ ] Total time and per-app times formatted as `"Xh Ym"` (e.g. `"1h 23m"`, `"< 1m"`)
- [ ] Day navigation works — `<` / `>` steps through days; `>` disabled on today
- [ ] Empty state shown when no usage data exists for the selected day
- [ ] No Screen Time permission shows a graceful degraded state — no crash
- [ ] Pull-to-refresh forces the report to re-render with fresh data
