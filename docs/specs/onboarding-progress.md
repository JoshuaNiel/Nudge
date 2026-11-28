# Onboarding Progress + Permission Banners

Branch `feat/onboarding-progress` (from `main` after #16). Decisions confirmed with the user on
2026-11-27. **Status: approved by the user 2026-11-27. Implementing.**

Replaces the device-local `@AppStorage("onboardingComplete")` flag. Fixes the backlog item
"A returning user on a new device or reinstall redoes onboarding".

---

## 1. Model: account steps vs device steps

| Kind | Examples | Where it's decided | Stored? |
|---|---|---|---|
| **Account steps** | profile (name); later: first goal, add a friend | server function `onboarding_status()` plus a device copy | yes, per account |
| **Device steps** | Screen Time access, notifications | the device's real permission status | no (re-checked on each device) |

Onboarding today: tour → sign in/up → (confirm email) → **profile setup** → **permissions** → app.
The tour, auth and confirm-email steps are unchanged.

---

## 2. Database (migration `009_onboarding_progress.sql`)

Numbered 009 because 006–008 are reserved by open PRs (#18, #23, #21). It is independent of them
and can be run in any order.

- `alter table public.profile add column onboarding_completed boolean not null default false;`
- **Backfill:** `update public.profile set onboarding_completed = true where nullif(trim(first_name),'') is not null and nullif(trim(last_name),'') is not null;`
  so existing users who finished profile setup are never sent back.
- **Function `public.onboarding_status()`:** `returns jsonb`, `language sql`, `stable`,
  `security invoker`, `set search_path = ''`. It reads the caller's own profile via
  `auth.uid()` (existing RLS applies). Returns:
  ```json
  { "completed": true|false, "next_step": "profile" | null }
  ```
  - `completed` = `profile.onboarding_completed`.
  - `next_step` = the first account step not yet satisfied, in order. Today the only step is
    `"profile"`, satisfied when `first_name` and `last_name` are both non-blank. Returns `null`
    when all account steps are satisfied.
  - Future steps are added here, in order, so changing the flow means changing this function
    only. A step added later does **not** send users with `completed = true` back into onboarding
    (the app may show it as an optional prompt instead; out of scope here).
- `grant execute on function public.onboarding_status() to authenticated;` and revoke from
  `anon`/`public`.
- **Marking completion:** the app writes `profile.onboarding_completed = true` with a normal
  update (the existing "own profile" update policy). Merge rule: it never goes back to false (the
  app never sends false).
- Idempotent (`add column if not exists`, `create or replace function`), plus a verify query in
  the file.

---

## 3. Device copy + outbox (offline support for onboarding)

### 3.1 Onboarding state on the device
`OnboardingStore`, persisted in standard `UserDefaults`, **keyed by user id**:
```
{ completed: Bool, nextStep: String?, firstName: String?, lastName: String?, updatedAt: Date }
```
- The app decides where to go from the **device copy first**, then refreshes it from
  `onboarding_status()` when online. A server answer is merged in (see 3.3) and never blocks the
  UI when a device copy exists.
- **No device copy** (first launch after this update, or new device):
  - If the old `@AppStorage("onboardingComplete")` is `true` → treat as completed (seed the copy
    and queue a `markOnboardingCompleted` so the server learns it), then delete the old key.
  - Else, online → fetch `onboarding_status()` and seed the copy from it.
  - Else (offline) → start at profile setup. It works offline and the outbox syncs it later.
- Account deletion and sign-out: deletion wipes the copy for that user. Sign-out keeps it, so a
  re-sign-in on this device has it offline.

### 3.2 Outbox (reusable; the foundation for app-wide offline-first)
A small generic queue of pending server writes, persisted on the device:
- `PendingWrite { id: UUID, userId: UUID, kind: String, payload: Data (JSON), createdAt: Date, attempts: Int }`
- Kinds in this PR: `updateProfileName(firstName, lastName)` and `markOnboardingCompleted`.
- **Enqueue:** the change is applied to the device copy **immediately** and the write is queued.
  The UI proceeds as if it succeeded.
- **Flush:** runs on foreground (once per real foreground, via `ForegroundSync`), when the network
  becomes reachable (`NWPathMonitor`), and right after an enqueue while online. Writes are sent in
  order, oldest first, only for the signed-in user. Each one is removed after the server accepts
  it.
  - Network / 5xx / 429 errors → stop the flush (keep order), retry on the next trigger.
  - Permanent 4xx (e.g. a check constraint) → drop that write, log it, and continue.
  - Single flight: one flush at a time.
- **Coalescing:** a newer `updateProfileName` replaces an older queued one for the same user.
  `markOnboardingCompleted` is queued at most once.
- Writes for another user stay queued until that user signs in again. A user's writes are deleted
  on account deletion.
- It is a generic type (`Outbox<Kind>` or kind → handler registration) so later features can add
  kinds without changing the queue.

### 3.3 Merge rules (device copy ← server)
- `completed`: device OR server (never goes back to false). If the device is true and the server
  false, the queued `markOnboardingCompleted` fixes the server.
- Profile name: if a queued `updateProfileName` exists, the device value wins (it's the newest the
  user typed). Otherwise the server value replaces the device value.
- `nextStep`: recomputed on the device from the merged data with the same rule as the server
  (profile = both names non-blank). The device logic mirrors the server function, and the server
  is authoritative once synced.

---

## 4. Routing

`RootView` / `OnboardingCoordinator` decide the signed-in destination:
1. Account step pending (`nextStep == "profile"`) → **profile setup**.
2. Otherwise, if not completed or a device permission was never asked → **permissions screen**,
   showing only the permissions that are `notDetermined` (Screen Time and/or notifications). A
   permission the user denied counts as asked (iOS won't re-prompt).
3. Otherwise → the app.

- Finishing the permissions screen (granted, denied or "Skip for now") with all account steps
  satisfied → set `completed = true` in the device copy plus the outbox.
- A completed user on a **new device or reinstall** sees only the permissions screen (step 2) if a
  permission hasn't been asked there, never profile setup again.
- Profile setup saves through the device copy plus the outbox (works offline), then advances.
- The existing account-deletion "Back to Sign In" (`onboardingStart = .auth`) still works.

---

## 5. Permission banners

After onboarding, a compact, **non-dismissible** banner at the top of affected screens. It's
re-checked on every real foreground and after returning from Settings.

| Condition | Text | Action | Screens |
|---|---|---|---|
| Screen Time not approved | "Screen Time access needed. Nudge can't track your usage or goals." | **Allow**: if `notDetermined`, request authorization; if denied, open the app's Settings page | ~~Dashboard,~~ Goals (2026-11-27: the Dashboard shows its own full-screen access state instead; phase-2-dashboard.md D1) |
| Notifications not authorized (denied or not determined) | "Notifications are off. You won't be alerted when you hit a limit." | **Turn On**: if `notDetermined`, request authorization; if denied, open the app's notification settings | Dashboard, Goals, Friends |

- One reusable `PermissionBanner` view, plus a `PermissionStatusProvider` (protocol, injectable)
  with the current Screen Time and notification statuses, published and refreshed on foreground.
- Both banners can show at once (stacked).
- `provisional` / `ephemeral` notification statuses count as on.

---

## 5b. Ask once, then banners and in-context asks (user decisions 2026-11-27)

Supersedes the "Skip for now" handling and the banner actions above, where they differ.

- **The full-screen permissions page appears at most once per device.** Reaching it records a
  device-local `permissionsPageShown = true` (standard `UserDefaults`, not per user, never
  synced). Whatever the user does there (Allow, Deny, Skip for now) finishes it. Routing never
  shows it again on this device, even if a permission is still `notDetermined`. A reinstall or
  new device counts as new. Remove the session-only "skipped" set.
- **Existing devices after this update:** if `permissionsPageShown` is missing but the legacy
  onboarding flag was true, or the device copy says completed, treat the page as already shown.
  Don't show it to existing users.
- **Banner and sheet actions:**
  - **Screen Time:** always calls `AuthorizationCenter.requestAuthorization(for: .individual)`
    (the system prompt), whatever the current status. Never opens Settings.
  - **Notifications:** if `notDetermined` → system prompt (button "Turn On"). If denied → the
    button reads **"Open Settings"** and opens the app's notification settings
    (`UIApplication.openNotificationSettingsURLString`). iOS can't re-prompt after a denial.
- **In-context asks on the Goals tab:**
  - Tapping **+ (Add goal)** without Screen Time approved → a small sheet: "Nudge needs Screen
    Time access to track goals." **Allow** (system prompt; on approval the add-goal flow
    continues) / **Not now** (closes; the add-goal flow does not open, because goals can't work
    without Screen Time).
  - **Saving a goal** while notifications are not authorized → after the save succeeds, a sheet:
    "Turn on notifications so Nudge can alert you when you hit this limit." **Turn On** /
    **Open Settings** (per status above) / **Not now**. The goal is saved either way.
  - "Not now" is never remembered. The ask appears again on the next attempt.
- **Note:** PR #22 later replaces the Goals UI. Its add/save entry points must carry these asks
  forward when it is merged.
- **Done when (5b):**
  - Unit tests:
    - the page is shown once (flag set on reaching it; never again even with notDetermined);
    - existing-user inference;
    - the banner/sheet action choice per status (Screen Time always prompts; notifications
      prompt vs. Open Settings);
    - the add-goal gate (blocked without Screen Time, continues on approval);
    - the post-save notification ask.
  - On device: Skip on the page → never shown again; tapping + without Screen Time → sheet →
    prompt; saving a goal with notifications denied → sheet with Open Settings.

## 5c. Banner layout + Screen Time status freshness (user feedback 2026-11-27)
- **Header:** every main tab (Dashboard, Goals, Categories, Friends, Settings) always shows the
  navigation bar's gray background (`.toolbarBackground(.visible, for: .navigationBar)`,
  system material), whether or not a banner is present.
- **Banners are not part of the header.** They render as the first element of the page content,
  below the navigation bar, with standard page padding (`docs/conventions.md` spacing). Remove
  the `safeAreaInset` placement. They must not be drawn on the bar's background. Banners still
  stay visible regardless of empty, loading or error states.
- **Screen Time status freshness:** `SystemPermissionStatusProvider` observes
  `AuthorizationCenter.shared.$authorizationStatus` (Combine) and republishes changes, in
  addition to the foreground refresh, so a revoked or granted Screen Time permission updates the
  banner without relying on a cached read.
- Done when: unit tests for the provider publishing a status change from an injected publisher;
  on device, the header is gray on all tabs, the banners sit below it, and revoking Screen Time
  shows its banner.

## 5d. Main-tab header style (user decision 2026-11-27, PR #15 review)
- **Every main tab** (Dashboard, Apps, Goals, Friends, Settings; and Categories when #22 lands)
  uses the same header: the compact, inline-height navigation bar (no large title), with the
  tab's title **left-aligned** at the leading edge in a slightly larger, bold font
  (`.title3.bold()`, ~20pt, vs. the standard 17pt inline title). The gray bar background from
  §5c is kept.
- Implemented once, in the shared `mainTabHeader(title:)` modifier (replacing today's
  `mainTabHeader()` and each tab's own `.navigationTitle`), so the tabs can't drift apart.
  The tab's `navigationTitle` is still set (for accessibility, and as the back-button label on
  pushed screens such as the friend screen), but the centered system title is not shown.
- On iOS 26, the leading title must not render inside a Liquid Glass toolbar-item bubble (hide
  the shared item background there).
- Trailing toolbar buttons (Dashboard Refresh, Goals +, Friends +, etc.) stay where they are.
- **Not affected:** pushed screens (friend screen) and sheets keep the standard centered inline
  title.
- Done when: on device, all five tabs show the same compact gray header with a left-aligned
  larger title; the friend screen's back button still reads "Friends"; VoiceOver reads each
  tab's title as a header.

## 6. Edge cases
- **Sign-in on a device with someone else's queued writes:** those stay queued and untouched.
- **The server rejects the name** (e.g. a non-blank check): the write is dropped and logged. On
  the next online refresh the device copy takes the server's value, and since profile then isn't
  satisfied, the user is routed back to profile setup.
- **Old builds:** they ignore the new column. The backfill keeps existing users finished.
- **The monitor extension** doesn't read any of this.

---

## 7. Done when
- **SQL:** the migration is idempotent; the backfill is correct; `onboarding_status()` returns
  the documented JSON for: no names, one name, both names, and completed. Verified with the
  file's verify queries (the user runs them).
- **Unit tests:**
  - routing for every combination of (nextStep, completed, Screen Time status, notification
    status);
  - device-copy seeding (old flag true, online fetch, offline no copy);
  - merge rules;
  - outbox: enqueue, order, coalescing, flush stops on network/5xx/429, drops on permanent 4xx,
    single flight, per-user isolation, cleared on account deletion;
  - the permission banner's visibility and action choice for each status.
- **On device:**
  - an existing user isn't sent back into onboarding;
  - a new user's profile setup in airplane mode completes, and the name reaches Supabase after
    reconnecting;
  - a reinstall shows only permissions;
  - the banners appear when access is off, and their buttons work.
- **User actions:** run `009_onboarding_progress.sql`.
