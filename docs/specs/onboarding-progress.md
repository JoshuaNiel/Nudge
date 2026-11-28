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
| Screen Time not approved | "Screen Time access needed. Nudge can't track your usage or goals." | **Allow**: if `notDetermined`, request authorization; if denied, open the app's Settings page | Dashboard, Goals |
| Notifications not authorized (denied or not determined) | "Notifications are off. You won't be alerted when you hit a limit." | **Turn On**: if `notDetermined`, request authorization; if denied, open the app's notification settings | Dashboard, Goals, Friends |

- One reusable `PermissionBanner` view, plus a `PermissionStatusProvider` (protocol, injectable)
  with the current Screen Time and notification statuses, published and refreshed on foreground.
- Both banners can show at once (stacked).
- `provisional` / `ephemeral` notification statuses count as on.

---

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
