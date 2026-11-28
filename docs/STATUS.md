# Nudge — Project Status

> **Read this first every session.** Update it at the end of each session.
> Last updated: 2026-11-27

---

## Where things stand (2026-11-27)

A PR-by-PR walkthrough with the user is in progress. Each PR is checked out in the **main
folder** (`~/BYU/CS452/screen-time`), fixed in response to the user's decisions and device testing,
then merged (merge commit; squash only for leaf PRs).

### Merged into `main`
| PR | What |
|---|---|
| #13 | Daily re-arm + `includesPastActivity` + FiredEventStore dedup, foreground banners, safe trigger-queue drain |
| #17 | App icon (squash) |
| #14 | APNs registration + reply-push deep link (push-tap crash fixed) |
| #19 | Account deletion + password re-auth (app + server `amr`) + Account Deleted page |
| #20 | Realtime nudge history + live Friends list, friend-accepted push, friend screen (rename/remove) |
| #16 | Auth: 8-char rule, specific link errors, email confirmation, PKCE Resend, eye toggle, confirm-email screen, generic 429 |

### Open, in order
| PR | Branch | State |
|---|---|---|
| **#26** | `feat/onboarding-progress` | **Done and device-tested; the user said "looks good". Confirm, then merge (merge commit).** Migration 009 has been run. |
| #15 | `feat/phase-2-dashboard` | Next. Merge `main` into it, then decisions → setup → testing |
| #18 | `feat/goals-core` | Must adopt `FiredEventStore` (#13) instead of its own fired set; burst of milestones on a lowered limit (notify only the highest) |
| #22 | `feat/goals-ui` | Replaces the Goals UI. **Must carry #26's add-goal permission asks** (`GoalsSheetFlow`) |
| #23 | `feat/why-reminders` | |
| #21 | `feat/nudge-trigger-settings` | |
| #24 | `feat/daily-report` | |
| #25 | `docs/session-wrap-2026-11-14` | Docs (this file). Merge last |

**Known mock fixes the remaining branches will need** after merging `main`: `fetchFriendId` stubs in
#21/#24 mocks; `updateGoalSelection` in #21's MockGoalService; #19-era deletion tests vs #18 key
helpers. See the commit `preview: fix test mocks…` on `preview/all-2026-11-14`.

### Constraints for testing
- **SMS sending is broken** (`send-nudge` returns 429/502). Don't test texts; verify local notifications.
- The user deploys Edge Functions and runs migrations themselves.
- Supabase's built-in email: about 2/hour, team members only (custom SMTP is backlogged).

---

## Testing

The unit suite uses Swift Testing. The test count grows across the stack; the highest is 440 on #23 (#21 → #24: 402). Run:
```
xcodebuild test -project Nudge.xcodeproj -scheme Nudge \
  -destination 'platform=iOS Simulator,arch=arm64,id=CBF5092A-00BE-4690-87E7-E0A3D9F376D6'
```
Run at most two `xcodebuild` processes at once on this Mac; five parallel builds pushed the load average to about 400 and hung test launches.

---

## History

Earlier phase-by-phase history (Phase 0–1 setup, Strategy 1 → 2, Twilio/APNs setup) is in `docs/ProgressLog.md` and the ADRs in `docs/decisions.md`. Read the specs' "implementation notes" sections for per-feature detail.
