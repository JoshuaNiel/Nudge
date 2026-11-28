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
| No Screen Time permission | "Screen Time access required" full-screen state with an **Allow** button (system prompt) — see 2026-11-27 decisions |
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
- **Refresh is a toolbar button, not pull-to-refresh.** The report is a remote view rendered by another process: touches inside it never reach a host `ScrollView`, so `.refreshable` would only respond to drags on the thin day-navigator strip. The report also scrolls itself, and nesting it in a host scroll view would require a fixed height the host cannot know. The report is additionally refreshed every time the app returns to the foreground (narrowed 2026-11-27, D3 below). The report's `.id` is keyed on (day, refreshId).
- **Authorization:** ~~`.approved` and (iOS 26.4+) `.approvedWithDataAccess` both count as authorized; anything else shows "Screen Time access required" with an Open Settings button.~~ Superseded 2026-11-27 (D1, D2 below).
- **Monitoring not registered:** "Usage tracking not active" with a Check Again button. Because the app registers monitoring asynchronously on foreground (after a network fetch), the dashboard also re-checks every 2s, up to 5 times, while in this state.
- **Loading:** a `ProgressView` sits behind the report; the extension's view has an opaque background that covers it once drawn.
- **Devices filter:** left at the default (`DeviceActivityFilter` with no explicit devices). With `.individual` authorization only this device's data is reported.
- **Extension isolation:** the `NudgeActivityReport` struct is `@MainActor` — scenes are main-actor isolated (ExtensionKit's `AppExtensionScene`) while the SDK leaves `DeviceActivityReportExtension.body` unannotated, which otherwise warns (an error in Swift 6 mode).
- **Cleanup:** no hidden `DeviceActivityReport`, `PendingUsageEntry` or `UsageSyncService` remained in code; nothing to remove. ADR-044 and ADR-047 describe the abandoned App Group sync and are now historical.

---

## Implementation Decisions (2026-11-27, user review of PR #15 after merging #26)

These supersede the 2026-11-14 notes above where they differ. The 2026-11-14 notes were agent
judgment calls; the user may revisit any of them.

### D1. No Screen Time access: one full-screen state, no banner
- When Screen Time is not granted, the Dashboard shows only the full-screen
  `ContentUnavailableView`: "Screen Time access required", text "Nudge needs Screen Time access
  to show your usage.", and an **Allow** button.
- **Allow** runs the shared Screen Time request (`PermissionActionRunner`, onboarding-progress
  §5b): always the system prompt (`requestAuthorization(for: .individual)`), whatever the
  current status. Never opens Settings. The "Open Settings" button and `openSettings()` are removed.
- The **Screen Time banner no longer appears on the Dashboard** (onboarding-progress §5 table is
  updated: Screen Time banner → Goals only). The **notifications banner still shows on the
  Dashboard**, above whatever state the Dashboard is in, including this one.
- In this state the day navigator and the toolbar Refresh button are hidden (as today).

### D2. Screen Time status comes from the shared `PermissionStatusStore`
- `DashboardAvailability` resolves from the store's `screenTime: PermissionStatus` (which
  includes the live `AuthorizationCenter` observation and the monitoring-proved revoke
  override) instead of reading `AuthorizationCenter.shared.authorizationStatus` itself. The
  Dashboard and the banners therefore never disagree.
- New resolver: `resolve(screenTime: PermissionStatus, isLoaded: Bool, isMonitoringActive: Bool)`:
  - `!isLoaded` → `.loading` (a plain `ProgressView`; avoids flashing the access screen on a
    cold start before the first status read);
  - `screenTime != .granted` → `.needsAuthorization`;
  - otherwise `.ready` or `.trackingInactive` from `DeviceActivityCenter().activities` as today.
- Remove `DashboardAvailability.isAuthorized(_:)`; `PermissionStatus(screenTime:)` already maps
  `.approvedWithDataAccess` and later approval kinds to `.granted`.
- Availability is re-evaluated whenever the store's `screenTime`/`isLoaded` change (not only on
  foreground), so granting via **Allow** or a revoke detected mid-session updates the screen
  immediately. The existing `trackingInactive` re-check (every 2s, up to 5 times) still covers
  the gap while #26's re-register-after-approval registers monitoring.

### D3. Automatic refresh only on a real return to the app
- The automatic refresh (re-check availability, re-clamp the day across midnight, rebuild the
  report) runs only when the scene becomes `.active` **after having been `.background`** — the
  same rule as `ForegroundSync`. Bounces through `.inactive` (the Screen Time and notification
  prompts, Face ID, Control Center, notification center) do not refresh.
- The decision of "is this a real foreground?" is a small pure, tested type (or reuse of an
  existing one) — not ad-hoc state in the view.
- Additionally, the report is refreshed once when availability transitions **into** `.ready`
  (e.g. right after Screen Time is granted and monitoring registers).
- The toolbar Refresh button is unchanged.

