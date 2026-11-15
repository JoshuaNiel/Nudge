# Phase 3 — Goals (v2: tokens + milestones)

**Status:** `[~] Spec v2 — approved 2026-11-14; 3a + 3b implemented, awaiting on-device verification`

**Supersedes** the v1 spec, which assumed goal progress came from the Supabase `usage`
table. That table is never populated: Screen Time data cannot leave the
`DeviceActivityReport` sandbox (ADR-049). App goals also cannot use bundle IDs, because
`DeviceActivityEvent` only accepts opaque `ApplicationToken`s, which come from
`FamilyActivityPicker` (ADR-042).

**Goal:** Users create daily time limits for one app, for a named category (a group of apps
and/or Apple categories), or for total screen time. They see progress in two forms:
**approximate progress** in 10% steps, which the app can reason about, and the **exact
usage**, drawn by the report extension.

---

## Key decisions

| # | Decision | Why |
|---|---|---|
| G1 | App and category targets are stored as a `FamilyActivitySelection`, PropertyList-encoded then base64, in a new `selection text` column. App goal → `goal.selection` (exactly 1 application token). Category → `app_category.selection` (≥1 app or Apple category token). | Tokens are the only identifier `DeviceActivityEvent` accepts. Storing them server-side survives reinstalls and keeps the App Group a cache rather than the only copy. |
| G2 | App goals get a user-typed **label** (`goal.label`, e.g. "Instagram"). Category goals use `app_category.name`. Total goals use "All Apps". | The main app and the monitor extension cannot turn a token into a name. Only `Label(token)` inside a SwiftUI view can display one. SMS nudges need a real string. |
| G3 | **Milestone events:** every monitored goal registers events at 10%, 20% … 100% of its limit, named `goal.<id>.p<NN>` (e.g. `goal.42.p50`). This replaces the `app.<bundle>` / `category.<id>` / `total` names from ADR-036 for goals. `session.timeout` is unchanged. | The extension can't read usage directly; milestone thresholds are the only signal it gets, and it can write that signal to the App Group. 10% is a constant in `MonitoringPlan` (`milestoneStepPercent`). |
| G4 | The extension records milestones in the App Group as `nudge.progress.<yyyy-MM-dd>` → `{goalId: highestPercent}`. Each milestone **fires its side effects at most once per goal per day** (dedup key `nudge.fired.<yyyy-MM-dd>` → set of event names). | Re-registering mid-day (after a goal edit) restarts counting, so milestones can fire again. Without dedup that would mean duplicate nudges. Progress keeps the max. Keys older than 2 days are pruned at `intervalDidStart`. |
| G5 | Side effects: p10–p90 → record progress only (Phase 4 adds why-reminders). **p100 = goal reached** → record, post a local "limit reached" notification, and enqueue a goal-breach nudge if goal-breach nudges are enabled (5E; until 5E lands, always enqueue, matching current behaviour). | One place decides what each milestone does. |
| G6 | **Daily goals only** in 3a/3b. **Weekly** follows as its own PR (separate repeating weekly schedule + re-arm, week start from `profile.week_start`); **monthly** stays in the backlog because one interval cannot exceed Apple's maximum (`intervalTooLong`). Keep `MonitoringPlan` structured so a second activity per frequency can be added. The UI offers no weekly/monthly option, and `MonitoringPlan` skips non-daily goals. The enum and DB keep all three values. | The schedule is a repeating daily interval. Weekly/monthly thresholds would need separate multi-day schedules, which can come later (backlog). |
| G7 | **Temporary goals** (start/end dates) are monitored only on days inside their range. `GoalSummary` gains `startDate`/`endDate` (`yyyy-MM-dd`, optional), and `MonitoringPlan.composeSummaries` filters by today's date. | The extension re-registers at midnight using the App Group copy, so the date filter has to live in shared code. Otherwise an expired goal would keep firing until the app is opened. |
| G8 | **Exact usage** comes from a second report context, `goalUsage` (`DeviceActivityReport.Context("GoalUsage")`). It's shown on a Goal detail screen using `DeviceActivityFilter(segment: .daily(today), applications:, categories:)` built from the goal's selection (no apps = total). The extension renders "47m used today". The host app draws the limit and milestone bar around it. | The extension can't receive the limit (no App Group reads guaranteed), and only the extension can see exact numbers. |
| G9 | Goal edits re-register monitoring through `MonitoringRegistrationService.goalDidChange` (debounced **1.5 s**, per ADR-035; the code says 10 s and gets fixed). | Fixes the "goalDidChange has no caller" backlog item. |
| G10 | Categories are managed from the **Apps** tab, renamed **"Categories"**: list, create (name + color + picker), edit selection, delete. The `app` and `app_category_member` tables are no longer used (kept in the schema, marked deprecated, like `usage`). | The Apps tab is an empty stub, and categories are now picker selections, not bundle-ID membership rows. |

