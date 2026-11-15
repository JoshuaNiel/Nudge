# Phase 5E — Nudge Trigger Settings + Daily Report (v2)

**Status:** `[ ] Spec v2 — approved 2026-11-14`. 5E-1 stacked on Phase 3a (goals-core); 5E-2 stacked on 5E-1.

## Settings storage — migration `008_nudge_settings.sql`
A separate table, as the backlog recommends, so per-friend trigger config can be added later
without reshaping `profile`.
```sql
create table public.nudge_settings (
  user_id                 uuid primary key references auth.users(id) on delete cascade,
  session_timeout_enabled boolean not null default true,
  session_timeout_minutes int     not null default 60
    check (session_timeout_minutes in (15, 30, 60, 90, 120)),
  goal_breach_enabled     boolean not null default false,
  daily_report_enabled    boolean not null default false,
  daily_report_time       time    not null default '08:00',
  updated_at              timestamptz not null default now()
);
-- RLS: own row only (select/insert/update), force RLS, (select auth.uid()) pattern.
-- Backfill: insert a row for every profile with session_timeout_minutes set, snapping
-- the value to the nearest allowed option. profile.session_timeout_minutes is left in
-- place but deprecated (no longer read). It is dropped in a later cleanup migration.
```
No row means defaults. The app upserts a row on first save.

`NudgeSettings` model (CodingKeys; `daily_report_time` decoded from Postgres `"HH:mm:ss"`)
and a `NudgeSettingsService` (protocol + class: `fetch`, `save` via upsert).

## Behaviour
- **Session timeout:** registered only when enabled, using `session_timeout_minutes`.
  `AppState.sessionTimeoutMinutes` is sourced from `nudge_settings` (nil when disabled).
- **Goal breach:** the monitor extension enqueues the p100 nudge only when
  `goal_breach_enabled`. The local "limit reached" notification fires regardless.
- **Settings in App Group:** `nudge.settings` (JSON) is written on load and save. It is not
  part of the monitoring signature, except that the session-timeout event is part of it
  (already true through `composeSummaries`).

## Daily report (total-only, approximate)
Per-app numbers are unavailable outside the report extension (ADR-049), and that extension
only runs while the app is drawing it on screen. So the report is **total screen time only, in 15-minute steps**.
- When enabled, `MonitoringPlan` adds total-usage events `total.m<NN>` every 15 min up to
  12 h (48 events, no app filter).
- The extension records the highest one per day at `nudge.dailyTotal.<yyyy-MM-dd>` (minutes).
- At `intervalDidStart` (midnight), if the report is enabled, the extension enqueues a
  `PendingTrigger(eventName: "daily.report", report:, notBefore: <today at daily_report_time>)`
  for **yesterday**. `PendingTrigger` gains an optional `notBefore` (decodeIfPresent).
- `NudgeTriggerService.drainPendingTriggers` sends only triggers with `notBefore ≤ now`
  and keeps the rest queued. When scheduling the BG task, `earliestBeginDate` is set to the
  earliest queued `notBefore`. **Delivery is at or after the chosen time**, when iOS next
  runs the app (foreground or background task). The Settings footer says so.
- Copy (`NudgeMessages.dailyReport`, which loses its `topApps` parameter):
  `"Josh's screen time yesterday: about 3h 15m."`. 12 h milestone hit → `"over 12 hours"`.
  (The function returns `"under 15 minutes"` below the first milestone, but that is never
  sent: nothing recorded → no report, below.)
- If nothing was recorded for yesterday (device off, or the report enabled mid-day) → no report is sent.
- `_shared/messages.ts` and `send-nudge` need no change, since the report text is built on iOS.

## UI — Settings → "Nudges" section
- Toggle "Too much screen time" + picker (15/30/60/90/120 min), footer "Friends are
  nudged after this much total screen time in a day."
- Toggle "Goal limit reached", footer "Friends are nudged when you hit a goal's limit."
- Toggle "Daily report" + time picker (shown when on), footer about approximate totals and
  "at or after" delivery.
- Changes save with the existing Settings Save bar. On save: upsert → write App Group → `goalDidChange`.
- No accepted friends → a section note: "Add a friend to start sending nudges."

