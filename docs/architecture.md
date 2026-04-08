# App Architecture

Overall structure and design patterns for the Nudge iOS app.

---

## Pattern

> TODO: Confirm MVVM as the architectural pattern. Document any deviations or additions (e.g. a service layer, repositories, coordinators for navigation).

Likely: **MVVM + Service Layer**
- Views (SwiftUI) — UI only, no business logic
- ViewModels — state management, data transformation, binding to views
- Services — Supabase calls, DeviceActivity coordination, notification scheduling
- Models — plain Swift structs matching DB schema

---

## Folder Structure

> TODO: Define the folder/module structure before starting Phase 1. Consistency across phases is much easier to enforce if this is decided upfront.

Proposed structure (to be confirmed):
```
Nudge/
  App/                  # App entry point, root view
  Core/                 # Shared infrastructure (SupabaseClient, etc.)
  Features/
    Auth/
    Dashboard/
    Goals/
    AppCategories/
    Notifications/
    Social/
    Settings/
  Models/               # Codable structs matching DB schema
  Services/
    UsageService        # DeviceActivity coordination + Supabase sync
    GoalService
    NotificationService
    SocialService
    AuthService
  Extensions/           # DeviceActivityReport extension target
  Widgets/              # WidgetKit target (Phase 7)
```

---

## Data Flow

> TODO: Map out the full data flow for each major feature area. See individual docs for detail:
> - `deviceactivity-pipeline.md` — usage data from Apple → Supabase
> - `notifications.md` — local and push notification triggers
> - `social.md` — friend connections and nudges

---

## State Management

> TODO: Decide how global state is handled.
> - SwiftUI `@EnvironmentObject` for auth session and user profile?
> - Supabase Realtime for live friend nudges?
> - Where does the current day's usage state live?

---

## Navigation

> TODO: Decide on navigation pattern.
> - Tab-based root navigation (Dashboard, Goals, Friends, Settings)?
> - Define tab structure and what lives in each tab.
> - How are modals and sheets handled?

---

## Dependency Management

> TODO: Confirm Swift Package Manager as the sole dependency manager. Document all third-party packages and why each is included.

Known packages:
- `supabase-swift` — Supabase client

---

## Extension Targets

The app will require multiple targets beyond the main app:

| Target | Purpose | Phase |
|---|---|---|
| DeviceActivityReport extension | Render usage data from Apple's APIs | 1 |
| DeviceActivityMonitor extension | Respond to usage events (thresholds) | 4 |
| WidgetKit extension | Home/lock screen widgets | To explore |

> TODO: Document the App Group identifier used to share data between targets. All targets must share the same App Group to communicate via UserDefaults or the file system.
