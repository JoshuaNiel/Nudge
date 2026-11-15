# Backlog

Parking lot for future features and known bugs. Nothing here is actively scheduled — move items into a phase spec when they become real work.

---

## Next up (spec'd or close to it)

- **Weekly goals.** Spec drafted in `specs/weekly-goals.md`; it waits on three user answers. Uses a second `nudge.weekly` activity with its own re-arm, period-scoped progress and dedup, and a "Week starts on" setting.
- **`includesPastActivity: true` on DeviceActivity events.** Available on iOS 17.4+ (deployment target is 17.6). Re-registering mid-day would then keep counting from midnight instead of resetting, which removes ADR-054's trade-off; the once-per-day dedup already handles any re-fired milestones. Needs a device test. It's part of the weekly-goals spec (W4) but can ship on its own.

## Future Features

- **Monthly goals.** Not feasible with one monitoring interval, since intervals can't exceed a week (ADR-060). It could be approximated by chaining weekly intervals with carried-over usage, but carry-over can't be measured precisely.
- **Per-friend trigger configuration.** Choose which trigger types each friend receives (e.g. Mom gets the daily report only). Needs a `friend_trigger` junction table `(friend_id, trigger_type, enabled)` next to `nudge_settings` (ADR-062), plus per-friend UI.
- **Mac sync.** Sync goals across Mac using the same Supabase backend.
- **WidgetKit.** A home or lock screen widget for today's goal progress. It could read the App Group milestone progress (ADR-058).
- **App blocking.** Hard-block apps when a goal limit is hit. Needs the ManagedSettings shield, which is a separate Apple approval.
- **Location-based settings lock.** A CoreLocation check when the Settings screen opens.
- **True continuous-session detection.** `session.timeout` fires on accumulated daily total, not continuous use. Explore `DeviceActivitySchedule.warningTime` or short overlapping schedules.

## Security

- **`send-consent` trusts its webhook payload, so it can be abused to send SMS.** The gateway accepts the public anon key, so a crafted POST could make the function text arbitrary numbers. Fix, in order of preference:
  1. Re-fetch the friend row with the service client and send only if it exists and `status = 'pending'`.
  2. A shared-secret webhook header.
  3. Per-number rate limiting.

  `send-nudge` and `delete-account` are not affected: both check `getUser()`.
- **Re-enable gateway `verify_jwt`** on `send-nudge` and `delete-account` once Supabase supports ES256 verification at the gateway (ADR-050/067).
- **Account deletion re-authentication.** Consider asking for the password (or Apple re-auth) before deleting.

## Auth

- **Sign in with Apple isn't configured on the Supabase backend.** Either configure the provider (Service ID, Team ID, Key ID, `.p8`) or hide the button. Apple also expects SIWA tokens to be revoked on account deletion (#19 doesn't do this).
- **Password minimum mismatch.** The set-new-password screen requires 8 characters, but sign-up validation doesn't. Align sign-up and set Supabase's minimum to 8.
- **Re-enable email confirmation** (ADR-004) after testing #16's confirmation link.

## APNs / Social

- **Stale APNs tokens.** Rows for rotated tokens or uninstalled apps linger, because RLS only lets a device delete its own row while signed in. Fix server-side: `receive-reply` deletes the token row when APNs returns `410 Unregistered` or `400 BadDeviceToken`.
- **Per-token APNs environment.** `APNS_SANDBOX` is one global flag, so dev and production devices can't both receive pushes at once. Store the environment with each token.
- **Realtime teardown lingers when the socket is already dead.** Harmless (no UI effect), but the cleanup task waits on a reply that never comes.

## Account deletion

- **Lost response.** If the server deletes the account but the response is lost, the app shows an error and stays signed in until the next token refresh fails. Consider treating a 401 on the next call as "deleted" and running local cleanup.

## Database cleanup (after all PRs merge and run)

- Drop the deprecated `profile.session_timeout_minutes` (ADR-062), `goal.bundle_id`, and the `app`, `app_category_member` and `usage` tables (ADR-049/057). `usage.app_id`, `goal.bundle_id` and `app_category_member.bundle_id` reference `app` and must be dropped first.
- Bring `supabase/schema.sql` up to date with migrations 001–008 (it currently reflects only the base schema).

## Known Bugs / Tech Debt

- **Device restart may need one app open.** If a reboot clears `DeviceActivityCenter.activities`, the extension gets no callbacks to re-arm from. Not yet verified on device.
- **Extension `BGTaskScheduler.submit`.** The identifier is now permitted in the extension's Info.plist (#13). Confirm on device that the submit succeeds; if it doesn't, drop the call (the queue still drains on foreground).
- **Settings Save bar rides up with the keyboard.** It should stay pinned at the physical bottom like the tab bar. Options: `.toolbar(placement: .bottomBar)`, a keyboard-height observer, or a custom `safeAreaInset`. Needs iterating on a device.
- **Event budget.** The worst case is goals × 10 + 48 + 1 events per registration; a warning is logged above 200. Apple's real limit is undocumented, so watch for `excessiveActivities`-style failures on device.
- **A UI-test target** would cover layout and keyboard behaviour that unit tests can't.