### D4. Main-tab header style — see onboarding-progress §5d
~~The Dashboard keeps the compact (inline-height) bar; the title moves to the leading edge in a
larger font, and all main tabs adopt the same style.~~ Superseded by §5d (revised): native large
title at ~28pt on every main tab.

### Done when (2026-11-27)
- **Unit tests:** `DashboardAvailability.resolve` for every combination of (isLoaded,
  screenTime ∈ notDetermined/denied/granted, isMonitoringActive); the real-foreground rule
  (background→active refreshes; inactive→active does not; first active after launch counts);
  refresh-on-transition-into-ready; banner visibility tables updated (Screen Time banner on
  Goals only; notifications banner on Dashboard, Goals, Friends).
- **On device:** with Screen Time revoked, the Dashboard shows only the full-screen state (no
  Screen Time banner), Allow shows the system prompt, and approving brings the report back
  without leaving the app; pulling down Control Center and dismissing it does not reload the
  report; returning from another app does.

---

## Dashboard v2 (user decisions 2026-11-27, after first device test of PR #15)

Device: iPhone 13, iOS 17.6.1. Supersedes earlier sections where they differ.

### V1. Bug: report stuck on the spinner after a day change or Refresh
**Seen:** stepping days or tapping Refresh often left the spinner showing; switching tabs and back
showed the report. Console: repeated `VS terminated … Terminated=disconnect method`.
**Cause (researched, Apple Developer Forums 723118, 723491, 730064, 750698; Apple docs example):**
every day change and refresh changed the report's `.id`, which disconnects the remote view and
connects a new one in the same frame. The new connection sometimes never draws, and the app can't
detect it. Apple recommends one report on screen, changing only its filter.
**Fix:**
- Keep **one** `DeviceActivityReport` alive. Day, week and mode changes change **only its filter**
  (built by a pure, tested function of (mode, selected date)); they never change `.id`.
- `.id` is keyed only on `refreshId`. A forced rebuild (toolbar Refresh, real foreground,
  transition into `.ready`) is **debounced and coalesced**: it happens ~400 ms after the last
  trigger, and back-to-back triggers produce one rebuild. The policy is a pure, tested type.
- **Fallback:** behind the report, under the spinner, a "Taking a while? **Reload**" button fades
  in after ~6 s. Once the extension draws its opaque view it covers both, so the button is only
  ever visible when the report failed to draw. Reload = one forced rebuild.
- Done when (device): 20 fast taps on `<`/`>` and 10 Refresh taps never leave a stuck spinner
  (or, if one happens, Reload recovers it).

### V2. Day | Week mode
- A segmented control **Day | Week** at the top of the page content (below the header and any
  banner, above the date navigator). Default Day. Kept while the app runs; not persisted.
- **Week = Sunday–Saturday** (hard-coded for now; a user-set week-start day is backlogged). The
  week filter is `.daily(during:)` from Sunday 00:00 to next Sunday 00:00 (always the full week,
  even the current one), so the extension gets one segment per day. Not clipped at today: a
  clipped current week on a Sunday would equal the day range and the extension (which only sees
  the filter range) couldn't tell Week from Day. The extension computes "days counted" from the
  range and its own `Date()`.
- Switching Day → Week shows the week containing the selected day; Week → Day selects today if
  that week is the current week, otherwise the week's Saturday.

### V3. Date navigator and date picker
- `<  [title]  >`. Day titles as before ("Today", "Yesterday", "Nov 25"). Week titles are
  **always a date range**: "Nov 15 – 21", "Oct 26 – Nov 1" across months, "Dec 27 – Jan 2"
  across years (no "This Week"/"Last Week").
- `<`/`>` step one day or one week. Range: **the last 30 days** (today − 30 … today), as before.
  In Week mode a week is reachable if any of its days is in range; `>` is disabled on the current
  week.
- **Tapping the title** opens a sheet (medium detent) with a graphical `DatePicker` limited to
  today − 30 … today and a Done button. In Week mode the chosen day selects its week. The title
  shows it's tappable (a small chevron.down).

### V4. Totals | Averages (Week mode only)
- Inside the report (the extension), a segmented control **Totals | Averages** at the top of the
  summary card. Default Totals.
- **Averages** divide the week's total time, pickups and every row by the **number of days counted**:
  days in the week up to and including today (current week), otherwise 7. Labels: "Daily
  Average" instead of "Total Screen Time"; rows show "/day".
- The pure math (days counted, average rounding) lives in `Shared/` with unit tests.

### V5. Apps | Categories breakdown
- Inside the report, the breakdown section header becomes a segmented control **Apps |
  Categories**. Default Apps.
- **Categories** = Apple's built-in Screen Time categories from the report data (`segment.categories`):
  `Label(categoryToken)` for name and icon, time, proportional bar, sorted like apps. Aggregated in
  `Shared/UsageSummary.swift` (generic, tested) alongside apps.
