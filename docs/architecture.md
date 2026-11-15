# App Architecture

Overall structure and design patterns for the Nudge iOS app.

---

## Pattern

**MVVM + Service Layer**

- **Views** (SwiftUI) — UI only, no business logic
- **ViewModels** — state management, data transformation, binding to views (added per feature as needed)
- **Services** — Supabase calls, DeviceActivity coordination, notification scheduling
- **Models** — plain Swift structs matching DB schema (Codable, snake_case → camelCase via Supabase decoder)

Global auth state and the current user are held in `AppState`, which is injected at the root via `@EnvironmentObject`.

---

## Folder Structure

As of the 2026-11-14 PR stack. Filesystem-synchronized folders mean new files are picked up by their target automatically.

```
Nudge/
  Nudge/                      # main app target
    Core/                     # AppState, RootView, SupabaseClient, AppDelegate (APNs),
                              # PushRouter / PushTokenManager, AuthDeepLink, Validation, Color+Hex
    Features/
      Auth/                   # AuthView, onboarding, PermissionsView, ForgotPassword / SetNewPassword
      Dashboard/              # DashboardView (hosts DeviceActivityReport), DashboardAvailability
      Goals/                  # GoalsView/VM, AddGoalSheet/VM, GoalDetailView, GoalRules,
                              # why-reminder section + editor (Phase 4)
      Categories/             # CategoriesView/VM, CategoryEditorSheet/VM, CategoryRules
      Social/                 # SocialView/VM, NudgeHistoryViewModel (realtime)
      Settings/               # SettingsView/VM, Nudges section (5E), Notifications section, account deletion
      Shared/                 # CountryPhoneField, ScreenTimeAccessRequiredView
    Models/                   # Goal, Social, Profile, NudgeSettings, WhyReminder, DeviceToken
    Services/                 # Auth, Goal, Category, Friend, Nudge, NudgeTrigger, MonitoringRegistration,
                              # DeviceToken, NudgeRealtime, NudgeSettings, Reminder, Account, AccountCleanup
  Shared/                     # compiled into the app AND both extensions (ADR-056/069)
                              # MonitoringPlan, MonitoringEvents, ThresholdRouter, GoalProgressStore,
                              # SelectionCodec, AppGroupKeys, MonitoringModels, NudgeMessages,
                              # NudgeTriggerSettings, DailyReport, PendingTriggerQueue, WhyReminderStore,
                              # UsageSummary, GoalUsage, DurationFormatting, ReportContext (not in monitor)
  NudgeActivityMonitor/       # DeviceActivityMonitor extension — thresholds, re-arm, notifications, queue
  NudgeActivityReport/        # DeviceActivityReport extension — dashboard + goalUsage scenes (display only)
  NudgeTests/                 # Swift Testing suites
design/app-icon/              # icon concepts + CoreGraphics render script
supabase/                     # schema.sql, migrations/, functions/ (send-consent, send-nudge,
                              # receive-reply, delete-account)
```

## Key Architectural Decisions

### Default Actor Isolation
The Xcode project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` set as a build setting. All code is implicitly `@MainActor` unless explicitly marked otherwise. This simplifies SwiftUI state management but means any CPU-heavy work must be explicitly dispatched off the main actor.

### Credentials
Supabase credentials are stored in `Config.xcconfig` (gitignored) and exposed to Swift via Info.plist build setting interpolation. Keys: `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. See `SupabaseClient.swift`.

### Onboarding Gating
`RootView` gates the app on two conditions: `AppState.isAuthenticated` (Supabase session) and `onboardingComplete` (persisted via `@AppStorage`). Both must be true to show the main tab view. `OnboardingCoordinator` drives the sequence: tour → auth → profile setup → permissions.

### Session Management
`AppState` listens to `supabase.auth.authStateChanges` (an `AsyncSequence`) on init. This handles initial session restore, sign-in, sign-out, and token refresh automatically. No manual token management needed.

---

## State Management

| State | Where it lives | How it's shared |
|---|---|---|
| Auth session + current user | `AppState` | `@EnvironmentObject` from `NudgeApp` |
| Onboarding completion | `@AppStorage("onboardingComplete")` | Persisted via UserDefaults |
| Feature-level UI state | Per-feature ViewModels (to be added) | `@StateObject` / `@ObservedObject` |
| Real-time nudge status | Supabase Realtime subscription on `nudge` (per history screen) | `NudgeHistoryViewModel` (ADR-068) |
| Monitoring + extension shared state | App Group `group.com.joshuaqn.Nudge` (goal catalog, progress, settings, whys, trigger queue) | `Shared/` types (see `AppGroupKeys`) |
| Push deep link | `PushRouter` owned by `AppDelegate` | `@EnvironmentObject` |

---

## Navigation

- **Root**: `RootView` switches between onboarding and main app based on auth + onboarding state
- **Main app**: Tab-based (`TabView`) with 5 tabs: Dashboard, Categories, Goals, Friends, Settings (selection is state-driven so push taps can switch to Friends)
- **Onboarding**: Linear step-based flow driven by `OnboardingCoordinator` (no NavigationStack — steps swap in place)
- **Modals/sheets**: Handled per-feature (TBD as features are built)

---

## Platform

| | |
|---|---|
| Minimum deployment target | iOS 17.6 (project setting) |
| Primary language | Swift |
| UI framework | SwiftUI |

All APIs used (DeviceActivity, FamilyControls, Swift Charts, `AuthorizationCenter`) are available on iOS 15+, so iOS 17 imposes no additional API constraints.

---

## Dependency Management

Swift Package Manager only. No CocoaPods or Carthage.

| Package | Version | Purpose |
|---|---|---|
| `supabase-swift` | ≥ 2.5.1 | Database, auth, realtime |

Products linked: `Supabase`, `Auth`, `Realtime`

---

## Extension Targets

| Target | Purpose | Status |
|---|---|---|
| `NudgeActivityMonitor` | Threshold callbacks: milestones → progress/whys/limit notification, session timeout, daily-report totals; daily re-arm; Strategy 2 trigger queue | Built |
| `NudgeActivityReport` | Renders Screen Time data (Dashboard, per-goal exact usage). Sandboxed, display-only (ADR-049) | Built |
| WidgetKit | Home/lock screen widgets | Backlog |

All targets share the App Group `group.com.joshuaqn.Nudge` and Family Controls entitlements.
