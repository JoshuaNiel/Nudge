# Phase 4 — Why-Reminders & Goal Notifications (v2)

**Status:** `[~] Implemented 2026-11-14 (simulator-tested; device checks pending)`. Spec v2 approved 2026-11-14. Stacked on Phase 3b (goals-ui).

**Goal:** A user attaches personal "why" messages to a goal ("I want to be present with my
kids"). When usage reaches a percentage they chose for that why, a local notification
shows it. Reaching the limit always produces a notification.

## Resolved open questions (v1)
1. *Can the monitor extension post local notifications?* **Yes.** Validated on device
   2026-09-06 (it already posts on threshold).
2. *Unlock prompt*: **dropped**. iOS exposes no unlock event.
3. *Why-reminder frequency*: **not time-based**. The user decided why-reminders fire at a
   per-why percentage of their goal (2026-11-14). The fixed 9am schedule and the per-goal
   morning reminders are removed from scope.

## Data — migration `007_why_reminder_goal.sql`
```sql
delete from public.why_reminder;  -- unused so far; old rows have no goal to attach to
alter table public.why_reminder
  add column goal_id bigint not null references public.goal(id) on delete cascade,
  add column notify_percent int not null default 80,
  add constraint why_reminder_percent_step
    check (notify_percent between 10 and 100 and notify_percent % 10 = 0);
create index why_reminder_goal_idx on public.why_reminder(goal_id);
```
The existing RLS (own rows) still applies. The insert policy must also check that `goal_id`
belongs to the user (`exists (select 1 from goal where id = goal_id and user_id = auth.uid())`).

`WhyReminder { id, userId, goalId, message (≤500, non-blank), notifyPercent }` with
CodingKeys. `ReminderService` (protocol + class) provides fetch (all of the user's), add, update,
and delete.

## Delivery
- The main app writes `nudge.reminders.byGoal` → `{goalId: {percent: [message]}}` to the App
  Group on every foreground and after every reminder edit. This is **not** part of the
  monitoring signature, so editing a why never re-registers monitoring (no reset).
- Milestones are 10% steps (Phase 3a), so every allowed `notify_percent` matches an
  existing event. No extra events are registered.
- On milestone `goal.<id>.p<NN>` (after the Phase 3a dedup), if whys exist at NN, the extension
  posts one notification:
  - Title: "You're at NN% of your <label> limit" (p100: "You've hit your <label> limit")
  - Body: one why message, rotating round-robin per (goal, percent). The index is stored in
    `nudge.reminders.rr`.
- p100 with no why at 100 → the generic limit notification from Phase 3a (body "You set a
  2h daily limit on Instagram."). With a why at 100 → that notification uses the why as its
  body (one notification, not two).
- Notification permission denied → posting fails silently and is logged. No crash.

## UI
- **Goal detail → "Why" section:** a list of whys showing message + "at 80%". Add/edit sheet:
  multiline message (required, ≤500, counter), percent picker 10…100 step 10 (default 80).
  Swipe to delete.
- **Settings → Notifications row:** current permission status (Allowed / Off / Not asked).
  Off → "Open Settings" deep link. Not asked → a "Turn on" button that requests permission.

## Acceptance criteria
- [x] A user can add, edit and delete whys on a goal, each with its own percent.
- [ ] Reaching that percent posts a notification with the why. Multiple whys at the same
      percent rotate day to day.
- [x] At most one notification per goal per milestone per day.
- [x] Editing whys does not reset monitoring progress.
- [ ] Settings shows notification permission and recovers from "denied".
- [x] Tests: model coding, payload encoding of `byGoal`, round-robin selection, title/body
      composition (p<100, p100 with/without why), percent validation.

Device-only (unchecked until verified on a phone): a why posts at its percent and rotates day
to day; the permission row recovers from "denied" via the Settings app.

## Implementation notes (2026-11-14)

**Files**
- `supabase/migrations/007_why_reminder_goal.sql` — goal_id/notify_percent/index + RLS rewrite.
- `Shared/WhyReminderStore.swift` — `WhyRemindersByGoal`, `WhyReminderPayload` (JSON codec),
  `WhyReminderRotation` (pure round-robin), `WhyReminderStore` (App Group read/write/rotate/clear).
- `Shared/GoalNotification.swift` — `GoalNotificationComposer` (p<100 / p100 title + body).
- `Shared/NudgeMessages.swift` — `milestoneReminderTitle`. `Shared/AppGroupKeys.swift` — the two keys.
- App: `Models/WhyReminder.swift`, `Services/ReminderService.swift`,
  `Services/WhyReminderAppGroup.swift` (payload builder, `WhyReminderAppGroupWriting`,
  `WhyReminderSync`), `Features/Goals/WhyReminderRules.swift`, `WhyRemindersViewModel.swift`,
  `WhyRemindersSection.swift`, `WhyReminderEditorSheet.swift`,
  `Features/Settings/NotificationSettingsViewModel.swift` + `NotificationSettingsSection.swift`.
- Edited: `GoalDetailView` (now a `List`; Why section + editor sheet), `SettingsView` (one line),
  `NudgeApp.onForeground` (`WhyReminderSync.refresh`), `AppState.clearAppGroup`,
  `MonitorExtension` (`handleMilestone` / `handleGoalReached`).
- Tests: `NudgeTests/WhyReminderTests.swift` (64 tests).

**Decisions beyond the spec**
- **Length counts code points** (`unicodeScalars`), matching Postgres `varchar(500)`; `String.count`
  (graphemes) would accept emoji-heavy text the DB rejects. Message trimmed of whitespace *and*
  newlines.
- **Rotation order is by reminder id** within (goal, percent), so it does not depend on row order
  from Supabase. A stored index beyond the count (after a deletion) wraps (`index % count`); a
  corrupt negative index restarts at 0. `write` never resets the rotation.
- **The ViewModel loads all of the user's whys** (one request) and writes the complete list after
  every successful add/edit/delete — the App Group copy covers every goal. Writes are refused until
  a load has succeeded, otherwise one goal's edit would wipe every other goal's whys from the copy.
  A successful load also refreshes the copy.
- **RLS:** the `for all` policy is replaced by four per-command policies; insert/update also
  require goal ownership. In addition, UPDATE is column-granted to `message, notify_percent` only.
- **Migration delete is one-time**: guarded by "goal_id does not exist yet", so re-running 007
  never deletes reminders created after it. Wrapped in a transaction.
- **Permission denied in the extension:** no settings pre-check before posting (an extra async
  hop would widen the window in which the extension can be suspended). `add` fails with
  "notifications not allowed"; the failure is logged with the event name.
- **Goal detail became a `List`** (`.insetGrouped`) for native swipe-to-delete; the Phase 3b cards
  are drawn unchanged as inset-free, clear-background rows.
- Settings row lives in its own `NotificationSettingsSection` (one line in `SettingsView`) and
  re-checks on `.task` and on every foreground. "Open Settings" uses
  `UIApplication.openNotificationSettingsURLString` (Nudge's notification page directly).
- Deleting a goal cascades its whys in the DB; the App Group copy keeps the stale entry until the
  next foreground. Harmless: no events are registered for a deleted goal.

## PR
`feat/why-reminders`, stacked on the Phase 3b branch.
