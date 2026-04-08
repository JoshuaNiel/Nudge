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

Implemented structure (as of Phase 1):

```
Nudge/
  Core/
    AppState.swift          # Global auth state, session listener
    RootView.swift          # Root gating view (loading → onboarding → main app)
    SupabaseClient.swift    # Supabase client singleton
  Features/
    Auth/
      AuthView.swift              # Sign in / sign up (email + Apple)
      OnboardingCoordinator.swift # Drives the full onboarding sequence
      OnboardingTourView.swift    # Feature tour slides
      PermissionsView.swift       # Screen Time + notification permission prompts
      ProfileSetupView.swift      # Name collection after sign up
    Dashboard/
    Goals/
    Apps/
    Social/
    Settings/
  Models/
    AppUsage.swift          # (needs update to match DB schema column names)
    Goal.swift              # (needs update to match DB schema column names)
  Services/
    AuthService.swift       # Supabase auth calls (sign up, sign in, Apple, profile patch)
    UsageService            # (Phase 1/2 — DeviceActivity + Supabase sync)
    GoalService             # (Phase 3)
    NotificationService     # (Phase 4)
    SocialService           # (Phase 5)
```

Future targets (not yet added):
```
  Extensions/             # DeviceActivityReport extension (Phase 1)
  Widgets/                # WidgetKit extension (Phase 7)
```

---

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
| Real-time nudges | Supabase Realtime (Phase 5) | TBD |

---

## Navigation

- **Root**: `RootView` switches between onboarding and main app based on auth + onboarding state
- **Main app**: Tab-based (`TabView`) with 5 tabs: Dashboard, Apps, Goals, Friends, Settings
- **Onboarding**: Linear step-based flow driven by `OnboardingCoordinator` (no NavigationStack — steps swap in place)
- **Modals/sheets**: Handled per-feature (TBD as features are built)

---

## Dependency Management

Swift Package Manager only. No CocoaPods or Carthage.

| Package | Version | Purpose |
|---|---|---|
| `supabase-swift` | ≥ 2.5.1 | Database, auth, realtime |

Products linked: `Supabase`, `Auth`, `Realtime`

---

## Extension Targets

| Target | Purpose | Phase | Status |
|---|---|---|---|
| DeviceActivityReport extension | Render usage data from Apple's APIs | 1 | Not yet created |
| DeviceActivityMonitor extension | Respond to usage threshold events | 4 | Not yet created |
| WidgetKit extension | Home/lock screen widgets | 7 | Not yet created |

All extension targets must share an App Group with the main app to communicate via UserDefaults or the file system. App Group ID to be defined when first extension is created.