## Acceptance criteria
- [ ] Toggles persist across launches and devices (server-side), and defaults apply with no row. *(5E-1: implemented + unit-tested; device check pending)*
- [ ] Session timeout off → no `session.timeout` event registered. *(5E-1: implemented + unit-tested; device check pending)*
- [ ] Goal breach off → no nudge on p100, but the local notification still shows. *(5E-1: implemented; device check pending)*
- [ ] Daily report sends yesterday's approximate total once, at or after the chosen time. *(5E-2: implemented + unit-tested; device check pending)*
- [ ] Tests: settings coding (time parsing), backfill snapping function (if done in Swift
      it's tested; otherwise SQL reviewed), total-milestone events, dailyTotal recording,
      `notBefore` drain filtering, copy edge cases.

## 5E-1 implementation notes (decisions made while implementing)
- **Model.** `NudgeSettings` (`Models/NudgeSettings.swift`) + `NudgeSettings.defaults` (= SQL
  defaults) + `allowedSessionTimeoutMinutes` (= SQL CHECK). `daily_report_time` is a
  `TimeOfDay` (`Shared/NudgeTriggerSettings.swift`): decodes `"HH:mm"`, `"HH:mm:ss"` and
  `"HH:mm:ss.ffffff"` (seconds dropped), encodes `"HH:mm:ss"`, rejects out-of-range values.
- **Service.** `NudgeSettingsService.fetch` selects an array (`limit 1`), so zero rows →
  defaults while a request error still throws. `save` upserts `NudgeSettingsUpsert`
  (`user_id` + columns) on `user_id` with `returning: minimal`. `updated_at` is set by a DB
  trigger, never sent by the client.
- **Snapping is SQL-only** (migration backfill): nearest of 15/30/60/90/120 by absolute
  distance, ties → the larger value (45 → 60, 75 → 90, 105 → 120). No Swift snapping.
  Profiles with `session_timeout_minutes IS NULL` get no row and so the defaults (on, 60).
- **Session timeout source.** `SupabaseMonitoringInputsLoader` (goalDidChange path) and
  `AppState.fetchAndCacheNudgeSettings` (foreground path) read `nudge_settings`;
  disabled → `nil` minutes. `profile.session_timeout_minutes` is no longer read anywhere.
  A failed settings fetch fails the load and never re-registers (ADR-055). On foreground the
  *profile* fetch no longer gates registration (it carries nothing that is registered);
  settings + goals do.
- **App Group `nudge.settings`.** JSON `NudgeTriggerSettings` (`goal_breach_enabled`,
  `daily_report_enabled`, `daily_report_time`). Written on every successful settings load
  (foreground, Settings screen) and save; never on a failed load; removed on sign-out. The
  monitor extension reads it in `shouldSendGoalBreachNudge`; missing/undecodable →
  `failClosed` (all off): a wrong "on" texts friends without consent, a wrong "off" only
  skips a nudge. The local "limit reached" notification fires regardless.
- **Settings save.** One Save bar for profile + nudge settings; dirty tracking covers both.
  Save writes only what changed, each part independently (one failing does not discard the
  other). Profile field validation only blocks the save when the profile is being saved.
  Settings success → App Group → `goalDidChange()` (once). Settings failure → error shown,
  nothing changed locally, the edit stays dirty for a retry.
- **Load failure.** If `nudge_settings` fails to load, the Nudges controls are disabled and
  never count as changes, so placeholder defaults can never be saved over the real row.
- **Friends note.** Shown only when the friends fetch succeeded with zero *accepted* friends
  (pending don't count); a failed fetch hides it.
- **UI details.** Three Form sections (one per trigger, each with its footer; the first has
  the "Nudges" header). Picker labels use `formattedDuration` (15m … 2h). The session
  picker and the daily-report time picker are shown only while their toggle is on.

### 5E-1 checklist
- [x] Migration `008_nudge_settings.sql` (written; run manually in the SQL editor)
- [x] `NudgeSettings` / `TimeOfDay` / `NudgeTriggerSettings` + `NudgeSettingsService`
- [x] Session timeout sourced from `nudge_settings` (loader + foreground), ADR-055 preserved
- [x] App Group `nudge.settings`; extension goal-breach gate (fail closed)
- [x] Settings "Nudges" section on the shared Save bar
- [x] Tests (`NudgeSettingsTests.swift`)
- [ ] On-device verification

## 5E-2 implementation notes (decisions made while implementing)
- **Events.** `total.m<NN>`, NN = 15, 30 … 720 (48 events), no zero padding, no app filter,
  threshold = NN minutes. Built and parsed in `Shared/MonitoringEvents.swift`
  (`MonitoredEvent.dailyTotal(minutes:)`); parsing is canonical-only (`total.m015`,
  `total.m+15`, `total.m14`, `total.m735`, legacy `total` → `.unknown`).
- **Report toggle in the registration.** `MonitoringPlan.register` reads
  `daily_report_enabled` from the App Group `nudge.settings` itself
  (`isDailyReportEnabled`), and every staleness check (app `refreshMonitoring`, extension
  re-arm) uses the same `registrationSignature(catalog:defaults:now:calendar:)`. One
  source for both sides means the app and the extension can never compute different
  signatures and re-register each other in turn. Missing settings → off (fail closed).
- **Signature.** `registrationSignature` = the goal signature, plus
  `;total.m15|15|720` when the report is on. Toggling re-registers; changing only the time
  does not. With the report off it is byte-identical to the 3a signature, so upgrading
  does not re-register.
- **Extension re-arm with no goals.** An empty catalog no longer skips the re-arm when the
  report is on (the report needs no goals).
- **Event count.** Worst case per registration = goals × 10 + 48 + 1. The existing
  `eventCountWarningThreshold` (200) now counts the report events too (warning logged from
  `registrationEvents`), so it is first logged at 16 goals + session + report (209).
- **Recording.** `ThresholdRouter` routes `total.m<NN>` to `.dailyTotal(minutes:)` with no
  catalog lookup and max-merges into `nudge.dailyTotal.<day>` (`Int` minutes,
  `GoalProgressStore.recordDailyTotal`). The fired set is not used: max-merge is
  idempotent and there is no side effect to dedup. No notification, no nudge.
- **Prune.** `GoalProgressStore.prune` now covers every prefix in
  `AppGroupKeys.dayScopedKeyPrefixes` (progress, fired, dailyTotal, dailyReport.enqueued)
  and still keeps today + the two previous days, so yesterday survives the midnight prune.
- **Midnight enqueue** (`Shared/DailyReport.swift`). In `intervalDidStart`, after prune
  and before re-registration: report on + a recorded value > 0 for yesterday + no
  `nudge.dailyReport.enqueued.<yesterday>` → mark it (test-and-set), then append
  `PendingTrigger(eventName: "daily.report", report:, notBefore: today at the report
  time)` and schedule the BG task. Marking first means a crash in between loses one
  report rather than texting twice. The second `intervalDidStart` that re-registration
  provokes finds the marker and does nothing. A mid-day `intervalDidStart` (an app
  registration after a missed midnight) catches up on a report that was never queued;
  if the time has already passed it is due at once.
- **`notBefore`.** `TimeOfDay.date(on: now)`. On a spring-forward day a missing time
  (02:30) resolves to the next valid time that day (03:00); other times use that day's
  offset. A report time change applies from the next report; an already-queued report
  keeps the time it was queued with.
- **`PendingTrigger.notBefore: Date?`** (`not_before`, synthesized `decodeIfPresent`), so
  queues written by older builds decode. `PendingTrigger` is now `Equatable`.
- **Queue helpers** moved to `Shared/PendingTriggerQueue.swift` (`load`/`save`/`append`,
  pure `partition` and `earliestBeginDate`); `MonitoringPlan.loadPendingTriggers` is gone.
- **Drain.** `partition` splits the queue into due (`notBefore` nil or passed), deferred
  (kept untouched) and dropped. A `daily.report` is **dropped** when the App Group setting
  now has the report off (turning the report off withdraws already-queued reports), or
  when it has **expired**: at the end of the local day it was due its "yesterday" names the
  wrong day. Dropped entries are removed before any network call. Only-deferred queues
  make no network calls. Existing semantics kept for due triggers: friend fetch failure
  retains them; no accepted friends clears them (deferred ones stay); a send failure
  retains the trigger. Removal is read-modify-write by (eventName, timestamp).
- **BG scheduling.** `earliestBeginDate` = the earliest future `notBefore` when nothing in
  the queue is due, else `nil` (a due trigger never waits behind a later one). Used by the
  app (going to background, and now also after the BG-task drain so a leftover deferred
  report sets the next run) and by the extension.
- **Copy.** `NudgeMessages.dailyReport(userName:totalMinutes:)`; the `topApps` parameter and
  its tests are gone. `send-nudge` needs no change: it uses `report` verbatim, appends
  `REPLY_OPTIONS` itself, and does not read `event_name` (the app never sends it).
- **Known limits.** Accuracy is the 15-min step. Delivery depends on iOS running the BG task
  or the user opening the app on the day the report is due; a late report time (e.g. 23:30)
  leaves a short window before expiry.

### 5E-2 checklist
- [x] `total.m<NN>` events, parsing, registration + signature from the App Group toggle
- [x] dailyTotal recording (max-merge) + prune keeps yesterday
- [x] Midnight enqueue with idempotency marker
- [x] `PendingTrigger.notBefore`, drain filtering, disabled/expired drop, `earliestBeginDate`
- [x] Copy without `topApps`
- [x] Tests (`DailyReportTests.swift`)
- [ ] On-device verification

## PRs
- **5E-1 `feat/nudge-trigger-settings`**: table, model/service, Settings UI, session/goal-breach toggles.
- **5E-2 `feat/daily-report`**: total milestones, midnight enqueue, `notBefore`, copy.
