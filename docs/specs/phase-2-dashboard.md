# Phase 2 — Dashboard

**Status:** `[ ] Not started`

**Goal:** Show the user their historical usage data — today's summary, top apps, and a weekly trend chart — pulled from Supabase.

---

## Prerequisites

- [x] Auth complete (user ID available via `AppState.currentUser`)
- [ ] Phase 1 complete — usage data exists in Supabase (can build UI against mock data first)
- [ ] `AppUsage.swift` model updated to match DB schema (task below)

---

## Tasks

### Models
- [ ] Update `AppUsage.swift` to match `usage` table schema:
  ```swift
  struct AppUsage: Codable, Identifiable {
      let id: Int
      let userId: UUID       // user_id
      let date: String       // "YYYY-MM-DD"
      let appId: String      // app_id (bundle_id)
      let seconds: Int
      let pickups: Int
  }
  ```
- [ ] Add `App` model matching `app` table:
  ```swift
  struct App: Codable, Identifiable {
      let bundleId: String   // PK
      let name: String
      var id: String { bundleId }
  }
  ```

### Service Layer
- [ ] Create `UsageService`
  ```swift
  class UsageService {
      // Fetch all usage rows for a given date range, joined with app names
      func fetchUsage(userId: UUID, from: Date, to: Date) async throws -> [AppUsageWithName]
      
      // Fetch today's total screen time (sum of seconds across all apps)
      func fetchTodayTotal(userId: UUID, timeZone: TimeZone) async throws -> Int
      
      // Fetch top N apps by seconds for a given date
      func fetchTopApps(userId: UUID, date: String, limit: Int) async throws -> [AppUsageWithName]
  }
  
  struct AppUsageWithName: Codable, Identifiable {
      let id: Int
      let appId: String
      let appName: String
      let date: String
      let seconds: Int
      let pickups: Int
  }
  ```

### Dashboard ViewModel
- [ ] Create `DashboardViewModel`
  - `@Published var todayTotalSeconds: Int`
  - `@Published var topApps: [AppUsageWithName]`
  - `@Published var weeklyUsage: [DailyTotal]` — for chart (7 days)
  - `@Published var isLoading: Bool`
  - `@Published var error: String?`
  - `func load() async` — fetches all three data sets

### Dashboard View
- [ ] Replace `DashboardView` stub with real implementation
- [ ] Today's total screen time (formatted: "2h 34m")
- [ ] Top apps list — app name, formatted time, simple bar or progress indicator
- [ ] Weekly bar chart (Swift Charts) — one bar per day, height = total seconds
- [ ] Pull-to-refresh
- [ ] Loading skeleton / empty state when no data

---

## Data Contracts

### Supabase query — today's usage
```swift
// Fetch usage rows where user_id = currentUser.id AND date = today's local date
supabase
    .from("usage")
    .select("*, app(name)")   // join app table for name
    .eq("user_id", value: userId)
    .eq("date", value: todayString)  // "YYYY-MM-DD" in user's timezone
    .execute()
```

### Supabase query — weekly usage
```swift
// Fetch last 7 days
supabase
    .from("usage")
    .select("date, seconds")
    .eq("user_id", value: userId)
    .gte("date", value: sevenDaysAgoString)
    .lte("date", value: todayString)
    .order("date", ascending: true)
    .execute()
// Aggregate by date client-side: sum seconds per date
```

### Time formatting helper
```swift
// Used throughout the app — define in a shared extension
extension Int {
    var formattedDuration: String {
        // e.g. 5400 → "1h 30m", 600 → "10m", 3660 → "1h 1m"
    }
}
```

---

## Open Questions

> None blocking — UI can be built with mock data while Phase 1 is in progress.

---

## Acceptance Criteria

- [ ] Dashboard shows today's total screen time and top 5 apps by time
- [ ] Weekly chart shows 7 bars with correct relative heights
- [ ] All times formatted as "Xh Ym" (e.g. "1h 23m")
- [ ] Empty state shown when no usage data exists
- [ ] Pull-to-refresh triggers a fresh Supabase fetch
- [ ] Loading state shown while data is being fetched
