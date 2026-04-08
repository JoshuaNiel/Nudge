# DeviceActivity Data Pipeline

How usage data flows from Apple's Screen Time APIs into Supabase.

---

## Overview

Apple's Screen Time APIs are sandboxed — the main app cannot directly read usage numbers. Data flows through a chain:

```
DeviceActivity Framework
        ↓
DeviceActivityReport Extension (renders SwiftUI views with usage data)
        ↓
App Group Shared Container (UserDefaults or file system)
        ↓
Main App Target
        ↓
Supabase (usage table)
```

> TODO: Validate this flow against Apple's actual API constraints before Phase 1. Confirm whether the DeviceActivityReport extension can write to a shared App Group container, or whether another mechanism is needed.

---

## Monitoring Setup

> TODO: Document how DeviceActivityMonitor is configured.
> - What schedule is used? (e.g. monitor from midnight to midnight in user's timezone)
> - How is the monitoring session started/restarted daily?
> - What happens if the user force-quits the app — does monitoring continue?

DeviceActivity monitoring must be authorized via Family Controls entitlement. The user must grant permission explicitly.

---

## DeviceActivityReport Extension

> TODO: Document what the report extension renders and what data it surfaces.
> - What `ActivityReportContext` values are used?
> - How is per-app data (bundle ID, seconds, pickups) extracted from the report?
> - How is this data passed back to the main app?

---

## Shared App Group Container

> TODO: Define the App Group identifier (e.g. `group.com.yourname.nudge`).
> - What format is usage data written in? (JSON in UserDefaults? A flat file?)
> - Who writes to it (the extension) and who reads from it (the main app)?
> - Is there any conflict risk if the extension writes while the main app reads?

---

## Supabase Sync

> TODO: Define the sync trigger and strategy.
> - When does the main app read from the shared container and write to Supabase?
> - Options: background task (BGAppRefreshTask), on app foreground, at end of day?
> - What happens if sync fails (no internet)? Is there a retry queue?
> - Should we deduplicate — i.e. upsert on (userId, date, bundleId) to avoid duplicate rows?

Recommended: upsert on `(user_id, date, bundle_id)` so re-syncing is idempotent.

---

## Timezone Consideration

`usage.date` must be the user's local calendar date, not UTC. Derive it from the user's timezone on-device before writing.

See `database.md` for full timezone rules.

---

## Entitlements Required

- `com.apple.developer.family-controls` — required for DeviceActivity and ManagedSettings
- App Group entitlement — required for data sharing between targets

> TODO: Document the status of the Family Controls entitlement request from Apple. This entitlement requires explicit approval and can block Phase 1 if not applied for early.

---

## Open Questions

> TODO: Answer these before beginning Phase 2 (Core Tracking):
> - Can the DeviceActivityReport extension write to a shared container, or is another IPC mechanism needed?
> - How granular is Apple's data — per-app per-minute, or only per-app per-day?
> - Does Apple provide historical data before monitoring was enabled, or only from the start of monitoring?
> - How does the pipeline behave if the user denies Screen Time permission?
