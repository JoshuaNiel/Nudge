-- Prevent blank (empty/whitespace-only) first/last names on profile.
-- Columns remain nullable (signup trigger inserts a row with null names),
-- but a set value must contain non-whitespace characters.
alter table public.profile
  add constraint profile_first_name_not_blank
    check (first_name is null or char_length(btrim(first_name)) > 0),
  add constraint profile_last_name_not_blank
    check (last_name is null or char_length(btrim(last_name)) > 0);