---

## Data

### Migration `006_goal_selection.sql`
```sql
alter table public.goal         add column selection text, add column label varchar(100);
alter table public.app_category add column selection text;

-- app goals: selection + label instead of bundle_id
alter table public.goal drop constraint goal_target_check;
alter table public.goal add constraint goal_target_check check (
  (target_type = 'app'      and selection is not null and category_id is null) or
  (target_type = 'category' and category_id is not null and selection is null) or
  (target_type = 'total'    and selection is null and category_id is null)
);
alter table public.goal add constraint goal_label_not_blank
  check (label is null or char_length(btrim(label)) > 0);
alter table public.goal add constraint goal_app_label_required
  check (target_type <> 'app' or label is not null);
```
`bundle_id` stays nullable and unused. The duplicate-goal unique index (ADR-010) is
re-checked by the implementer: two app goals for different apps must not collide just
because `bundle_id` is NULL. If the index includes `bundle_id`, it is replaced so it is
keyed on (`user_id`, `target_type`, `category_id`, `selection` hash, `frequency`) for
non-temporary goals.

### Models
- `Goal` gains `selection: String?`, `label: String?`.
- `AppCategory` gains `selection: String?`.
- `GoalSummary` (Shared) gains `startDate`, `endDate`, `frequency`, and
  `selectionData: Data?` (decoded token set for app/category goals; category goals carry
  the category's selection). It stays backward-compatible when decoding old App Group
  JSON (`decodeIfPresent`).
- A pure `SelectionCodec` (Shared) encodes/decodes `FamilyActivitySelection` ↔ base64,
  unit-tested with an empty selection round trip.

### App Group keys (new)
| Key | Written by | Read by |
|---|---|---|
| `nudge.progress.<day>` | monitor ext | app (Goals list) |
| `nudge.fired.<day>` | monitor ext | monitor ext (dedup) |

---

## UI

**Goals tab:** a list of goals. Each row shows the target (`Label(token)` icon + label for app
goals, color dot + name for categories, "All Apps" for total), the limit ("2h / day"),
and a 10-step progress bar from `nudge.progress.<today>` with the caption "≈ 50% used" ("Limit
reached" at 100%). The progress bar refreshes on foreground. Tapping a row opens **Goal
detail**: an exact-usage report view (G8), the limit, the milestone bar, temporary dates if
any, and delete. Swipe-to-delete still works.

**Add Goal sheet:** target type → (App: `FamilyActivityPicker` restricted to exactly one
app, plus a required "Name" field, prefilled empty with the placeholder "e.g. Instagram" | Category:
pick an existing one or "New category…" | Total) → limit (hours + minutes, minimum 5 min) →
optional temporary range. No frequency picker (daily only). Save → `createGoal` →
`goalDidChange`.

**Categories tab:** a list of categories with a color dot and "N apps, M categories". Create/edit
sheet: name (required, unique per user; DB error → "You already have a category with this
name"), color (preset palette of 8 hex colors), `FamilyActivityPicker` (≥1 token
required). Deleting asks for confirmation and states that goals using the category are
deleted too (DB cascade). Editing a category's selection triggers `goalDidChange`.

## Edge cases
- Screen Time not authorized → Goals and Categories show a "Screen Time access required"
  state with a Settings link instead of the picker.
- A selection that fails to decode (e.g. a token from another device) → the goal is shown
  with "Re-select app", is skipped by `MonitoringPlan`, and is logged.
- Duplicate non-temporary goal → friendly error (ADR-010).
- Progress keys missing (new day, extension hasn't fired) → bar at 0%, caption "Under 10%".
- Deleting a goal removes its progress entry at the next prune. The UI ignores unknown ids.

## Acceptance criteria
- [ ] Create app, category and total daily goals. Each registers 10 milestone events.
- [ ] Goal list shows 10%-step progress written by the extension. Goal detail shows exact usage.
- [ ] p100 posts a "limit reached" notification and enqueues a goal-breach nudge, at most once a day.
- [ ] Temporary goals are monitored only inside their date range, including after midnight with the app closed.
- [ ] Editing goals or categories re-registers within ~1.5 s, without duplicate notifications.
- [ ] Category CRUD works. Deleting a category removes its goals.
- [x] All pure logic (milestone event names/thresholds, composition with date filter, progress
      decode/merge/prune, dedup, selection codec, label rules) is unit-tested. (3a)

## 3a implementation notes (decisions made while implementing)

- **Catalog vs. active set.** `nudge.goals.active` now holds the *unfiltered* catalog
  (every goal + the session-timeout pseudo-goal). `MonitoringPlan.register` filters it to
  today's active set (daily + inside the temporary range) on every registration. Without
  this the extension could never arm a temporary goal on its first day at midnight.
  `refreshMonitoring` persists the freshly fetched catalog even when it does not
  re-register, so an edit that does not touch today's set (e.g. a goal starting tomorrow)
  reaches the extension without resetting today's counters.
- **Signature** = `v2;` + sorted `eventName|targetType|limitSeconds|sha256(selectionData)`
  over the *active* set. The selection fingerprint makes a category edit re-register even
  if the limit is unchanged. The `v2` tag makes upgraded installs re-register once.
- **Event names** `goal.<id>.p<NN>`, no zero padding. Thresholds are
  `max(1, limit * NN / 100)` (floored; p100 exact). Parsing accepts canonical names only.
- **Skipped goals.** App/category goals with a missing, undecodable *or empty* selection
  are skipped and logged — an empty token set would otherwise monitor all usage.
- **Session timeout** is `GoalSummary(goalId: 0, eventName: "session.timeout",
  targetType: .total)` and is deduped once per day like milestones.
- **Decision logic in Shared.** `ThresholdRouter.route` (parse → match → dedup → progress)
  is unit-tested; the extension only runs side effects. Phase 4 hooks into
  `handleMilestone`; Phase 5E's toggle replaces `shouldSendGoalBreachNudge`.
- **`goalDidChange()`** takes no arguments: after 1.5 s it fetches goals + session
  timeout itself (`MonitoringInputsLoading`) and calls `refreshMonitoring`. A failed fetch
  never registers (ADR-055). Use `MonitoringRegistrationService.shared` so all screens
  share one debounce window; ViewModels depend on `MonitoringRegistrationServiceProtocol`.
- **Pruning** keeps today and the two previous days; malformed progress/fired keys are
  removed.
- **Migration 006** deletes legacy app goals with no selection (they could never be
  monitored and would violate the new target check) and replaces the app unique index with
  `(user_id, md5(selection), frequency)` — best effort, since re-picking an app can yield
  different token bytes. Selections are capped at 131072 chars.
- **Interim UI (until 3b):** the Add Goal sheet's "Specific App" option is disabled
  ("Coming soon"); the bundle-ID text field is gone.

### 3a checklist
- [x] Migration `006_goal_selection.sql` (written; run manually in the SQL editor)
- [x] `Goal`/`AppCategory`/`GoalInsert` gain `selection`/`label`; enums moved to `Shared/`
- [x] `GoalSummary` gains `targetType`, `frequency`, `startDate`, `endDate`, `selectionData` (backward-compatible decode)
- [x] `SelectionCodec`
- [x] `MonitoringPlan` milestones, date/frequency filter, selection-aware signature
- [x] `GoalProgressStore` (progress merge, dedup, prune) + `AppGroupKeys` builders
- [x] Monitor extension: dedup, progress, p100 notification + nudge, prune at `intervalDidStart`
- [x] `GoalService.fetchGoalSummaries` reads selection/label/category selection
- [x] `goalDidChange()` 1.5 s debounce, self-fetching (not yet wired to UI — 3b)
- [ ] On-device verification (see 3b)

## 3b implementation notes (decisions made while implementing)

- **Pure rules are testable types**, not view code: `GoalTargetValidation` (exactly one
  app token, no categories/web domains; label required, ≤100 after trimming),
  `GoalLimit` (5 min … 23h 59m), `GoalDateRange` (start ≥ today, end ≥ start, by local
  day; `yyyy-MM-dd` via `MonitoringPlan.dayStamp`), `GoalProgressDisplay` (10 steps;
  "Under 10%" / "≈ N% used" / "Limit reached"), `CategoryRules`, `CategoryPalette`,
  `SaveErrorMessage` (`23505` → friendly copy, anything else → generic; raw DB errors are
  never shown), `GoalUsageSummary` / `GoalUsageDay` (Shared). Tests:
  `NudgeTests/GoalsUITests.swift`.
- **`GoalListItem.make`** resolves each goal against its category, decoded selection and
  today's progress. Status: `active`, `needsReselect` (missing/undecodable/empty
  selection, or missing category — same skip rule as `MonitoringPlan`), `notMonitored`
  (legacy weekly/monthly rows: listed so they can be deleted, never labelled with a
  frequency, limit shown without "/ day"), `notActiveToday` (temporary goal outside its
  range). Only `active` rows show milestone progress.
- **Re-select.** Tapping a `needsReselect` row skips the detail: app goals open a
  picker sheet that saves through the new `GoalServiceProtocol.updateGoalSelection`
  (same validator; `23505` mapped); category goals open that category's editor.
- **Goal detail** builds `DeviceActivityFilter(segment: .daily(during: today))` with the
  goal's (or its category's) application/category/web-domain tokens; total → no tokens.
  App/category goals without a usable selection show no report (an empty filter would
  report all usage under the goal's name). Report frame is fixed at 110 pt (ADR-044) and
  re-keyed on foreground. The extension's `GoalUsageReport` sums segment
  `totalActivityDuration`, rounding once.
- **ViewModels:** `GoalsViewModel` (list, progress refresh without refetch, delete,
  re-select), `AddGoalViewModel`, `CategoriesViewModel`, `CategoryEditorViewModel`. Each
  successful write calls `goalDidChange()` exactly once (on
  `MonitoringRegistrationService.shared`); failures never do. Category *create* also
  calls it, per the spec; it does not re-register because the active-set signature is
  unchanged. A failed delete shows an alert and leaves the list in place.
- **Services.** `CategoryService` now has a protocol and is user-scoped on every query
  (in addition to RLS): `fetchCategories(userId:)`, `createCategory(userId:name:color:selection:)`,
  `updateCategory(id:userId:name:color:selection:)`, `deleteCategory(id:userId:)`.
  `userId` is explicit because `app_category.user_id` has no default. The bundle-ID
  member methods, `AppCategoryMember` and the stub `GoalEvaluationService` (which read
  the never-populated `usage` table) are removed, as is `GoalWithProgress`.
- **Progress** is read through `GoalProgressReading` (`AppGroupGoalProgressReader` wraps
  `GoalProgressStore`) on every appear of the Goals tab and every foreground. Goals and
  categories are also refetched when the Goals tab appears, because deleting or editing
  a category in the Categories tab changes them.
- **Screen Time not authorized** → both tabs show `ScreenTimeAccessRequiredView` (now
  shared with the Dashboard) using `DashboardAvailability.isScreenTimeAuthorized()`;
  re-checked on appear and foreground.
- **Category selections** need ≥1 app or Apple-category token. Web domains may be
  included alongside (they are monitored) but are not enough on their own; the summary
  adds ", N websites" only when present. Name ≤100 (`varchar(100)`).
- **Category delete** uses a non-destructive-role swipe action plus a confirmation
  dialog ("Goals that use this category will be deleted too.") so the row is not removed
  before the user confirms. Goal swipe-to-delete stays immediate; the detail screen's
  Delete asks for confirmation.
- **Palette:** `#FF3B30 #FF9500 #FFCC00 #34C759 #00C7BE #007AFF #5856D6 #AF52DE`
  (default `#007AFF`). An existing category with a non-palette but valid hex keeps it.
- **Tab:** the Apps tab (`AppsView`) is replaced by `CategoriesView`, labelled
  "Categories", same icon.

### 3b checklist
- [x] Goals list: target (`Label(token)` + label / color dot + name / "All Apps"), "Xh / day", 10-step bar + caption, refresh on appear + foreground, swipe-to-delete
- [x] "Re-select app" state for undecodable selections (tap → picker / category editor)
- [x] Goal detail with `goalUsage` report (second scene in `NudgeActivityReport`), limit, milestone bar, temporary range, Delete with confirmation
- [x] Add Goal sheet: App (`FamilyActivityPicker`, exactly one app, required name) | Category (existing or "New category…") | Total; limit 5 min–23h 59m; optional temporary range; no frequency option
- [x] Categories tab: list with "N apps, M categories", create/edit (name, 8-color palette, picker), delete with cascade warning
- [x] `goalDidChange()` wired to every goal/category write (once on success, never on failure)
- [x] Screen Time not authorized → access-required state on Goals and Categories
- [x] Unit tests for all of the above (`GoalsUITests.swift`)
- [ ] On-device verification (acceptance criteria above)

## PR split
- **3a `feat/goals-core`**: migration 006, models, `SelectionCodec`, `MonitoringPlan` milestones + date
  filter, monitor extension progress/dedup/p100, `goalDidChange` debounce fix, tests.
- **3b `feat/goals-ui`**: Goals list/detail, Add Goal sheet with picker, Categories tab,
  `goalUsage` report context, wiring `goalDidChange`.
