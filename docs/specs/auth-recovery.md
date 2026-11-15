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

