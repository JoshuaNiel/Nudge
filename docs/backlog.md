# Backlog

Parking lot for future features and known bugs. Nothing here is actively scheduled — move items into a phase spec when they become real work.

---

## Next up (spec'd or close to it)

- **Weekly goals.** Spec drafted in `specs/weekly-goals.md`; it waits on three user answers. Uses a second `nudge.weekly` activity with its own re-arm, period-scoped progress and dedup, and a "Week starts on" setting.

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
- **Rework when the onboarding tour shows.** Today the tour shows on every fresh start of the onboarding flow: a first launch, any sign-out, and any relaunch while signed out. Only "Back to Sign In" after an account deletion skips it (#19, account-deletion spec D). The user wants to revisit when it appears, and has other tweaks for the tour itself; get the details from the user before speccing. Related to the returning-user item below. (User request 2026-11-23.)
- **A returning user on a new device or reinstall redoes onboarding.** `onboardingComplete` is a device-local `@AppStorage` flag, so signing in to an existing account on a fresh install walks through profile setup and permissions again. (Found 2026-11-23 on the Simulator.) Fix: after sign-in, skip profile setup when the `profile` row already has a name, and show permissions only for permissions that aren't granted on this device. Set the flag once both are satisfied.

## APNs / Social

- **Stale APNs tokens.** Rows for rotated tokens or uninstalled apps linger, because RLS only lets a device delete its own row while signed in. Fix server-side: `receive-reply` deletes the token row when APNs returns `410 Unregistered` or `400 BadDeviceToken`.
- **A device token can stay attached to the previous user.** `device_tokens` is unique on `(user_id, token)`. Sign-out deletes this device's row best-effort (5 s cap). If that fails, for example offline, and a different user then signs in on the same phone, the old row survives, and the previous user's reply pushes land on the new user's phone. Fix: make `token` unique, and add a `security definer` RPC `claim_device_token(token)` that deletes other users' rows for that token before the upsert. (Deferred from #14 by the user, 2026-11-23.)
- **Refine the friend-reply copy.** `receive-reply` builds the push the user sees when a friend answers a nudge. Review all of it together:
  - **Push title:** `Message from <friend_name>`.
  - **Canned reply 1 (encouragement)** and **reply 2 (reality check)** are hardcoded in `receive-reply/index.ts`. Reply 2 always says "4 hours a day is 25% of your waking hours", whatever the user's actual usage or limit. It could use the real figure from the nudge's report.
  - **The SMS reply options** (`_shared/messages.ts` `REPLY_OPTIONS`) that friends see.
  - Consider moving the canned replies into `_shared/messages.ts` next to the rest of the copy. (User request 2026-11-23.)
- **Per-token APNs environment.** `APNS_SANDBOX` is one global flag, so dev and production devices can't both receive pushes at once. Store the environment with each token.
- **Realtime teardown lingers when the socket is already dead.** Harmless (no UI effect), but the cleanup task waits on a reply that never comes.

## Account deletion

- **Lost response.** If the server deletes the account but the response is lost, the app shows an error and stays signed in until the next token refresh fails. Consider treating a 401 on the next call as "deleted" and running local cleanup.
- **Tell friends when an account is deleted.** Send each accepted friend a one-time SMS, e.g. "<Name> has stopped using Nudge. You won't get any more messages from them." It has to go out *before* the auth user is deleted, because the friend rows cascade with it. That means `delete-account` reads the accepted friends with the service client, sends best-effort (a failure must not block the deletion), then deletes. Copy goes in `_shared/messages.ts`. Blocked on SMS sending working. (User request 2026-11-23.)

## Database cleanup (after all PRs merge and run)

- Drop the deprecated `profile.session_timeout_minutes` (ADR-062), `goal.bundle_id`, and the `app`, `app_category_member` and `usage` tables (ADR-049/057). `usage.app_id`, `goal.bundle_id` and `app_category_member.bundle_id` reference `app` and must be dropped first.
- Bring `supabase/schema.sql` up to date with migrations 001–008 (it currently reflects only the base schema).

## Known Bugs / Tech Debt

- **SMS sending is failing.** `send-nudge` returned `502`, then `429`, for every drain on 2026-11-23. The user is investigating it separately; SMS is out of scope for device testing until it's fixed. Since #13 the drain stops at the first failure and expires triggers at the end of their day, so the backlog no longer piles up.
- **Device restart may need one app open.** If a reboot clears `DeviceActivityCenter.activities`, the extension gets no callbacks to re-arm from. Not yet verified on device.
- **Extension `BGTaskScheduler.submit`.** The identifier is now permitted in the extension's Info.plist (#13). Confirm on device that the submit succeeds; if it doesn't, drop the call (the queue still drains on foreground).
- **Settings Save bar rides up with the keyboard.** It should stay pinned at the physical bottom like the tab bar. Options: `.toolbar(placement: .bottomBar)`, a keyboard-height observer, or a custom `safeAreaInset`. Needs iterating on a device.
- **Event budget.** The worst case is goals × 10 + 48 + 1 events per registration; a warning is logged above 200. Apple's real limit is undocumented, so watch for `excessiveActivities`-style failures on device.
- **A UI-test target** would cover layout and keyboard behaviour that unit tests can't.
