# Phase 3c — Weekly Goals

**Status:** `[ ] Draft — awaiting user confirmation`. Stacks on Phase 3b (goals-ui) + Phase 4.

**Goal:** Users can set a weekly limit (e.g. "Instagram, 5h / week") alongside daily ones,
with the same milestone progress, exact-usage detail, why-reminders and goal-breach nudge.
Monthly stays in the backlog: one monitoring interval cannot exceed a week
(`DeviceActivityCenter.MonitoringError.intervalTooLong`).

## Design

| # | Decision | Why |
|---|---|---|
| W1 | **A second activity, `nudge.weekly`,** with a repeating schedule from the user's week start at 00:00 to the last day of the week at 23:59:59. Daily goals stay on `nudge.daily`. | A threshold accumulates within one interval. A week is the longest interval iOS allows. |
| W2 | **Week start = `profile.week_start`** (0 = Sunday, the existing column and default). Settings gains a **"Week starts on"** row (Sunday / Monday). Changing it re-registers the weekly activity. | The column already exists but has no UI. |
| W3 | **Re-arm, per activity.** `MonitoringPlan` keeps separate stamps per activity (`lastDay`/`lastSignature` for daily, `lastWeek`/`lastWeeklySignature` for weekly). The weekly stamp is the start date of the current week. The extension re-arms whichever activity's `intervalDidStart` fired, using the same loop guard as ADR-054. The app's foreground check covers both. | Thresholds are one-shot per registration, so each interval needs its own re-arm. The two activities are independent, so re-arming one never resets the other. |
| W4 | **`includesPastActivity: true`** on weekly events. The deployment target is already iOS 17.6, so this API (17.4+) is always available. A weekly goal created on Wednesday then counts from the week's start rather than from Wednesday, and re-registering mid-week doesn't reset progress. **Proposed: also apply it to daily events.** That removes ADR-054's "re-registering mid-day resets counters" trade-off. Device verification required. | Without it, any mid-week edit would zero the week's progress, which is far worse for a weekly goal than for a daily one. The once-per-period dedup already stops any re-fired milestones. |
| W5 | **Period-scoped progress and dedup.** Weekly goals use `nudge.progress.week.<weekStart>` / `nudge.fired.week.<weekStart>`. `ThresholdRouter` picks the period key from the goal's frequency. Pruning keeps the current and previous week. | Daily keys would reset at midnight. |
| W6 | **Event names stay `goal.<id>.p<NN>`.** They're unique by goal id across both activities, so the parser is unchanged. | Keeps the strict canonical parsing. |
| W7 | **Weekly goals cannot be temporary** in this version. The toggle is hidden when Weekly is selected. | Partial weeks make "5h / week" ambiguous. Can be revisited later. |
| W8 | **Copy.** Limits show "5h / week". Captions read "this week" (e.g. "≈ 40% used this week"). Goal-breach SMS: "Josh just passed their 5-hour weekly limit on Instagram." The p100 notification: "You set a 5h weekly limit on Instagram." Why-reminder titles: "You're at 80% of your weekly Instagram limit". | The copy has to make the period clear. |
| W9 | **Limits** for weekly goals run from 30 min to 99 h. | A week has 168 h. 99 h keeps the picker reasonable. |
| W10 | **Exact usage in goal detail** for weekly goals uses a `DeviceActivityFilter` covering the current week (start of week → now), totalled by the existing `goalUsage` scene. It shows "4h 12m used this week". | Reuses the 3b report scene. |

## Data
No migration needed: `goal.frequency` already accepts `weekly`, and `profile.week_start`
exists with a 0–6 check. The UI only allows 0 (Sunday) and 1 (Monday).

## Edge cases
- **Changing week start mid-week:** the weekly activity re-registers with the new boundaries. With `includesPastActivity`, the new week's usage counts from its new start. The old week's progress keys are pruned.
- **DST weeks** (167 or 169 h): the schedule is defined by date components, so iOS handles it. Week-start date math uses the user's calendar and is unit-tested.
- **Upgrade:** an existing `weekly` row from before this change (shown as "Not monitored" in 3b) becomes monitored automatically.
- **Event budget:** each weekly goal adds 10 events to the weekly activity. The total stays far below Apple's limits for normal use, and the >200-event warning still applies per activity.

## Acceptance criteria
- [ ] A weekly app, category or total goal can be created. It registers 10 milestones on `nudge.weekly`.
- [ ] Progress persists across days within the week and resets at the user's week start, with the app closed.
- [ ] A mid-week edit does not reset the week's progress (device check, `includesPastActivity`).
- [ ] Goal breach, the p100 notification and whys work for weekly goals, with weekly copy, once per week.
- [ ] Settings → "Week starts on" persists and re-arms the weekly activity.
- [ ] Tests: weekly schedule components for both week starts, week-start date math (DST, year boundary), per-activity stamps and loop guard, period-key selection, prune, copy, limit bounds.

## Questions for the user
1. Weekly goals cannot be temporary (W7). OK?
2. Add the "Week starts on" setting (W2)? Recommended.
3. Use `includesPastActivity` for **daily** goals too (W4)? Recommended. It fixes the mid-day reset, but needs a device check.
