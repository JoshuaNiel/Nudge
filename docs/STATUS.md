# Nudge — Project Status

> **Read this first every session.** Update it at the end of each session.
> Last updated: 2026-11-14

---

## Where things stand

Every phase in the original plan has been implemented in code. Phase 3 (goals) is daily-only; weekly goals have a draft spec waiting for the user. **Nothing from the 2026-11-14 session is merged yet.** The work sits in a stack of 12 PRs. Each one passed its full unit-test suite in an independent run before it was opened. Most features still need checking on a physical device, because the simulator has no Screen Time data.

| Phase | Name | Status |
|---|---|---|
| 0 | Auth & Onboarding | `[x] Done` (+ password reset & email-link deep links: #16) |
| 1 | DeviceActivity + nudge trigger | `[x] Done`. Daily re-arm (#13) still needs its overnight device check. |
| 2 | Dashboard | `[x] In PR #15`. Device check pending. |
| 3 | Goals | `[x] Daily goals in PR #18 (core) + #22 (UI)`. Weekly: spec drafted (`docs/specs/weekly-goals.md`, in this PR), needs user confirmation. Monthly: not feasible (ADR-060). |
| 4 | Why-reminders & notifications | `[x] In PR #23` |
| 5 | Social | `[x] Done`. APNs (#14), realtime (#20), trigger settings (#21), daily report (#24). |
| — | Account deletion | `[x] In PR #19` |
| — | App icon | `[x] In PR #17` |

---

## PR stack (merge in this order, top to bottom)

GitHub retargets a stacked PR to `main` automatically once the PR it's based on is merged.

| PR | Branch | Base | Contents |
|---|---|---|---|
| #13 | `fix/daily-rearm` | main | Phase 1 daily re-arm (ADR-054/055/056) |
| #17 | `feat/app-icon` | main | App icon (independent) |
| #14 | `feat/apns-registration` | #13 | APNs token + reply-push deep link |
| #19 | `feat/account-deletion` | #14 | delete-account function + Settings flow |
| #20 | `feat/realtime-nudge-status` | #14 | Live nudge history |
| #16 | `feat/auth-deep-links` | #13 | Forgot password, email-confirmation link |
| #15 | `feat/phase-2-dashboard` | #13 | Dashboard |
| #18 | `feat/goals-core` | #15 | Goals core: tokens, milestones, progress |
| #22 | `feat/goals-ui` | #18 | Goals UI, Categories tab, exact usage |
| #23 | `feat/why-reminders` | #22 | Why-reminders on milestones |
| #21 | `feat/nudge-trigger-settings` | #18 | `nudge_settings` + Settings Nudges section |
| #24 | `feat/daily-report` | #21 | Daily report (total-only) |
| #25 | `docs/session-wrap-2026-11-14` | #13 | STATUS, ADR-057–069, backlog, ProgressLog, architecture, weekly-goals spec |

**Expected merge conflicts.** Sibling branches touch some of the same files: `SettingsView`, `NudgeApp`, `AppState`, `ContentView` and `MonitorExtension`, mostly in different places. Merge in the order above and resolve conflicts as each PR lands; Claude can rebase any PR on request.

---

## Manual steps for the user (checklist)

**Database (Supabase SQL editor), in this order:**
- [ ] `006_goal_selection.sql` (#18). Run its preview query first: it deletes legacy app goals that have no selection.
- [ ] `006b_realtime_nudge.sql` (#20). Independent of 006.
- [ ] `007_why_reminder_goal.sql` (#23). Deletes existing `why_reminder` rows; only runs that delete on its first run.
- [ ] `008_nudge_settings.sql` (#21). **Run it before installing a build that includes #21**; until then the settings fetch fails, so monitoring won't re-register on foreground.

**Supabase config:**
- [ ] `supabase secrets set APNS_SANDBOX=true` while testing Xcode builds (#14). Unset it for TestFlight/App Store.
- [ ] Authentication → URL Configuration → Redirect URLs: add `nudge://**` (#16).
- [ ] Authentication → Providers → Email → minimum password length 8 (recommended, #16).
- [ ] `supabase functions deploy delete-account --no-verify-jwt` (#19).

**Xcode:**
- [ ] Nudge target → Signing & Capabilities → **+ Push Notifications** (#14).

---

## On-device verification still needed

**Follow `docs/testing-walkthrough.md`.** It gives the one-time setup, which branch to build to test which PRs (nothing is merged, so test the top of each stack), and step-by-step checks with expected results for every PR. The key checks:

1. **#13:** leave the app closed overnight; a limit should still fire the next day.
2. **#15, #22:** real app names and icons (`Label(token)`); totals match Settings → Screen Time; the goal-detail exact usage covers only that goal's apps.
3. **#18, #23:** milestones fire for app tokens; p100 gives one notification plus a nudge (when goal-breach is on); whys show at their percent and rotate; no duplicates after a mid-day edit.
4. **#21, #24:**
   - Session-timeout and goal-breach toggles take effect.
   - The daily report goes out once, at or after its set time. Shortcut for testing it without waiting a day: see #24.
5. **#14, #20:** a reply push deep-links to the history (cold and warm start), and the history updates live.
6. **#16, #19:** the reset link flow works; account deletion works (use a throwaway account).

---

## Open decisions

| Decision | Status |
|---|---|
| Weekly goals: no temporary weekly goals (W7), a "Week starts on" setting (W2), and `includesPastActivity` for daily goals too (W4) | **Waiting for the user.** See `docs/specs/weekly-goals.md` |
| Daily report expiry (dropped once its due day ends) | Implemented. The user may want it dropped (#24, decision 4). |
| Sign in with Apple: configure the provider or hide the button; token revocation on account deletion | Open (backlog) |
| Re-enable email confirmation (ADR-004) | After #16 is tested |

---

## Testing

The unit suite uses Swift Testing. The test count grows across the stack; the highest is 440 on #23 (#21 → #24: 402). Run:
```
xcodebuild test -project Nudge.xcodeproj -scheme Nudge \
  -destination 'platform=iOS Simulator,arch=arm64,id=19C7BD9B-6973-4F63-8492-C8D13401B835'
```
Run at most two `xcodebuild` processes at once on this Mac; five parallel builds pushed the load average to about 400 and hung test launches.

---

## History

Earlier phase-by-phase history (Phase 0–1 setup, Strategy 1 → 2, Twilio/APNs setup) is in `docs/ProgressLog.md` and the ADRs in `docs/decisions.md`. Read the specs' "implementation notes" sections for per-feature detail.
