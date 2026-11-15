# Device Testing Walkthrough: PRs #13–#24

Written 2026-11-14, while PRs #13–#25 were all open and none were merged. This is the script for testing every PR on a physical iPhone; Claude can walk you through it. Every branch already passes its unit tests. These checks cover what the simulator can't: Screen Time data, pushes, SMS and real timing.

Tick each item as you go, and note any failure with its PR number so it can be fixed on that branch.

---

## 0. One-time setup (do this first)

Every migration is safe to run before any build. Older builds don't read the new columns, and the deprecated ones are kept.

**Supabase SQL editor, in this order** (each file has a preview or verify query at the top or bottom):
- [ ] `006_goal_selection.sql`: deletes legacy app goals that have no selection. Preview them first.
- [ ] `006b_realtime_nudge.sql`: verify with `select * from pg_publication_tables where pubname='supabase_realtime' and tablename='nudge';`, which should return 1 row.
- [ ] `007_why_reminder_goal.sql`: deletes the existing (unused) `why_reminder` rows the first time it runs.
- [ ] `008_nudge_settings.sql`: backfills session timeouts. Preview: `select user_id, session_timeout_minutes from profile where session_timeout_minutes is not null;`

**Supabase config:**
- [ ] `supabase secrets set APNS_SANDBOX=true`. Xcode builds get sandbox push tokens. Unset it before TestFlight.
- [ ] Authentication → URL Configuration → Redirect URLs: add `nudge://**`.
- [ ] Authentication → Providers → Email → minimum password length **8**.
- [ ] `supabase functions deploy delete-account --no-verify-jwt`

**Xcode, push builds only (C and D below):**
- [ ] On the `feat/apns-registration` branch: Nudge target → Signing & Capabilities → **+ Push Notifications**. Commit that change to #14 so the branches stacked on it (#19, #20) pick it up when rebased. Until then, add it on each of those branches by hand.

**Useful tools:**
- **Console.app:** select the iPhone, then filter on subsystem `com.joshuaqn.Nudge`. Useful categories: `MonitoringPlan`, `MonitoringService`, `NudgeMonitor`, `DailyReport`, `AppDelegate`.
- **Accounts:** a test friend phone that has accepted the consent SMS, and a **throwaway account** for the deletion test.

---

## Which build tests what

Nothing is merged yet, so build the **top of each stack**; it contains everything beneath it.

| Build | Check out | Contains | Section |
|---|---|---|---|
| A | `feat/why-reminders` | #13, #15, #18, #22, #23 | 1–4 |
| B | `feat/daily-report` | #13, #15, #18, #21, #24 | 5–6 |
| C | `feat/realtime-nudge-status` | #13, #14, #20 | 7–8 |
| D | `feat/account-deletion` | #13, #14, #19 | 9 |
| E | `feat/auth-deep-links` | #13, #16 | 10 |
| F | `feat/app-icon` | #17 | 11 |

Each worktree lives in `.worktrees/<name>/` and already has `Config.xcconfig`. Open `Nudge/Nudge.xcodeproj` from there, or check the branch out in the main repo. If test data seems stale after switching builds, delete the app first.

---

## 1. #13 Daily re-arm (any build, overnight)
- [ ] Have a goal or session timeout that will fire. Leave Nudge **closed** overnight. The next day, exceed the limit: the notification fires without opening the app.
- [ ] Console at midnight: `intervalDidStart — … re-arming`, then `registered monitoring`.

## 2. #15 Dashboard (Build A or B)
- [ ] The Dashboard shows a spinner, then the total · pickups, and apps sorted by time with **real icons and names**.
- [ ] Totals roughly match iOS Settings → Screen Time for today.
- [ ] `<` goes to "Yesterday", then dates. `>` is disabled on Today. `<` is disabled after 30 steps. A day before install shows "No usage recorded for this day".
- [ ] Use another app, come back (or tap refresh), and check the numbers update.
- [ ] Revoke Screen Time access in Settings: "Screen Time access required" appears and Open Settings works. Re-grant it: the report returns.
- [ ] Across midnight: reopen the app, the title says "Yesterday" and nothing crashes.

