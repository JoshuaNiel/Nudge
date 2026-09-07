-- Forbid blank (empty/whitespace-only) values in user-entered required text columns.
-- These columns are already NOT NULL, but NOT NULL does not stop '' — a CHECK does.
-- (Regex-constrained columns like phone numbers and hex colors already forbid blanks.)
--
-- If any ADD CONSTRAINT below fails, an existing row holds a blank value. Find offenders:
--   select id, friend_name from public.friend        where btrim(friend_name) = '';
--   select id, name        from public.app_category   where btrim(name)        = '';
--   select id, message     from public.why_reminder   where btrim(message)     = '';
--   select id              from public.device_tokens  where btrim(token)       = '';
-- Fix or delete those rows, then re-run (constraints are dropped-if-exists, so it's safe to repeat).

alter table public.friend         drop constraint if exists friend_name_not_blank;
alter table public.app_category   drop constraint if exists app_category_name_not_blank;
alter table public.why_reminder   drop constraint if exists why_reminder_message_not_blank;
alter table public.device_tokens  drop constraint if exists device_tokens_token_not_blank;

alter table public.friend
  add constraint friend_name_not_blank check (char_length(btrim(friend_name)) > 0);

alter table public.app_category
  add constraint app_category_name_not_blank check (char_length(btrim(name)) > 0);

alter table public.why_reminder
  add constraint why_reminder_message_not_blank check (char_length(btrim(message)) > 0);

alter table public.device_tokens
  add constraint device_tokens_token_not_blank check (char_length(btrim(token)) > 0);
