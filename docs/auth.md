# Auth Flow

Authentication strategy using Supabase Auth.

---

## Mechanism

Supabase Auth handles all credential management. We do not store passwords or manage sessions manually.

### Auth Methods

Two methods are offered:

1. **Email + password** — primary cross-platform method. Works on iOS, web, and any future Android/Mac clients.
2. **Sign in with Apple** — required for App Store compliance when any third-party auth is offered. Provides a native iOS experience.

**Account linking is enabled** in Supabase Auth settings ("Link accounts by email"). This allows a user who signed up with Apple to later sign in with email/password on another platform using the same account, as long as the emails match.

### Apple Private Relay Emails

Apple lets users hide their real email behind a relay address (e.g. `abc123@privaterelay.appleid.com`). If a user does this, their Supabase account will have the relay address — which cannot be used to log in on a non-Apple platform.

**Mitigation:** During Apple sign-in onboarding, if Apple provides a private relay email, prompt the user to also set a real email + password. This gives them a cross-platform fallback. This step is optional but strongly encouraged.

---

## Session Management

The Supabase Swift client handles session persistence automatically via the keychain. No manual token management is needed.

### Session lifecycle:
- **First launch with no session** → show feature tour → sign up / sign in
- **Session expires mid-use** → Supabase client auto-refreshes the token. If refresh fails (e.g. revoked), `AppState` detects the signed-out state and redirects to auth.
- **Sessions are always persisted** — no "remember me" toggle. Users stay signed in until they explicitly sign out.

---

## Email Links (Password Reset + Sign-up Confirmation)

Full spec: `docs/specs/auth-recovery.md`.

- The client uses the **PKCE flow** (`flowType: .pkce`, pinned in `SupabaseClient.swift`). Email links redirect to the custom scheme `nudge://`, which another app could also register. Under PKCE the redirect only carries a one-time `code`. Turning that code into a session needs the code verifier this device stored when it requested the email, so an intercepted link is useless.
- Redirect URLs: `nudge://reset-password` (`resetPasswordForEmail`) and `nudge://auth-callback` (`signUp`). The scheme is registered in `Nudge/Info.plist` (`CFBundleURLTypes`). The Supabase dashboard must allow `nudge://**` under Authentication → URL Configuration → Redirect URLs.
- `NudgeApp.onOpenURL` → `AuthRecoveryCoordinator.handleOpenURL` → `AuthDeepLink` classifies the URL by host → `AuthService.establishSession(from:)` (`supabase.auth.session(from:)`). A recovery link then presents the Set New Password sheet above `RootView`. A failure shows "This link has expired. Request a new one."
- Forgot-password never reveals whether an account exists. Every server response shows the same neutral message. The only exceptions are a rate limit and an offline/transport failure.
- Links must be opened on the device that requested them, and only the most recent email's link works (single stored verifier).

---

## Onboarding Flow

Sign-up leads into a linear onboarding sequence before reaching the main app:

1. **Feature tour** — 2–3 swipeable screens showing what Nudge does. Shown before any account commitment to reduce drop-off.
2. **Create account** — email + password, or Sign in with Apple.
3. **Profile setup** — collect first name and last name. Required to proceed. These patch the auto-created `profiles` row (see Profile Creation below).
4. **Screen Time permission** — explain why it's core to the app. Skippable with a clear warning that the core tracking feature will be unavailable.
5. **Notification permission** — explain use cases (threshold alerts, reminders, nudges). Skippable.
6. **You're all set** → main tab view.

Users who skip Screen Time or notification permissions can grant them later via Settings.

---

## Profile Creation

When a user signs up, Supabase automatically creates a `profiles` row via a database trigger. The app then immediately patches the row with the user's name collected during onboarding (step 3 above).

Fields set at signup (via trigger):
- `user_id` — from `auth.users.id`

Fields set during onboarding (step 3):
- `firstName`, `lastName`

Fields set later in Settings (nullable, patchable at any time):
- `timeZone` — default: auto-detected from device at onboarding completion
- `weekStart` — default: 0 (Sunday)
- `settingsLocationLat`, `settingsLocationLon` — only set if user enables location lock

### Profile Creation Trigger

```sql
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (user_id)
  values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();
```

---

## Row Level Security (RLS)

All tables must have RLS enabled. Users can only read and write their own rows.

General pattern:
```sql
alter table <table> enable row level security;

create policy "Users can manage their own rows"
  on <table> for all
  using (auth.uid() = user_id);
```

### Special cases:

- **`friend`** — users only see their own contacts (`user_id = auth.uid()`). Standard pattern applies.
- **`nudge`** — no direct `user_id` column. RLS must join through `friend`:
  ```sql
  using (
    exists (
      select 1 from friend
      where friend.id = nudge.friend_id
      and friend.user_id = auth.uid()
    )
  )
  ```
- **`app`** — readable by all authenticated users (global registry); writable only by the system (no user-facing inserts):
  ```sql
  create policy "Authenticated users can read apps"
    on app for select
    using (auth.role() = 'authenticated');
  ```
- **`app_category` and `app_category_members`** — users only see their own categories.

---

## Account Deletion

Settings → **Delete Account** (bottom section) → confirmation alert → the app calls the
`delete-account` Edge Function with the user's JWT (POST, no body). The function validates the
caller with `auth.getUser(jwt)` and hard-deletes only that user via `auth.admin.deleteUser`;
every user-owned table cascades from `auth.users` (audit in `docs/specs/account-deletion.md`).

Only after a 2xx does the app clean up locally (`AccountCleanupService`): stop all
DeviceActivity monitoring → wipe the App Group suite → reset `onboardingComplete` →
`signOut(scope: .local)`, which emits `.signedOut` and returns the user to onboarding. On
failure nothing local changes. Full details: `docs/specs/account-deletion.md`.

Still open: revoking the Sign in with Apple token on deletion (SIWA isn't configured on the
backend yet — tracked in the spec's backlog notes).

---

## Open Questions

> TODO: Answer before submission:
> - Sign in with Apple token revocation on account deletion (deletion itself is implemented — see above)
> - Privacy nutrition label — document all data collected and how it is used
