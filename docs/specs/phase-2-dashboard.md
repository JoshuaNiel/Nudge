# Phase 2 — Dashboard

**Status:** `[~] Implemented — awaiting on-device verification` (acceptance criteria are verified on a physical device; the simulator has no Screen Time data)

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

- [x] Define `DailyUsageSummary` struct — implemented in `Shared/UsageSummary.swift` (not extension-only; see Implementation Decisions):
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

- [x] Update `TotalActivityReport.swift` — `makeConfiguration` returns `DailyUsageSummary` instead of `[PendingUsageEntry]`
  - Aggregate seconds and pickups per bundle ID
  - Sort apps by seconds descending
  - Derive `displayName` from bundle ID last component (e.g. `"com.instagram.Instagram"` → `"Instagram"`)

- [x] Implement `DashboardReportView` in `TotalActivityView.swift`:
  - Total time header: `"2h 34m"` (use `Int.formattedDuration`)
  - Pickups count: `"47 pickups"`
  - Per-app list: app name + formatted duration + simple relative bar (width proportional to `seconds / totalSeconds`)
  - Empty state: `"No usage data for this day"` — shown when `totalSeconds == 0`

### Main App — `DashboardView`

- [x] Replace `DashboardView` stub with real implementation:
  - `@State private var selectedDate: Date = Date()`
  - Hosts `DeviceActivityReport(.nudgeSummary, filter: filterForDate(selectedDate))`
  - Date navigation: `<` / `>` buttons to step through days; disable `>` when `selectedDate` is today
  - Title shows selected date: `"Today"` when current, `"Apr 14"` otherwise
  - ~~Pull-to-refresh~~ → toolbar refresh button + auto-refresh on foreground (see Implementation Decisions): increment/decrement a `@State var refreshId: UUID` and pass as `.id()` to force the report to re-render

- [x] `filterForDate(_ date: Date) -> DeviceActivityFilter` — date math lives in `DashboardDay.filterInterval(for:calendar:)` (Shared, tested):
  ```swift
  private func filterForDate(_ date: Date) -> DeviceActivityFilter {
      let interval = Calendar.current.dateInterval(of: .day, for: date)
          ?? DateInterval(start: date, duration: 86400)
      return DeviceActivityFilter(segment: .daily(during: interval))
  }
  ```

- [x] Add `Int.formattedDuration` extension — now `Shared/DurationFormatting.swift`, compiled into all three targets (shared between main app and extension):
  ```swift
  // e.g. 5400 → "1h 30m", 600 → "10m", 3660 → "1h 1m", 45 → "< 1m", 0 → "0m"
  ```
  Define it in a file included in both the main app target and the extension target, or duplicate it (move to a shared framework in Phase 3+ if needed).

---

## Data Contracts

### `DeviceActivityReport.Context`
Defined once in `Shared/ReportContext.swift`, compiled into the app and the report extension (excluded from the monitor extension):
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
- [ ] Refresh (toolbar button, and returning to the app) forces the report to re-render with fresh data

---

## Implementation Decisions (2026-11-14)

- **Pure logic in `Shared/`.** `DailyUsageSummary`, `AppUsageEntry`, aggregation, display-name fallback, bar geometry, pickups copy and day-navigation math live in `Shared/UsageSummary.swift` and take plain values, because `DeviceActivityData` has no public initializer and cannot be built in tests. The extension's `makeConfiguration` only walks `DeviceActivityResults` (`activitySegments` → `categories` → `applications`) and maps to `UsageSegmentSample`/`AppUsageSample`. Tests: `NudgeTests/DashboardTests.swift`.
- **`Shared/` is now compiled into the report extension** (third entry in its `fileSystemSynchronizedGroups`). `ReportContext.swift` is excluded from `NudgeActivityMonitor` via a membership exception so the memory-constrained monitor does not link SwiftUI for one constant.
- **Generic token payload.** The types are generic over `Token: Hashable`; the extension uses `DailyUsageSummary<ApplicationToken>` so each row renders the real name and icon with `Label(token)`, falling back to the derived display name when the token is nil. Tests use `String`.
- **Merge key:** bundle id → token → localized name. Samples with none of these are dropped from the list, but their time still counts in the total.
- **Display name:** `localizedDisplayName` (now exposed by the SDK) → last bundle-id component, first letter capitalized (`com.google.ios.youtube` → `Youtube`) → whole bundle id → `"Unknown App"`. Only used when the token is nil.
- **Totals:** `totalSeconds` = sum of segment `totalActivityDuration` (includes time not attributed to a listed app), floored at the sum of listed apps; durations rounded once at the end. `totalPickups` = sum of `totalPickupsWithoutApplicationActivity` + per-app `numberOfPickups`. Apps with zero time and zero pickups are omitted.
- **Sort:** seconds descending, then display name (case-insensitive), then bundle id.
- **Bar:** `seconds / totalSeconds`, clamped to `0...1`; any non-zero fraction renders at least 2pt; never wider than the track.
- **Empty state:** shown when `totalSeconds == 0` — copy "No usage recorded for this day".
- **Day range:** today back to 30 days before today (31 selectable days); `<` disabled at the earliest day, `>` disabled on today. Selection is stored as a start of day and re-clamped on foreground so it stays valid across midnight. Title: "Today", "Yesterday", or a localized month-day (`"Apr 14"` in en_US).
- **Refresh is a toolbar button, not pull-to-refresh.** The report is a remote view rendered by another process: touches inside it never reach a host `ScrollView`, so `.refreshable` would only respond to drags on the thin day-navigator strip. The report also scrolls itself, and nesting it in a host scroll view would require a fixed height the host cannot know. The report is additionally refreshed every time the app returns to the foreground. The report's `.id` is keyed on (day, refreshId).
- **Authorization:** `.approved` and (iOS 26.4+) `.approvedWithDataAccess` both count as authorized; anything else shows "Screen Time access required" with an Open Settings button.
- **Monitoring not registered:** "Usage tracking not active" with a Check Again button. Because the app registers monitoring asynchronously on foreground (after a network fetch), the dashboard also re-checks every 2s, up to 5 times, while in this state.
- **Loading:** a `ProgressView` sits behind the report; the extension's view has an opaque background that covers it once drawn.
- **Devices filter:** left at the default (`DeviceActivityFilter` with no explicit devices). With `.individual` authorization only this device's data is reported.
- **Extension isolation:** the `NudgeActivityReport` struct is `@MainActor` — scenes are main-actor isolated (ExtensionKit's `AppExtensionScene`) while the SDK leaves `DeviceActivityReportExtension.body` unannotated, which otherwise warns (an error in Swift 6 mode).
- **Cleanup:** no hidden `DeviceActivityReport`, `PendingUsageEntry` or `UsageSyncService` remained in code; nothing to remove. ADR-044 and ADR-047 describe the abandoned App Group sync and are now historical.
