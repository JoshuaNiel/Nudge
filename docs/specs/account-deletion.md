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

## C. Password confirmation before deletion (approved by the user 2026-11-23)

Deleting requires re-entering the account password. It is checked in **two layers**: the
app re-authenticates, and the server independently requires a recent password sign-in.

**What the user sees**
- Settings → "Delete Account" opens a **sheet** instead of the alert. The sheet has:
  - the existing explanation (account, friends, goals and history are permanently removed;
    friends get no further texts);
  - a `SecureField` "Password" (`textContentType(.password)`);
  - a destructive **Delete Account** button, disabled while the field is empty (after
    trimming nothing; whitespace is allowed in passwords) or while a request is in flight;
  - **Cancel**.
- While in flight: a spinner, the field and buttons disabled, and swipe-to-dismiss disabled
  (`interactiveDismissDisabled`).
- Errors are shown inline in the sheet (red text under the field), the typed password is
  **cleared**, and the user can retry. Nothing is deleted on any error.

| Situation | Message |
|---|---|
| Wrong password (`invalid_credentials`) | "Incorrect password." |
| Auth rate limit (HTTP 429 / `over_request_rate_limit`) | "Too many attempts. Try again in a few minutes." |
| Server says re-auth too old (403 `reauth_required`) | "Please enter your password again." |
| Network / anything else | "Couldn't delete your account. Check your connection and try again." |

- On success the sheet dismisses and the existing post-deletion cleanup runs unchanged
  (stop monitoring → wipe App Group → reset onboarding → end local session).
- A user who forgot their password can't delete until they reset it (#16 adds reset).

**Layer 1: app re-authentication**
- `AccountService.deleteAccount(password:)` first calls
  `supabase.auth.signIn(email: <current session user's email>, password:)`. This replaces the
  session with a fresh one whose token records a password sign-in now.
- Only if that succeeds does it call `delete-account` with the **new** access token.
- No current user / no email on the session → generic error, no request sent.

**Layer 2: server recent-sign-in check**
- After `getUser(jwt)` succeeds, `delete-account` decodes the (already validated) JWT payload
  and reads its `amr` claim: an array of `{ method, timestamp }` (timestamp in Unix seconds).
- It requires an entry with `method === "password"` whose `timestamp` is within
  **300 seconds** of now (allow 60 s of clock skew into the future).
- Otherwise it returns **403** `{ "error": "reauth_required" }`, logs the reason (missing
  `amr`, no password entry, or too old), and deletes nothing.
- The handler gets the current time and the claim reader by injection, so it stays
  unit-testable. Still no body or query parameters are read.

**Edge cases**
- Sign in with Apple accounts have no password. SIWA isn't configured on the backend, so
  today every account is email/password. When SIWA ships, deletion for those accounts needs
  Apple re-authentication instead (backlog).
- **Assumption to confirm on device:** Supabase access tokens carry `amr` with the original
  authentication time, and keep it across refreshes. If not, layer 2 fails safe (403, nothing
  deleted) and the device test catches it.

**Done when**
- iOS unit tests: the view model's states and messages for each row of the table; the
  password is cleared after an error; re-auth runs before the delete call and the delete
  call is skipped when re-auth fails; the delete call uses the token from re-auth.
- Deno tests (`handler.test.ts`): a recent password `amr` → 204; an old one → 403
  `reauth_required`; missing `amr` → 403; only non-password methods → 403; a future
  timestamp within skew → OK; existing 401/405/500 cases unchanged. (They can't be run here
  without Deno; see Checklist.)
- On device: a wrong password gives "Incorrect password." and deletes nothing; the right
  password deletes the account and all its rows.

## D. "Account Deleted" confirmation page (approved by the user 2026-11-23)

**After a successful deletion** the post-deletion cleanup runs unchanged (stop monitoring → wipe
App Group → reset `onboardingComplete` → end local session). Instead of RootView falling
through to the onboarding tour, a **full-screen "Account Deleted" page** is shown:
- an SF Symbol checkmark (e.g. `checkmark.circle.fill`), large, accent-coloured;
- title **"Your account has been deleted"**;
- body: *"Your account, friends, goals and history have been permanently removed. Your
  friends won't receive any more messages from you."*;
- one primary button **"Back to Sign In"** (project button style, see `docs/conventions.md`).

**"Back to Sign In"** clears the page and shows `OnboardingCoordinator` starting at the
**`.auth` step** (the feature tour is skipped). From there the normal flow continues
(sign up → profile setup → permissions; sign in → existing account).

**No other exit:** it isn't a dismissible sheet, so there is no swipe-down or back navigation.

**Not persisted:** the "just deleted" flag is **in memory only** (e.g. a published property on
`AppState`, set by the deletion flow once the server confirms, before local cleanup — see Ordering). If the app is killed on that page, the
next launch shows the normal start (the tour). No information about the deleted account is
stored on the device.

**Ordering:** the flag must be set so RootView shows the page instead of a flash of the tour
when `.signedOut` flips `isAuthenticated` to false. Set it **before** the session is ended,
or make RootView check it first.

**Failure:** the page only appears after the server confirms deletion. Errors stay inline in the
password sheet (section C), and the flag is never set.

**Done when**
- Unit tests: a successful deletion sets the flag; a failed deletion (each error kind) never
  sets it; "Back to Sign In" clears it and the coordinator starts at `.auth`; the default
  coordinator start (no flag) is still `.tour`.
- On the Simulator: delete the test account → Account Deleted page (no tour flash) → Back to
  Sign In → sign-in screen.

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
- ~~No re-authentication before deletion.~~ Done in section C (password + server recent-sign-in check).
- SIWA token revocation and friend-notification SMS remain out of scope (see above).