- Nudge's own categories (#22) are added later; the breakdown type is an enum so a third source
  can be added without restructuring.
- **Device check:** whether the in-report controls (V4, V5) keep their selection when the host
  changes the filter. If they reset on every day step, report it; the fallback is to accept the
  reset or move the controls to the host.

### V7. Custom loading indicator
- Replace Apple's default `ProgressView` spinner with a Nudge-branded loading indicator. A
  designer subagent builds **several options** as reusable SwiftUI views, viewable side by side
  in a DEBUG-only gallery (Settings → "Loading styles", debug builds only). The user picks one;
  then the chosen view replaces `ProgressView` in the Dashboard (`.loading` state and behind the
  report) and in the app's other loading states, and the other options are deleted.
- Requirements for every option: iOS 17, light and dark mode, Reduce Motion (a calm, non-moving
  fallback), VoiceOver label "Loading", cheap to animate (no per-frame work when off screen),
  sizes small (inline) and large (full screen).
- **Chosen (2026-11-27):** Tipping Point (`NudgeLoadingIndicator`, `Features/Shared/LoadingIndicator*.swift`)
  replaces every indeterminate `ProgressView` in the app (large for screens/lists, small inline,
  white `.onFilled` tone on filled buttons; button labels use `.replacedByLoadingIndicator` /
  `.prefixedByLoadingIndicator` so they keep their height). Rolling Hills stays in the code,
  unused, for later. Ring Nudge, Cradle, Breathe and the debug gallery were removed.

### V6. Header
See onboarding-progress §5d (revised): native large title, ~28pt, all main tabs.

### Done when (v2)
- **Unit tests:** filter interval for (mode, date) incl. Sun–Sat weeks, today-clipping, DST,
  month-spanning; week titles; week stepping and range bounds; Day↔Week selection mapping;
  date-picker range; refresh debounce/coalesce policy; days-counted and averages; category
  aggregation and sort.
- **Device:** V1 stress check; Day/Week switch; week totals vs. Settings → Screen Time's week
  view (iPhone); Averages = totals ÷ days; Categories match Settings' categories; date picker
  limits; controls' state across day steps (V5 note).

---

## Dashboard v3 — DRAFT (user decisions 2026-11-27, second device test). Not ready to implement.

Second device test: everything in v2 looked good, and the in-report controls **keep their
selection** across day/week steps (the V5 risk is resolved).

### Decided
- **W1. Labels:** the week-mode control reads **Total | Daily Average**. It moves out of the
  summary card and stands alone above it, the same way Apps | Categories sits above its list.
- **W2. App detail:** tapping an app row (Day or Week) opens a detail screen:
  - the app's name and icon at the top;
  - a bar chart of daily usage for the **last 30 days** (to be confirmed: Apple may keep only 28;
    the spike checks);
  - three averages:
    - **this week**: Sunday through today;
    - **rolling 7 days**: the last 7 days including today;
    - **30-day**: divided by the number of days that **actually have collected data**, not a
      hard-coded 30. A collected day with 0 minutes still counts; a day with no data at all
      (e.g. before install, or past Apple's retention) doesn't.
- **W3. Category detail:** tapping a category opens the same layout (chart + three averages)
  plus the list of apps in that category. Tapping one of those opens its app detail.
- **W4. Filter:** a filter button in the toolbar, next to Refresh, opens Apple's
  `FamilyActivityPicker` (apps and/or categories). The whole Dashboard shows only the
  selection; the filter changes only the report's filter (no rebuild).
  - The button is filled when a filter is active.
  - While a filter is active, a chip under Day | Week reads "Filtered: 3 apps, 1 category" with
    a **Clear** button.
  - Remembered **on this device** (App Group / UserDefaults, encoded selection), never synced.

### Open: architecture (blocked on a device spike)
The detail screens are drawn by the report extension: only it knows which app was tapped, and
it can't send that back to the host. They need 30+ days of data while the main view shows the
selected day/week, but a report receives only one filter (date range + apps/categories). Options:
- **A.** The host writes the selected period to the App Group. The extension **reads** it, and
  the filter always spans the last 30+ days plus the selected period. Requires App Group reads
  to work in the report extension (writes are blocked by the sandbox).
- **B.** Day | Week, the navigator and the date picker move **into** the extension. The host
  always sends the last 30+ days. Requires navigation pushes (and ideally sheets) to work inside
  the report's remote view.
- Either way: the 30+ day query must fit the extension's ~100 MB memory limit, and a forced
  rebuild (Refresh/foreground) resets in-extension state (an open detail screen closes).

### Spike (debug-only, separate branch) — to answer on device
1. Can the report extension read a value the host just wrote to the App Group (UserDefaults
   suite and a container file)?
2. A `.daily` filter over 30 / 35 / 60 days: how many segments come back, the earliest day with
   data, how a day with no data appears (missing vs. 0), time taken and peak memory.
3. Do `NavigationStack` pushes and `.sheet` presentations work inside the report view?
