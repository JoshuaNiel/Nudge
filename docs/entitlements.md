# Entitlements & Permissions

All entitlements, capabilities, and user-facing permissions required by the app.

---

## Apple Entitlements

These are provisioning-level entitlements configured in the Apple Developer portal and Xcode.

| Entitlement | Required For | Status | Notes |
|---|---|---|---|
| Family Controls | DeviceActivity, ManagedSettings, app blocking | TODO | Requires explicit approval from Apple — apply early |
| App Groups | Sharing data between app and extensions | TODO | Define group ID: `group.com.yourname.nudge` |
| Push Notifications | APNs social nudges | TODO | Standard capability, no special approval needed |
| Sign in with Apple | Auth (if offered) | TODO | Required if any other third-party auth is used |
| HealthKit | Not planned | N/A | |

> TODO: Apply for the Family Controls entitlement as early as possible. It is required for DeviceActivity monitoring (Phase 1/2) and app blocking (Phase 5). Approval can take time and will block development if not requested early.

---

## User-Facing Permissions

These are runtime permission prompts shown to the user.

| Permission | Required For | When to Request | Degraded State if Denied |
|---|---|---|---|
| Screen Time / Family Controls | All usage tracking | Onboarding | Core feature unavailable — app is non-functional without this |
| Notifications | Threshold alerts, reminders, nudges | Before first notification feature | Local notification features disabled; push disabled |
| Location (When In Use) | Settings location lock | When user enables the feature in settings | Location lock feature unavailable |

> TODO: Design the permission request flow in onboarding. Screen Time permission is the most critical — decide whether to gate the entire app on it or allow limited use without it.

> TODO: Write the usage description strings for Info.plist (`NSLocationWhenInUseUsageDescription`, etc.) with clear, user-friendly explanations of why each permission is needed.

---

## App Store Considerations

> TODO: Review before submission:
> - Account deletion flow is required by App Store guidelines (users must be able to delete their account and all associated data)
> - Privacy nutrition label — document all data collected and how it is used
> - If Sign in with Apple is not offered, confirm no other third-party auth is used
> - Screen Time entitlement must be approved before the app can be submitted

---

## Extension Targets & Entitlements

Each extension target must share the App Group entitlement with the main app. The Family Controls entitlement may also need to be applied to extension targets.

> TODO: Confirm which entitlements are required on each target (main app, DeviceActivityReport extension, DeviceActivityMonitor extension) and configure Xcode signing accordingly.