## 3. #18 + #22 Goals and Categories (Build A)
- [ ] **Categories tab:** tap +, then name, color and picker, then Create. The row shows the dot and "N apps, M categories". A duplicate name shows "You already have a category with this name." Edit a category's apps and save.
- [ ] **App goal:**
  - Picking 2 apps, or an app plus a category, shows a validation message and Save stays disabled.
  - With exactly 1 app and a name, save.
  - The row shows the app icon and name plus your label, "Xh / day", an empty bar and "Under 10%".
- [ ] **Category goal:** use "New category…" inline; it's auto-selected after you create it.
- [ ] **Total goal:** create one, then a second permanent Total, which shows "You already have a daily goal for this."
- [ ] **Temporary goal:** a past start date is blocked. Start today, end next week, and save.
- [ ] **Progress:** set a goal with a ~10 min limit. Use the app past 1 min, return, and check the bar says "≈ 10% used". At the limit: **one** "You've hit your <label> limit" notification.
- [ ] **Detail:** tap the row to see "Xm used today" (exact, from the report). A Total goal ≈ the Dashboard total.
- [ ] **Delete** from detail (with confirmation) and by swipe. Console shows `refreshMonitoring` about 1.5 s later.
- [ ] **Category delete:** deleting a category that has a goal warns about its goals, and that goal disappears from the Goals tab.
- [ ] **Screen Time revoked:** Goals and Categories show the access-required state.
- [ ] **No duplicate notifications:** edit a goal mid-day after it passed 50%. Monitoring re-registers, and no repeat notifications appear for milestones already passed.

## 4. #23 Why-reminders (Build A)
- [ ] Goal detail → Why: add one at **10%** and one at **100%**. The editor counter (/500) and the percent picker work. Edit one, and swipe-delete one.
- [ ] Editing a why does **not** re-register monitoring (no `refreshMonitoring` in Console).
- [ ] At 10%: "You're at 10% of your <label> limit" with your why as the body.
- [ ] At 100%: **one** notification, "You've hit your <label> limit", with the 100% why as its body. The friend nudge is still queued if goal-breach is on (Build B only).
- [ ] Two whys at the same percent rotate on different days.
- [ ] Settings → Notifications shows Allowed. Turn notifications off in iOS Settings: it shows Off with "Open Settings", which opens Nudge's notification page. On a fresh install where you skip the prompt it shows "Not asked" with Turn On, which brings up the system prompt.
- [ ] Airplane mode and foreground: existing whys still fire.

