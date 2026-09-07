-- Prevent blank (empty/whitespace-only) first/last names on profile.
-- Columns remain nullable (the signup trigger inserts a row with null names),
-- but a set value must contain non-whitespace characters.

-- 1. Normalize any existing blank names to NULL so the constraint can be added,
--    and so the app treats them as "unset" (Settings requires a non-blank name).
update public.profile set first_name = null where first_name is not null and btrim(first_name) = '';
update public.profile set last_name  = null where last_name  is not null and btrim(last_name)  = '';

-- 2. Add the CHECK constraints (idempotent: drop first so this is safe to re-run).
alter table public.profile drop constraint if exists profile_first_name_not_blank;
alter table public.profile drop constraint if exists profile_last_name_not_blank;

alter table public.profile
  add constraint profile_first_name_not_blank
    check (first_name is null or char_length(btrim(first_name)) > 0),
  add constraint profile_last_name_not_blank
    check (last_name is null or char_length(btrim(last_name)) > 0);
