-- ============================================================
-- Migration 006: goal + category selections (Phase 3a — tokens + milestones)
-- Run in Supabase SQL editor after 005_non_blank_text.sql.
--
-- App and category goals now store a FamilyActivitySelection (PropertyList-encoded,
-- then base64) instead of bundle IDs, because DeviceActivityEvent only accepts opaque
-- ApplicationTokens from FamilyActivityPicker (ADR-042, phase-3-goals.md G1/G2).
--   goal.selection          — app goals: exactly one application token
--   goal.label              — app goals: user-typed display name (tokens have no name
--                             outside a SwiftUI Label, and SMS copy needs a string)
--   app_category.selection  — category goals: >= 1 app / Apple-category token
--
-- goal.bundle_id stays (nullable, unused). The app and app_category_member tables are
-- deprecated and no longer read or written by the app.
--
-- Safe to re-run: columns use IF NOT EXISTS, constraints/indexes are dropped-if-exists
-- before being recreated.
--
-- Legacy app goals: before this migration an app goal was keyed only by bundle_id. It can
-- never be monitored (no token) and cannot satisfy the new target check, so it is deleted
-- below. Preview what will be removed first:
--   select id, user_id, bundle_id from public.goal where target_type = 'app' and selection is null;
-- ============================================================

alter table public.goal         add column if not exists selection text;
alter table public.goal         add column if not exists label     varchar(100);
alter table public.app_category add column if not exists selection text;

-- Size cap: a selection is a handful of opaque tokens (~100–200 bytes each). 128 KiB of
-- base64 is far above any real picker result and stops a client storing arbitrary blobs.
alter table public.goal         drop constraint if exists goal_selection_size;
alter table public.app_category drop constraint if exists app_category_selection_size;
alter table public.goal
  add constraint goal_selection_size check (selection is null or char_length(selection) <= 131072);
alter table public.app_category
  add constraint app_category_selection_size check (selection is null or char_length(selection) <= 131072);

-- Remove legacy, un-monitorable app goals (see header) so the new target check validates.
delete from public.goal where target_type = 'app' and selection is null;

-- App goals: selection instead of bundle_id. Category goals keep their selection on the
-- category row, so goal.selection must be null for them.
alter table public.goal drop constraint if exists goal_target_check;
alter table public.goal add constraint goal_target_check check (
  (target_type = 'app'      and selection   is not null and category_id is null) or
  (target_type = 'category' and category_id is not null and selection   is null) or
  (target_type = 'total'    and selection   is null     and category_id is null)
);

alter table public.goal drop constraint if exists goal_label_not_blank;
alter table public.goal drop constraint if exists goal_app_label_required;
alter table public.goal
  add constraint goal_label_not_blank    check (label is null or char_length(btrim(label)) > 0),
  add constraint goal_app_label_required check (target_type <> 'app' or label is not null);

-- Duplicate-goal guard for app goals (ADR-010).
-- The old index was keyed on (user_id, bundle_id, frequency). App goals no longer set
-- bundle_id, and Postgres treats NULL != NULL in unique indexes, so it would let any
-- number of identical app goals through. Key it on the selection instead. md5() keeps the
-- index entry small (a btree entry must stay under ~2.7 KB; a selection may not).
--
-- Best effort only: the DB cannot decode tokens, so re-picking the same app can produce a
-- byte-different selection that this index will not catch. The total and category indexes
-- are unaffected (they never involved bundle_id).
drop index if exists public.goal_unique_active_app;
drop index if exists public.goal_unique_active_app_selection;
create unique index goal_unique_active_app_selection
  on public.goal(user_id, md5(selection), frequency)
  where temporary = false and target_type = 'app';
