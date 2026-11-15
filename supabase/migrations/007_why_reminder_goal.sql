-- ============================================================
-- Migration 007: why-reminders belong to a goal (Phase 4 v2)
-- Run in Supabase SQL editor after 006_goal_selection.sql.
--
-- A why-reminder is now attached to one goal and shown when that goal reaches
-- notify_percent of its limit (docs/specs/phase-4-notifications.md):
--   why_reminder.goal_id         — the goal it belongs to (deleted with the goal)
--   why_reminder.notify_percent  — 10..100 in steps of 10 (every value matches an
--                                  existing goal.<id>.p<NN> milestone event)
--
-- EXISTING ROWS ARE DELETED. No version of the app has ever written why_reminder (Phase 4
-- is its first UI), and a goal-less row cannot satisfy the new NOT NULL goal_id. Preview
-- what will be removed first:
--   select id, user_id, message from public.why_reminder;
-- The delete runs only on the first application (while goal_id does not exist yet), so
-- re-running this file never deletes reminders created afterwards.
--
-- RLS: the single "for all" own-row policy is replaced by four per-command policies.
-- Insert and update additionally require the referenced goal to belong to the caller, so a
-- user cannot attach a reminder to someone else's goal id. UPDATE is limited to the two
-- user-editable columns (owner and goal are never rewritten).
--
-- Kept from migration 005: why_reminder_message_not_blank.
-- Safe to re-run: guarded add, if-not-exists, drop-if-exists before every create.
-- ============================================================

begin;

-- goal_id (+ the one-time delete of goal-less rows, see header).
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'why_reminder' and column_name = 'goal_id'
  ) then
    delete from public.why_reminder;
    alter table public.why_reminder
      add column goal_id bigint not null references public.goal(id) on delete cascade;
  end if;
end $$;

alter table public.why_reminder
  add column if not exists notify_percent int not null default 80;

alter table public.why_reminder drop constraint if exists why_reminder_percent_step;
alter table public.why_reminder
  add constraint why_reminder_percent_step
    check (notify_percent between 10 and 100 and notify_percent % 10 = 0);

-- FK lookups (the goal-delete cascade) and per-goal reads.
create index if not exists why_reminder_goal_idx on public.why_reminder(goal_id);


-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------

-- Old (schema.sql):
--   create policy "Users can manage their own reminders"
--     on public.why_reminder for all to authenticated
--     using ((select auth.uid()) = user_id)
--     with check ((select auth.uid()) = user_id);
drop policy if exists "Users can manage their own reminders" on public.why_reminder;

drop policy if exists "Users can read their own reminders"   on public.why_reminder;
drop policy if exists "Users can insert their own reminders" on public.why_reminder;
drop policy if exists "Users can update their own reminders" on public.why_reminder;
drop policy if exists "Users can delete their own reminders" on public.why_reminder;

create policy "Users can read their own reminders"
  on public.why_reminder for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can insert their own reminders"
  on public.why_reminder for insert
  to authenticated
  with check (
    (select auth.uid()) = user_id
    and exists (
      select 1 from public.goal g
      where g.id = why_reminder.goal_id
        and g.user_id = (select auth.uid())
    )
  );

create policy "Users can update their own reminders"
  on public.why_reminder for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and exists (
      select 1 from public.goal g
      where g.id = why_reminder.goal_id
        and g.user_id = (select auth.uid())
    )
  );

create policy "Users can delete their own reminders"
  on public.why_reminder for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- Least privilege: clients may edit only the message and the percent. Moving a reminder
-- to another goal or owner is not a feature; the policies above would reject a foreign
-- goal anyway, this removes the capability outright.
revoke update on public.why_reminder from authenticated;
grant update (message, notify_percent) on public.why_reminder to authenticated;

commit;

-- Verify:
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_schema = 'public' and table_name = 'why_reminder';
--   select policyname, cmd from pg_policies where tablename = 'why_reminder';
