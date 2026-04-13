# Phase 3 — Goals

**Status:** `[ ] Ready to start`

**Goal:** Let users create time-limit goals for apps, custom categories, or total usage. Show progress toward each goal. Evaluate goals against usage data when Phase 1 is complete.

---

## Prerequisites

- [x] Auth complete
- [x] DB schema deployed (`goal`, `app_category`, `app_category_member` tables)
- [ ] `Goal.swift` model updated (task below)
- [ ] Phase 1 complete for live goal progress — can show goals UI and mock progress beforehand

---

## Tasks

### Models
- [ ] Update `Goal.swift` to match `goal` table schema:
  ```swift
  struct Goal: Codable, Identifiable {
      let id: Int
      let userId: UUID           // user_id
      let limitSeconds: Int      // limit_seconds
      let frequency: GoalFrequency
      let targetType: GoalTargetType  // target_type
      let bundleId: String?      // bundle_id — set when targetType = .app
      let categoryId: Int?       // category_id — set when targetType = .category
      let temporary: Bool
      let startDate: String?     // start_date "YYYY-MM-DD"
      let endDate: String?       // end_date "YYYY-MM-DD"
  }
  
  enum GoalFrequency: String, Codable { case daily, weekly, monthly }
  enum GoalTargetType: String, Codable { case app, category, total }
  ```

- [ ] Add `AppCategory` model:
  ```swift
  struct AppCategory: Codable, Identifiable {
      let id: Int
      let userId: UUID   // user_id
      let name: String
      let color: String  // hex "#RRGGBB"
  }
  ```

- [ ] Add `AppCategoryMember` model:
  ```swift
  struct AppCategoryMember: Codable {
      let bundleId: String    // bundle_id
      let categoryId: Int     // category_id
  }
  ```

### Service Layer
- [ ] Create `GoalService`:
  ```swift
  class GoalService {
      func fetchGoals(userId: UUID) async throws -> [Goal]
      func createGoal(_ goal: GoalInsert) async throws
      func deleteGoal(id: Int) async throws
  }
  
  struct GoalInsert: Encodable {
      let userId: UUID
      let limitSeconds: Int
      let frequency: GoalFrequency
      let targetType: GoalTargetType
      let bundleId: String?
      let categoryId: Int?
      let temporary: Bool
      let startDate: String?
      let endDate: String?
  }
  ```

- [ ] Create `CategoryService`:
  ```swift
  class CategoryService {
      func fetchCategories(userId: UUID) async throws -> [AppCategory]
      func createCategory(userId: UUID, name: String, color: String) async throws -> AppCategory
      func deleteCategory(id: Int) async throws
      func addApp(bundleId: String, categoryId: Int) async throws
      func removeApp(bundleId: String, categoryId: Int) async throws
      func fetchMembers(categoryId: Int) async throws -> [String]  // returns bundle IDs
  }
  ```

- [ ] Create `GoalEvaluationService` (depends on Phase 1 data):
  ```swift
  class GoalEvaluationService {
      // Returns seconds used in the goal's current window (daily/weekly/monthly)
      func fetchUsedSeconds(goal: Goal, userId: UUID, timeZone: TimeZone, weekStart: Int) async throws -> Int
  }
  ```
  - For `daily`: sum `usage.seconds` where `date = today`
  - For `weekly`: sum where `date` is between current week start and today (using `weekStart` from profile)
  - For `monthly`: sum where `date` is in current calendar month

### Goals ViewModel & View
- [ ] Create `GoalsViewModel`
  - `@Published var goals: [GoalWithProgress]`
  - `@Published var isLoading: Bool`
  - `func load() async`
  - `func deleteGoal(_ goal: Goal) async`

  ```swift
  struct GoalWithProgress {
      let goal: Goal
      let usedSeconds: Int    // from GoalEvaluationService (0 until Phase 1 complete)
      var progressFraction: Double { min(Double(usedSeconds) / Double(goal.limitSeconds), 1.0) }
      var isExceeded: Bool { usedSeconds >= goal.limitSeconds }
  }
  ```

- [ ] Replace `GoalsView` stub:
  - List of active goals, each showing target name, used/limit (e.g. "1h 23m / 2h"), progress bar
  - "Add Goal" button → sheet

- [ ] Goal creation sheet:
  - Step 1: Choose target type (App / Category / Total)
  - Step 2 (if App): Pick from list of apps seen in usage data (`app` table)
  - Step 2 (if Category): Pick from user's categories or create new
  - Step 3: Set limit (time picker — hours + minutes)
  - Step 4: Set frequency (Daily / Weekly / Monthly)
  - Step 4b: Toggle temporary goal → date range picker
  - Confirm → calls `GoalService.createGoal`

### App Category Management
- [ ] Category list in Settings (or Goals tab)
- [ ] Create category: name + color picker
- [ ] Add/remove apps from a category (pick from `app` table)
- [ ] Delete category (cascades to members and goals via DB)

---

## Data Contracts

### Supabase — fetch goals
```swift
supabase
    .from("goal")
    .select()
    .eq("user_id", value: userId)
    .execute()
```

### Supabase — create goal
```swift
supabase
    .from("goal")
    .insert(goalInsert)
    .execute()
```

### Supabase — evaluate daily goal
```swift
supabase
    .from("usage")
    .select("seconds")
    .eq("user_id", value: userId)
    .eq("date", value: todayString)
    // if targetType = .app: also .eq("app_id", value: bundleId)
    // if targetType = .category: also .in("app_id", values: memberBundleIds)
    // if targetType = .total: no additional filter
    .execute()
// Sum all returned seconds client-side
```

---

## Open Questions

> None blocking for UI work. Goal evaluation requires Phase 1 data.

---

## Acceptance Criteria

- [ ] User can create an app goal, category goal, and total usage goal
- [ ] User can set daily, weekly, or monthly frequency
- [ ] User can create a temporary goal with a date range
- [ ] Goals list shows each goal's progress (used / limit) and a progress bar
- [ ] Deleting a goal removes it from Supabase and the UI immediately
- [ ] Creating a duplicate non-temporary goal (same target + frequency) fails gracefully with a user-facing error
- [ ] User can create, rename (color), and delete custom app categories
- [ ] User can add and remove apps from a category
