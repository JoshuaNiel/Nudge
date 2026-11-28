-- ============================================================
-- Migration 009: onboarding progress stored on the account
--
-- docs/specs/onboarding-progress.md §2. Replaces the device-local
-- "onboardingComplete" flag, so a returning user on a new device or a
-- reinstall is not sent through onboarding again.
--
-- 1. profile.onboarding_completed  — set to true by the app (a normal
--    update under the existing "Users can manage their own profile"
--    policy) when the user finishes onboarding. The app never sends false.
-- 2. Backfill — existing users who already finished profile setup (both
--    names set) are marked completed, so no one is sent back.
-- 3. public.onboarding_status() — the caller's own progress:
--      { "completed": bool, "next_step": "profile" | null }
--    next_step is the first account step not yet satisfied, in order.
--    Today the only step is "profile" (first_name and last_name both
--    non-blank). Future steps are added to this function, in order; a step
--    added later does NOT send users with completed = true back into
--    onboarding (the app checks `completed` first).
--
-- Numbered 009 because 006–008 are reserved by open PRs. Independent of
-- them; may be run in any order.
--
-- Idempotent: safe to re-run (add column if not exists, the backfill only
-- ever sets true, create or replace function, grants are repeatable).
--
-- Security: security invoker + auth.uid(), so the existing profile RLS
-- policy applies and a caller only ever reads their own row. Executable by
-- `authenticated` only (revoked from anon / public). search_path is empty;
-- every reference is schema-qualified.
-- ============================================================

alter table public.profile
  add column if not exists onboarding_completed boolean not null default false;

update public.profile
set onboarding_completed = true
where onboarding_completed = false
  and nullif(btrim(first_name), '') is not null
  and nullif(btrim(last_name), '') is not null;

-- Left join from auth.uid() so a caller with no profile row still gets a
-- well-formed answer ({ completed: false, next_step: "profile" }) instead of NULL.
create or replace function public.onboarding_status()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'completed', coalesce(p.onboarding_completed, false),
    'next_step',
      case
        when nullif(btrim(p.first_name), '') is null
          or nullif(btrim(p.last_name), '') is null
          then 'profile'
        else null
      end
  )
  from (select auth.uid() as uid) as me
  left join public.profile as p on p.user_id = me.uid;
$$;

revoke all on function public.onboarding_status() from public;
revoke all on function public.onboarding_status() from anon;
grant execute on function public.onboarding_status() to authenticated;

-- ------------------------------------------------------------
-- Verify (run in the SQL editor after the migration):
--
-- 1. Column exists, not null, default false:
--   select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema = 'public' and table_name = 'profile'
--     and column_name = 'onboarding_completed';
--
-- 2. Backfill: no one with both names is left incomplete (expect 0):
--   select count(*) from public.profile
--   where onboarding_completed = false
--     and nullif(btrim(first_name), '') is not null
--     and nullif(btrim(last_name), '') is not null;
--
-- 3. Grants: authenticated can execute, anon cannot (expect true, false):
--   select has_function_privilege('authenticated', 'public.onboarding_status()', 'execute'),
--          has_function_privilege('anon', 'public.onboarding_status()', 'execute');
--
-- 4. The function's answers. auth.uid() reads the request's JWT claims, so
--    impersonate a user inside a transaction (replace <user-id> with a real
--    profile.user_id; rolled back, nothing is changed):
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', '{"sub":"<user-id>","role":"authenticated"}', true);
--
--   -- no names       → {"completed": false, "next_step": "profile"}
--   update public.profile set first_name = null, last_name = null, onboarding_completed = false
--     where user_id = auth.uid();
--   select public.onboarding_status();
--
--   -- one name       → {"completed": false, "next_step": "profile"}
--   update public.profile set first_name = 'Ada' where user_id = auth.uid();
--   select public.onboarding_status();
--
--   -- both names     → {"completed": false, "next_step": null}
--   update public.profile set last_name = 'Lovelace' where user_id = auth.uid();
--   select public.onboarding_status();
--
--   -- completed      → {"completed": true, "next_step": null}
--   update public.profile set onboarding_completed = true where user_id = auth.uid();
--   select public.onboarding_status();
--
--   rollback;
--
-- 5. Anonymous callers are refused (expect "permission denied for function"):
--   begin; set local role anon; select public.onboarding_status(); rollback;
-- ------------------------------------------------------------
