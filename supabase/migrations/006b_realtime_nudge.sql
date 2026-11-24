-- ============================================================
-- Migration 006b: enable Supabase Realtime on public.nudge
--
-- Phase 5H — the nudge history screen subscribes to Postgres Changes
-- (INSERT + UPDATE, filtered by friend_id) so a friend's reply
-- (status -> replied -> reply_delivered, type, friend_reply) appears
-- without a manual refresh.
--
-- Run in the Supabase SQL editor. Independent of every other migration
-- (including the other 006): it only adds a table to the publication,
-- so 006 / 006b may be run in either order.
--
-- Idempotent: safe to re-run; skips the ALTER if the table is already
-- in the publication.
--
-- Security: no policy is added or widened. Realtime Postgres Changes
-- evaluates the existing RLS select policy ("Users can read their own
-- nudges" — nudge.friend_id must belong to a friend row whose user_id
-- is auth.uid()) as the subscribing user, so each user only receives
-- events for their own nudges. The client-side friend_id filter only
-- narrows that further; it is not the security boundary.
-- ============================================================

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname    = 'supabase_realtime'
      and schemaname = 'public'
      and tablename  = 'nudge'
  ) then
    alter publication supabase_realtime add table public.nudge;
  end if;
end
$$;

-- Verify:
--   select * from pg_publication_tables
--   where pubname = 'supabase_realtime' and tablename = 'nudge';
