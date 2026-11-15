-- ============================================================
-- Migration 008: nudge_settings (Phase 5E-1 — nudge trigger settings)
-- Run in Supabase SQL editor after 006_goal_selection.sql (007 is reserved for a
-- separate branch; this migration does not depend on it).
--
-- One row per user holding the global trigger toggles (ADR-039):
--   session timeout  — on/off + minutes (15/30/60/90/120)
--   goal breach      — on/off (nudge friends at a goal's p100)
--   daily report     — on/off + local time of day (sending arrives in 5E-2)
--
-- No row means "defaults" (the column defaults below); the app upserts a row on the
-- first save. A separate table rather than more profile columns, so per-friend trigger
-- config can be added later without reshaping profile.
--
-- profile.session_timeout_minutes is DEPRECATED by this migration: it is backfilled
-- into nudge_settings below and no longer read or written by the app. It is left in
-- place (so this migration is reversible and older builds keep working) and will be
-- dropped in a later cleanup migration.
--
-- Safe to re-run: create-if-not-exists, policies/trigger dropped before being
-- recreated, and the backfill skips users who already have a row.
-- ============================================================

create table if not exists public.nudge_settings (
  user_id                 uuid        primary key references auth.users(id) on delete cascade,
  session_timeout_enabled boolean     not null default true,
  session_timeout_minutes int         not null default 60,
  goal_breach_enabled     boolean     not null default false,
  daily_report_enabled    boolean     not null default false,
  daily_report_time       time        not null default '08:00',
  updated_at              timestamptz not null default now(),

  -- Must match NudgeSettings.allowedSessionTimeoutMinutes in the app.
  constraint nudge_settings_session_timeout_minutes_allowed
    check (session_timeout_minutes in (15, 30, 60, 90, 120))
);

-- ------------------------------------------------------------
-- RLS: each user reads and writes only their own row.
-- No delete policy: rows go away with the auth user (on delete cascade), and the app
-- never deletes settings — "back to defaults" is an update.
-- ------------------------------------------------------------
alter table public.nudge_settings enable row level security;
alter table public.nudge_settings force row level security;

drop policy if exists "Users can read their own nudge settings"   on public.nudge_settings;
drop policy if exists "Users can insert their own nudge settings" on public.nudge_settings;
drop policy if exists "Users can update their own nudge settings" on public.nudge_settings;

create policy "Users can read their own nudge settings"
  on public.nudge_settings for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can insert their own nudge settings"
  on public.nudge_settings for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

-- The app saves with an upsert (INSERT ... ON CONFLICT (user_id) DO UPDATE), which needs
-- the select, insert and update policies together.
create policy "Users can update their own nudge settings"
  on public.nudge_settings for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- ------------------------------------------------------------
-- updated_at is set by the server, never by the client clock.
-- ------------------------------------------------------------
create or replace function public.set_nudge_settings_updated_at()
returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql set search_path = '';

drop trigger if exists nudge_settings_set_updated_at on public.nudge_settings;
create trigger nudge_settings_set_updated_at
  before update on public.nudge_settings
  for each row execute procedure public.set_nudge_settings_updated_at();

-- ------------------------------------------------------------
-- Backfill from profile.session_timeout_minutes.
--
-- Only profiles with a value get a row (session timeout enabled, value snapped to the
-- nearest allowed option). Profiles with NULL get no row and so the defaults
-- (enabled, 60 min) — per the 5E spec.
--
-- Snapping: nearest allowed value by absolute distance; on a tie the LARGER value wins
-- (e.g. 45 → 60, 75 → 90, 105 → 120), i.e. a tie errs toward fewer nudges. Below 15 →
-- 15, above 120 → 120.
--
-- Preview before running:
--   select user_id, session_timeout_minutes from public.profile
--   where session_timeout_minutes is not null;
-- ------------------------------------------------------------
insert into public.nudge_settings (user_id, session_timeout_enabled, session_timeout_minutes)
select
  p.user_id,
  true,
  (
    select allowed.minutes
    from unnest(array[15, 30, 60, 90, 120]) as allowed(minutes)
    order by abs(allowed.minutes - p.session_timeout_minutes), allowed.minutes desc
    limit 1
  )
from public.profile p
where p.session_timeout_minutes is not null
on conflict (user_id) do nothing;

comment on column public.profile.session_timeout_minutes is
  'DEPRECATED (migration 008): superseded by nudge_settings.session_timeout_*; no longer read by the app. Drop in a later cleanup migration.';
