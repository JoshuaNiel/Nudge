# Account Deletion

**Status:** `[x] Approved 2026-11-14` · `[x] Implemented 2026-11-14 (feat/account-deletion, awaiting deploy + on-device test)`

## B. Account deletion — `feat/account-deletion`
- **Edge Function `delete-account`** (POST, user JWT). Deployed with `--no-verify-jwt` for
  the same ES256 gateway reason as ADR-050, and authenticated in-function with
  `auth.getUser(jwt)` → 401. A service-role client runs `auth.admin.deleteUser(user.id)`.
  All user tables cascade from `auth.users` (the implementer verifies every FK, including `nudge`
  through `friend`, `device_tokens`, and `nudge_settings`). It returns 204, or 500 with a
  generic message (details only in logs). It accepts no parameters (the user can only delete
  themselves).
- **iOS:** Settings → bottom section → "Delete Account" (destructive) → confirmation alert
  explaining the account, friends, goals and history are permanently removed and friends
  receive no further texts → `AccountService.deleteAccount()` → on success:
  `DeviceActivityCenter().stopMonitoring()`, clear all App Group keys, clear local caches,
  reset `onboardingComplete`, sign out locally → auth screen. On failure → error alert, nothing
  changes locally. A spinner shows while the request is in flight, and the button is disabled.
- **Not in scope (backlog):** revoking Sign in with Apple tokens (Apple asks for this when
  SIWA is used; SIWA isn't configured on the backend yet), and an optional SMS telling friends.
- **User actions:** deploy `supabase functions deploy delete-account --no-verify-jwt`.
- **Tests:** the post-deletion local cleanup (App Group keys cleared and the monitoring stop
  is called, via an injected protocol) and the ViewModel state machine (idle → deleting →
  done/error).

## Checklist
- [x] Cascade audit of every FK (below) — no explicit deletes needed in the function
- [x] `supabase/functions/delete-account/` — `handler.ts` (pure, injectable), `index.ts` (wiring), `handler.test.ts` (Deno tests; not run locally — no `deno` installed)
- [x] `AccountService` (+ protocol, `AccountServiceError`)
- [x] `AccountCleanupService` (+ `AccountCleanupProtocol`, `MonitoringStopping`, `LocalSessionEnding`)
- [x] `AccountDeletionViewModel` state machine
- [x] Settings bottom section, confirmation + error alerts, spinner/disabled state
- [x] iOS tests (`NudgeTests/AccountDeletionTests.swift`)
- [ ] User: deploy the function
- [ ] User: on-device test with a throwaway account

## Cascade audit (verified 2026-11-14 against `schema.sql` + migrations 001–005)

| Table | FK path to `auth.users` | On delete | Result |
|---|---|---|---|
| `profile` | `user_id → auth.users(id)` | cascade | deleted |
| `app_category` | `user_id → auth.users(id)` | cascade | deleted |
| `app_category_member` | `category_id → app_category(id)` | cascade | deleted (via category) |
| `usage` | `user_id → auth.users(id)` | cascade | deleted |
| `goal` | `user_id → auth.users(id)` (also `category_id → app_category` cascade) | cascade | deleted |
| `why_reminder` | `user_id → auth.users(id)` | cascade | deleted |
| `friend` | `user_id → auth.users(id)` | cascade | deleted |
| `nudge` | `friend_id → friend(id)` | cascade | deleted (via friend) |
| `device_tokens` | `user_id → auth.users(id)` (migration 001) | cascade | deleted |
| `app` | — (global registry, no user FK) | — | kept (not user data) |
| `nudge_settings` | — | — | **does not exist** in schema or migrations (spec mention was speculative) |

Non-blocking FKs checked: `usage.app_id → app ... on delete restrict` and `app_category_member.bundle_id → app` / `goal.bundle_id → app` constrain deletes of **`app`** rows only; deleting a user never deletes `app` rows, so they cannot block. No Storage buckets are used. `auth.*` children (identities, sessions, refresh tokens, MFA) are removed by GoTrue on hard delete (`shouldSoftDelete = false`).

Side effects: `profile.phone_number` (unique) is freed for reuse. A friend who later replies to an old nudge hits `receive-reply`, finds no `friend` row, and gets an empty TwiML response (no error, no SMS).

## Decisions
- **Handler split** — `handler.ts` holds all request logic with injected `getUserId` / `deleteUser`, so it is unit-testable without Supabase; `index.ts` only reads env and wires clients.
- **No body/query read at all** — the only identity input is the JWT; nothing in the request can name another user.
- **No OPTIONS/CORS** — matches the other functions; the only caller is the native app. OPTIONS gets 405.
- **iOS sends the token explicitly** — `AccountService` reads `supabase.auth.session` (auto-refreshes) and sets `Authorization: Bearer <access token>` instead of relying on the functions client's implicit header (which falls back to the anon key if no session was propagated yet).
- **App Group wipe = `removePersistentDomain(forName:)`** plus a per-key fallback over `persistentDomain(forName:)`. Removing the whole domain cannot miss keys added later or dynamic ones (`nudge.selection.app.<bundleId>`); the fallback covers iOS versions where domain removal on App Group suites was unreliable.
- **`stopMonitoring()` with no names** — stops every activity the app owns (today only `MonitoringPlan.activityName`), so a future second activity can't survive deletion.
- **APNs token kept** — `apnsDeviceToken` in standard defaults is device-scoped; the next account needs it to upload. Its `device_tokens` row cascaded. `PushTokenManager`'s in-memory upload state is reset by the existing `.signedOut` handler in `AppState`. No `unregisterDevice` call (row already gone).
- **Local sign-out** — `supabase.auth.signOut(scope: .local)`: the SDK removes the stored session and emits `.signedOut` before calling `/logout`, and ignores 401/403/404, so `AppState` flips to unauthenticated even when the network call fails.
- **Cleanup order** — stop monitoring → wipe App Group → reset `onboardingComplete` → end session (last, so the auth screen appears only after local state is gone).
- **State machine** — `idle → confirming → deleting → done | failed(message)`; `confirmDeletion()` enters `.deleting` synchronously (button disabled before the alert finishes dismissing; double taps ignored). Failure message is generic; details only in `os.Logger`.
- **Alert bindings** have no-op setters; each alert button drives the ViewModel explicitly, so SwiftUI's dismissal write can't race the "Delete" action.

## Known limitations / backlog candidates
- If the server deletes the user but the response is lost (network drop), the app shows the error and keeps local state; the next token refresh fails and `AppState` signs out. A retry would return 401. Acceptable for now.
- No re-authentication before deletion (an unlocked, signed-in device can delete the account). Consider a recent-sign-in check or password re-entry.
- SIWA token revocation and friend-notification SMS remain out of scope (see above).
