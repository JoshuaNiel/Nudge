-- ============================================================
-- Migration 006c: enable Supabase Realtime on public.friend
--
-- Phase 5I — the Friends list subscribes to Postgres Changes
-- (INSERT + UPDATE, filtered by user_id) while it is on screen, so a
-- new contact appears and a consent reply (pending -> accepted, or
-- STOP -> blocked) or a rename shows without a manual refresh.
-- DELETE is deliberately not subscribed (see Security below).
--
-- Run in the Supabase SQL editor. Independent of every other migration
-- (including 006 / 006b): it only adds a table to the publication, so
-- the 006-series migrations may be run in any order.
--
-- Idempotent: safe to re-run; skips the ALTER if the table is already
-- in the publication.
--
-- Security: no policy is added or widened. Realtime Postgres Changes
-- evaluates the existing RLS select policy ("Users can read their own
-- friend contacts" — friend.user_id must be auth.uid()) as the
-- subscribing user, so each user only receives events for their own
-- friend rows. The client-side user_id filter only narrows that
-- further; it is not the security boundary. Realtime cannot apply RLS
-- to DELETE events, which is why the app never subscribes to them —
-- declines / deletions made elsewhere appear on the next fetch.
-- ============================================================

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname    = 'supabase_realtime'
      and schemaname = 'public'
      and tablename  = 'friend'
  ) then
    alter publication supabase_realtime add table public.friend;
  end if;
end
$$;

-- Verify:
--   select * from pg_publication_tables
--   where pubname = 'supabase_realtime' and tablename = 'friend';