## 5. #21 Trigger settings (Build B)
- [ ] Settings → Nudges defaults with no row: Too much screen time on at 1h, Goal limit off, Daily report off. With no accepted friends you see "Add a friend to start sending nudges."
- [ ] Turn on Goal limit reached and Save. A row appears in `nudge_settings`, and `updated_at` changes on later saves.
- [ ] Goal breach **on**: reaching a limit gives the local notification **and** an SMS to friends. **Off**: only the notification.
- [ ] Session timeout at 15m and Save: Console shows a re-registration ~1.5 s later, and after 15 min of use you get the session nudge. Turn it off and Save: it re-registers without the event.
- [ ] Changing only your name and saving causes **no** monitoring re-registration.
- [ ] Airplane mode and Save a change: you get an error, the edit is kept, and Save stays enabled.
- [ ] Sign out, then back in: the settings are still there (they're stored on the server).

## 6. #24 Daily report (Build B)
- [ ] Turn on Daily report, pick a time, Save. Console shows `registered monitoring … daily report: true` with ~48 extra events. Saving again with only the time changed: no re-registration.
- [ ] Use the phone 15+ min. Console: `total usage reached 15 min today`.
- [ ] **Shortcut so you don't have to wait a day:** set `nudge.dailyTotal.<yesterday yyyy-MM-dd>` = 60 in the App Group, either with a temporary debug button or via Claude. Then set the report time 1–2 min ahead, clear `nudge.monitoring.lastDay`, and foreground. Console: `queued daily report for <yesterday>`. Foreground again after the time: **one SMS per friend**, "<Name>'s screen time yesterday: about 1h." followed by the reply options. Foreground again: no second SMS.
- [ ] **Real overnight:** with the report on, the next morning after the chosen time you get one SMS with a sensible total.
- [ ] Turn the report off while one is queued but not yet due: nothing is sent.

## 7. #14 Push notifications (Build C)
- [ ] Sign in and allow notifications. `select * from device_tokens` shows your row (64-character hex token).
- [ ] Friend replies to a nudge while the app is in the **foreground**: a banner appears.
- [ ] App in the **background**: tap the push, and the app switches to Friends and opens that friend's history.
- [ ] **Force-quit**, then tap a new reply push: you land in the same place.
- [ ] A push for a deleted friend lands on Friends with no error.
- [ ] Settings → Sign Out: the token row is gone and replies no longer push. Sign in again: the row is back.
- [ ] No token row? Check Console `AppDelegate` for "APNs registration failed" (usually the missing capability).

## 8. #20 Live nudge history (Build C)
- [ ] Open a friend's history and trigger a nudge: an "Awaiting reply" row appears at the top without refreshing.
- [ ] Friend replies "1": the row updates live, from "Friend replied" to "Reply delivered".
- [ ] Tap a reply push while already on that friend's history: it shows the reply.
- [ ] Pull to refresh works on the list, the empty state and the error state.
- [ ] Navigate in and out ~10 times: Supabase → Realtime → Inspector shows one channel at a time.
- [ ] Airplane mode, friend replies, airplane mode off: the reply appears after reconnecting.

## 9. #19 Account deletion (Build D, **throwaway account**)
- [ ] Sign up, add a friend, a goal and a why, and allow notifications.
- [ ] Settings → Delete Account → Cancel: nothing changes.
- [ ] Airplane mode → Delete: spinner, then "Couldn't Delete Account". You're still signed in with all data present.
- [ ] Online → Delete: you land on onboarding/auth.
- [ ] Supabase: the auth user is gone, and `profile`/`friend`/`nudge`/`goal`/`why_reminder`/`device_tokens` have no rows for that id. Function logs show `[delete-account] deleted user <id>`.
- [ ] Sign up again: onboarding starts from the beginning.

## 10. #16 Password reset and email links (Build E)
- [ ] Sign out → sign-in screen → type your email → "Forgot password?". The sheet opens with the email filled in → Send shows the neutral message.
- [ ] Open the email on the **same iPhone** and tap the link: the Set New Password sheet appears. Fewer than 8 characters gives an error, mismatched passwords give an error, a valid pair gives "Password updated" → Done. Sign out and back in with the new password.
- [ ] An email with no account gets the same neutral message.
- [ ] Tap Send repeatedly: "Please wait a minute before trying again."
- [ ] An old or used link shows "This link has expired. Request a new one."
- [ ] Simulator: `xcrun simctl openurl booted "nudge://reset-password?code=bogus"` shows the expired alert.
- [ ] Optional: turn on "Confirm email" in Supabase, sign up with a new email, see "Check <email>…", tap the link, and land on profile setup.

## 11. #17 App icon (Build F)
- [ ] The Home Screen shows the teal "n" with the yellow ball.
- [ ] Long-press the Home Screen → Edit → Customize → Dark and Tinted: both versions look right.

---

## After testing
- Record any failures (with PR numbers) and fix them on the branch, before merging.
- Merge in the order in `docs/STATUS.md`. Expect conflicts between sibling branches in `SettingsView`, `NudgeApp`, `AppState`, `ContentView` and `MonitorExtension`.
- After everything is merged: answer the weekly-goals questions (`docs/specs/weekly-goals.md`), then do the database cleanup listed in `docs/backlog.md`.
