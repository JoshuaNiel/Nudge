# Auth Recovery — Password Reset + Email-Confirmation Deep Link

**Status:** `[x] Approved 2026-11-14 — implemented on feat/auth-deep-links, pending on-device verification`

## A. Password reset + email-confirmation deep link — `feat/auth-deep-links`
- **URL scheme:** register `nudge` (`CFBundleURLTypes`) in the main app's Info.plist. This is
  not an entitlement, so editing the plist is fine. Redirect URLs: `nudge://auth-callback`
  (sign-up confirmation) and `nudge://reset-password` (recovery).
- **Security:** a custom scheme can be claimed by another app, so the auth client must use
  the PKCE flow (`flowType: .pkce`). The intercepted link is then useless without the
  verifier stored on this device. The implementer verifies or sets this explicitly in
  `SupabaseClient.swift`.
- **Forgot password:** a "Forgot password?" link on `AuthView` in sign-in mode opens a sheet with an
  email field that calls `supabase.auth.resetPasswordForEmail(email, redirectTo: nudge://reset-password)`.
  It always shows "If an account exists for that email, we've sent a reset link." (no
  account enumeration), and errors other than rate limiting are swallowed into the same message.
  Rate-limit error → "Please wait a minute before trying again."
- **Link handling:** `.onOpenURL` in `NudgeApp` → `supabase.auth.session(from: url)`.
  - Recovery link → present a **Set new password** sheet (new + confirm, min 8 chars, must
    match) → `auth.update(user: .init(password:))` → success toast → normal app.
  - Confirmation link → session established → normal onboarding/app flow.
  - Expired/invalid link → alert "This link has expired. Request a new one."
- `signUp` passes `redirectTo: nudge://auth-callback`.
- **User actions (dashboard):** Authentication → URL Configuration: add `nudge://**` to
  Redirect URLs. Optionally re-enable email confirmation (ADR-004) once tested.
- **Tests:** URL routing (recovery vs callback vs unrelated URL), password validation rules,
  and the neutral reset message.

## C. 2026-11-23 changes (user decisions on #16) `[ ] Approved by the user 2026-11-23 — implementing`

