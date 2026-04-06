# screen-time
iOS application to track screen time and help you be more intentional about phone usage.

---

## Tech Stack
- **iOS:** Swift, SwiftUI, Swift Charts
- **Screen Time APIs:** Family Controls, DeviceActivity, ManagedSettings
- **Backend:** Supabase (PostgreSQL, Auth, Realtime)
- **Push Notifications:** APNs (Apple Push Notification service)

---

## Features

### Fully Planned
- Main app with graphs, usage history, and progress tracking
- Goal setting — set time limits per app/category and define *why* you want to reduce screen time (shown as reminders)
- Notifications when you've hit a session or daily time threshold (configurable)
- Prompt on phone unlock asking if you're going to be productive or just browsing
- Sort apps into custom buckets/categories
- App blocker — require a cooldown (N seconds) before opening certain apps *(requires Screen Time entitlement approval from Apple)*
- Friends — optional push notifications to shame friends who've been on their phone too long; friends can send encouraging messages back
- Location-based settings lock — settings/goals can only be edited when you're at a designated location (e.g. home), using CoreLocation
- Set week start day and timezone
- Mac sync — track computer usage using the same Supabase backend (later phase)

### Partially Possible (with caveats)
- Lock screen / Live Activity overlays showing current session time — Live Activities are the closest iOS allows; true overlays are not permitted
- App icon badges showing daily usage — only your own app's icon can be badged, not other apps'

### Not Possible on iOS
- Blocking a second device when one is already open — iOS does not allow cross-device app control

### To Explore / Figure Out
- **Widgets** — home screen and lock screen widgets showing today's usage at a glance; likely doable with WidgetKit but needs design and scoping
- **Daily/weekly summary notifications** — end-of-day and end-of-week recap of usage vs. goals; need to decide on format and timing
- **Insights engine** — pattern detection surfacing things like "you use Instagram most on Sunday nights"; needs data pipeline design and enough historical data to be meaningful

---

## Current Status
Planning phase complete. Tech stack decided (Swift/SwiftUI + Supabase). Feature set scoped and categorized. Build phases defined. Next step: set up Xcode project, register App ID/bundle identifier, and apply for Family Controls entitlement from Apple before beginning Phase 1 development.

---

## Build Phases

### Phase 1 — Foundation
- SwiftUI app skeleton and navigation structure
- Supabase project setup: auth, user profiles, schema design
- Screen Time API authorization (Family Controls entitlement)
- Basic DeviceActivity data capture and local storage

### Phase 2 — Core Tracking
- DeviceActivity reports pipeline
- Per-app and per-category usage data synced to Supabase
- App bucketing/categories UI

### Phase 3 — Insights UI
- Swift Charts graphs (daily, weekly trends)
- Usage history views
- Goal setting UI — time limits and personal "why" reminders

### Phase 4 — Notifications & Interventions
- Local notifications for session/daily time thresholds
- Unlock prompt (productive vs. entertainment)
- Goal reminder notifications
- Location-based settings lock (CoreLocation)

### Phase 5 — App Blocking
- ManagedSettings integration for app blocker/cooldown
- Apply for Screen Time entitlement from Apple

### Phase 6 — Social Layer
- Friend connections (Supabase)
- Shame push notifications via APNs
- Encouraging message replies

### Phase 7 — Mac Sync
- macOS companion app target
- Shared Supabase backend for cross-device usage data
