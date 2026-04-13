# Nudge — TODO List

## Auth

- [ ] **Email confirmation deep link** — Supabase currently sends a `localhost` confirmation URL. Fix requires:
  1. Register `nudge://` custom URL scheme in Xcode (Target → Info → URL Types)
  2. Set **Site URL** to `nudge://` and add `nudge://auth/callback` to **Redirect URLs** in Supabase dashboard (Authentication → URL Configuration)
  3. Handle the callback in `NudgeApp.swift`:
     ```swift
     .onOpenURL { url in
         Task { try? await supabase.auth.session(from: url) }
     }
     ```
  4. Re-enable email confirmation in Supabase dashboard (Authentication → Email)
  > Currently: email confirmation is **disabled** in Supabase for development.

## Models

- [ ] **Update `AppUsage.swift` and `Goal.swift`** — these were written before the schema was finalized. Column names need to match the DB schema (snake_case, handled by Supabase Swift SDK).

## Screen Time

- [ ] **PermissionsView** — Family Controls / DeviceActivity permission request is a stub. Real implementation comes in Phase 1 DeviceActivity work.

## Future Phases

- [ ] Usage sync pipeline (DeviceActivity → Supabase `usage` table)
- [ ] Dashboard charts (Swift Charts)
- [ ] Goal creation and tracking
- [ ] Notifications and interventions
- [ ] App blocking (requires Apple Screen Time entitlement)
- [ ] Social layer (friends, nudges, SMS via Twilio)
- [ ] Mac sync