### C1. 8-character minimum at sign-up (app + server)
- **App:** sign-up uses `PasswordRules.validationError(password:confirmation:)`, the same
  rule and messages as Set New Password ("Password must be at least 8 characters." /
  "Passwords do not match."). Length is checked first. Passwords are never trimmed. No hint
  under the field (removed at the user's request 2026-11-27; the validation message covers it). Sign-in is unchanged
  (no length check), because existing accounts may have shorter passwords.
- **Server:** the user sets Supabase Authentication → Providers → Email → *Minimum password
  length* = 8. If Supabase still rejects a password (`weak_password`, e.g. a stricter rule
  later), sign-up and Set New Password show the server's reasons when present, otherwise
  "Password must be at least 8 characters."

### C2. Specific messages for a failed link
The single "This link has expired" alert becomes one alert per reason. Title: "Link Problem".

| Reason | How it's detected | Message |
|---|---|---|
| Expired before opening | redirect URL has `error_code=otp_expired` (Supabase's `/verify` redirects with `error`/`error_code`/`error_description` in the query or fragment) | "This link has expired. Request a new one." |
| Opened on a different device (or after reinstalling) | the SDK has no stored PKCE code verifier on this device | **Reset link:** "This link was requested on a different device. Open it on the iPhone where you asked for it, or request a new one here." **Confirmation link:** "Your email is confirmed. Sign in with your email and password." (see note) |
| An older email's link (a newer request replaced it) | server rejects the code exchange with `bad_code_verifier` | "This link is from an older request. Use the newest email, or request a new one." |
| Already used | server `flow_state_not_found` | "This link has already been used. Request a new one if you still need it." |
| Expired after opening (flow state too old) | server `flow_state_expired` | "This link has expired. Request a new one." |
| Malformed (no `code` and no `error`) | router | "This link isn't valid. Request a new one." |
| No connection | `URLError` | "Couldn't check the link. Check your connection and try again." |
| Anything else | fallback | "This link has expired. Request a new one." |

- The exact SDK and GoTrue error codes are verified against the resolved supabase-swift
  version during implementation. A code that can't be confirmed maps to the fallback row.
- **Note on confirmation links:** GoTrue marks the email confirmed in `/verify` *before*
  redirecting with the PKCE code, so a confirmation link opened on another device has
  still confirmed the account. Only the automatic sign-in fails. **Assumption, to confirm
  on device.** If it's wrong, the row falls back to the reset-style "different device" text.
- Existing rules are unchanged: a stale link while Set New Password is open is still
  ignored; the forgot-password sheet still closes before the alert. Codes are never logged.

### C3. Turn on email confirmation now (ADR-004 reversal)
- **User:** Supabase Authentication → Providers → Email → enable **Confirm email**.
- **App:** already handles it (sign-up shows "Check <email> for a link…"; the link signs in
  and continues to profile setup). No code change beyond C1/C2, unless testing finds a gap.
- **Sign-in before confirming:** Supabase returns `email_not_confirmed`, and only after the
  password has been verified. The sign-in screen shows "Confirm your email first. Check your
  inbox for the link." with a **Resend email** button.
- **Resend = repeat the original sign-up (user decision 2026-11-27).** The button calls
  `auth.signUp(email:password:redirectTo: <confirmation redirect>)` with the email and
  password captured when sign-in was refused, **not** `auth.resend`. Reason: SDK 2.43.1's
  `resend` sends no PKCE challenge, so Supabase would email an implicit-flow link carrying
  `access_token`/`refresh_token` through the claimable `nudge://` scheme. `signUp` uses PKCE,
  so the resent link works like the original (same device, signs straight in).
  - The captured password is kept in memory only, cleared on success, on leaving the
    sign-in screen, or when the email field changes. It is never logged or persisted.
  - Success → "Email sent. Check your inbox for the new link." A rate limit → the existing
    wait message. Any other failure → generic "Couldn't send the email. Try again."
  - If `signUp` returns a session (email already confirmed in the meantime), treat it as a
    normal sign-in.
  - **Assumption to confirm on device:** GoTrue re-sends the confirmation email for a repeat
    sign-up of an unconfirmed address. If it doesn't, fall back to removing the button
    (option B).
  - Any link carrying `access_token` with no code still gets the "Your email is confirmed.
    Sign in…" message, and its tokens are ignored and never logged (defensive).
- Existing accounts are already confirmed and aren't affected.
- **Delivery limit (backlog, before launch):** Supabase's built-in email only sends to
  project team members, with a low hourly cap. Real users need custom SMTP.
- ADR-004 gets an amendment: email confirmation re-enabled 2026-11-23.

### Done when
- **Unit tests:**
  - sign-up password validation (7 rejected, 8 accepted, mismatch, order of messages, no trimming);
  - the `weak_password` mapping;
  - every C2 row: URL-error parsing from the query and the fragment, and the SDK/server error → reason mapping, for both link kinds;
  - the `email_not_confirmed` mapping and the Resend action (including the rate limit).
- **On device:**
  - sign-up with 7 characters is blocked in the app;
  - with email confirmation on, sign-up shows "Check your email", the link opens the app signed in at profile setup, and signing in before confirming shows the message and Resend works;
  - a reset link opened twice gives "already used", an older link gives "older request", and `simctl openurl` with `error_code=otp_expired` gives the expired message.

## B. Implementation notes (2026-11-14)

### Where things live
| Piece | File |
|---|---|
| URL classification (`AuthDeepLink`, pure) | `Core/AuthDeepLink.swift` |
| `isValidEmail`, `PasswordRules` (min 8, must match) | `Core/Validation.swift` |
| `AuthRecoveryServiceProtocol` + SDK calls, `AuthRateLimit` | `Services/AuthService.swift` |
| Sheet/alert state above `RootView` | `Features/Auth/AuthRecoveryCoordinator.swift` |
| Forgot-password sheet | `Features/Auth/ForgotPassword{View,ViewModel}.swift` |
| Set-new-password sheet | `Features/Auth/SetNewPassword{View,ViewModel}.swift` |
| `.onOpenURL`, `.sheet(item:)`, `.alert` | `NudgeApp.swift` |
| Tests | `NudgeTests/AuthDeepLinkTests.swift` |

### Routing rules
- Scheme `nudge` and host `reset-password` / `auth-callback`, compared case-insensitively
  (RFC 3986). Path must be empty or `/`. Query and fragment are ignored by the router.
  Anything else is ignored without calling Supabase.
- The router decides recovery vs confirmation **by host**. Under PKCE the SDK's
  `session(from:)` emits only `.signedIn` (never `.passwordRecovery`), so the auth event
  can't be used to detect recovery.

### Presentation
- Both sheets are presented from `NudgeApp` (above `RootView`) through a single
  `activeSheet` on `AuthRecoveryCoordinator`. Establishing a session flips `RootView`
  between onboarding and the main app; a sheet owned inside either branch would be torn
  down by that switch.
- A reset link that arrives while the forgot-password sheet is still open swaps it for the
  set-new-password sheet in one step (`sheet(item:)` replacement).
- Expired/invalid link: alert "This link has expired. Request a new one." If the
  forgot-password sheet is open, it is closed first and the alert is raised from the
  sheet's `onDismiss`, because SwiftUI can't show an alert while a sheet is presented.
  If the set-new-password sheet is already open (a valid recovery session exists), a stale
  second link is ignored so it doesn't interrupt that session.
- The set-new-password sheet blocks swipe-to-dismiss. "Not now" closes it. The recovery
  link has already signed the user in, so skipping keeps the old password. On success
  the sheet shows a "Password updated" confirmation with a Done button.

### Messages
| Case | Message |
|---|---|
| Reset request: success **or any server error** | "If an account exists for that email, we've sent a reset link." |
| Reset request: rate limit (`over_email_send_rate_limit`, `over_request_rate_limit`, or HTTP 429) | "Please wait a minute before trying again." |
| Reset request: transport failure (`URLError`) | "Couldn't reach Nudge. Check your connection and try again." |
| Invalid email format | "Please enter a valid email address." (no request sent) |
| New password < 8 chars / mismatch | "Password must be at least 8 characters." / "Passwords do not match." |

The transport-failure message departs from the original "swallow everything" rule. A
`URLError` means the request never reached Supabase, so it reveals nothing about whether
the account exists. Telling the user they're offline avoids a false "we've sent a link".

### Onboarding interaction
- `OnboardingCoordinator` advances from `.tour` or `.auth` to `.profileSetup` when
  `AppState.isAuthenticated` becomes true. A link-driven sign-in (confirmation or recovery)
  would otherwise leave a signed-in user looking at the sign-in form. Returning users with
  `onboardingComplete` go straight to the main app via `RootView` as before.
- `AuthService.signUp` returns whether email confirmation is pending (no session in the
  response). When it is, `AuthView` shows "Check <email> for a link to confirm your
  account…" instead of advancing to profile setup, which would fail without a session.
  This only matters once email confirmation is re-enabled (ADR-004).

### `AppState` fix
`.passwordRecovery` used to be handled as a sign-out. That event carries a valid session
(implicit flow emits it right after `.signedIn`), so it now updates `currentUser` like
`.tokenRefreshed`. PKCE never emits it, so this change is defensive.

### Known limitations
- **Same device only.** PKCE stores one code verifier on the device that requested the
  email. A link opened on another device, or after reinstalling the app, fails as
  "expired". The forgot-password copy tells the user to open the link on this iPhone.
- **Latest request wins.** Each `resetPasswordForEmail` or `signUp` call overwrites the stored
  verifier, so only the most recent email's link works.
- **Other in-app sheets.** If some unrelated sheet is open in the main app when a link
  arrives, the root-level sheet or alert can't be presented on top of it. This is unlikely,
  because both flows start from the signed-out sign-in screen.
- Sign-up still uses the old rules (non-empty, match), not the 8-character minimum.
  Setting Supabase's server-side minimum password length to 8 makes the two consistent.

### Dashboard steps (user)
1. Authentication → URL Configuration → Redirect URLs: add `nudge://**`.
2. (Recommended) Authentication → Providers → Email → minimum password length 8.
3. (Optional, after testing) re-enable "Confirm email" (ADR-004).

