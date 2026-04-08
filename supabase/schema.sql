-- ============================================================
-- Nudge — Full Database Schema
-- Run this in the Supabase SQL editor (in order).
-- ============================================================


-- ============================================================
-- ENUM TYPES
-- ============================================================

create type goal_frequency   as enum ('daily', 'weekly', 'monthly');
create type goal_target_type as enum ('app', 'category', 'total');
create type friend_status    as enum ('pending', 'accepted', 'blocked');
create type nudge_type       as enum ('shame', 'encouragement', 'custom');
create type nudge_status     as enum ('sent_to_friend', 'replied', 'reply_delivered', 'failed');


-- ============================================================
-- TABLES
-- ============================================================

-- Global app registry. Populated by the usage sync pipeline, not by users directly.
create table public.app (
  bundle_id varchar(255) primary key,
  name      varchar(100) not null
);

-- Extends auth.users with user-specific settings.
create table public.profile (
  user_id               uuid primary key references auth.users(id) on delete cascade,
  first_name            varchar(100),
  last_name             varchar(100),
  phone_number          varchar(16) unique,
  week_start            int              not null default 0,  -- 0 = Sunday, 1 = Monday, etc.
  time_zone             varchar(64),                         -- IANA timezone string e.g. 'America/Denver'
  settings_location_lat double precision,
  settings_location_lon double precision,

  constraint profile_phone_number_e164          check (phone_number ~ '^\+[1-9]\d{7,14}$'),
  constraint profile_week_start_range           check (week_start between 0 and 6),
  constraint profile_location_lat_range         check (settings_location_lat between -90 and 90),
  constraint profile_location_lon_range         check (settings_location_lon between -180 and 180),
  constraint profile_location_both_or_neither   check ((settings_location_lat is null) = (settings_location_lon is null))
);

-- User-defined custom app categories (separate from Apple's built-in categories).
create table public.app_category (
  id      bigint generated always as identity primary key,
  user_id uuid    not null references auth.users(id) on delete cascade,
  name    varchar(100) not null,
  color   varchar(7)   not null,

  constraint app_category_color_hex   check (color ~ '^#[0-9A-Fa-f]{6}$'),
  constraint app_category_unique_name unique (user_id, name)
);

-- Join table: many-to-many between apps and user-defined categories.
create table public.app_category_member (
  bundle_id   varchar(255) not null references public.app(bundle_id) on delete cascade,
  category_id bigint  not null references public.app_category(id) on delete cascade,
  primary key (bundle_id, category_id)
);

-- Daily usage snapshots synced from Apple's DeviceActivity.
-- This is the core data pipeline — the source of truth for all charts and insights.
-- date is a local calendar date in the user's timezone, not UTC.
create table public.usage (
  id      bigint  generated always as identity primary key,
  user_id uuid    not null references auth.users(id) on delete cascade,
  date    date    not null,
  app_id  varchar(255) not null references public.app(bundle_id) on delete restrict,
  seconds bigint  not null default 0,
  pickups bigint  not null default 0,
  unique (user_id, date, app_id),  -- one row per user per app per day

  constraint usage_seconds_non_negative check (seconds >= 0),
  constraint usage_pickups_non_negative check (pickups >= 0)
);

-- Time limit goals, scoped to an app, category, or total usage.
create table public.goal (
  id            bigint           generated always as identity primary key,
  user_id       uuid             not null references auth.users(id) on delete cascade,
  limit_seconds bigint           not null,
  frequency     goal_frequency   not null,
  target_type   goal_target_type not null,
  bundle_id     varchar(255)     references public.app(bundle_id) on delete cascade,
  category_id   bigint           references public.app_category(id) on delete cascade,
  temporary     boolean          not null default false,
  start_date     date,
  end_date       date,

  constraint goal_limit_seconds_positive check (limit_seconds > 0),

  -- Exactly one target must be set, matching target_type.
  constraint goal_target_check check (
    (target_type = 'app'      and bundle_id   is not null and category_id is null) or
    (target_type = 'category' and category_id is not null and bundle_id   is null) or
    (target_type = 'total'    and bundle_id   is null     and category_id is null)
  ),

  -- start/end dates are required when temporary = true, forbidden otherwise.
  constraint goal_temporary_check check (
    (temporary = true  and start_date is not null and end_date is not null) or
    (temporary = false and start_date is null     and end_date is null    )
  ),

  constraint goal_date_order check (end_date >= start_date)
);

-- Motivational reminders tied to a user (not to specific goals).
-- A random reminder is selected when sending threshold notifications.
create table public.why_reminder (
  id      bigint  generated always as identity primary key,
  user_id uuid    not null references auth.users(id) on delete cascade,
  message varchar(500) not null
);

-- SMS-based friend contacts. Friends do not need the app installed.
-- When added, a consent SMS is sent. status tracks the consent state.
-- timestamp records when the consent SMS was sent.
create table public.friend (
  id                    bigint        generated always as identity primary key,
  user_id               uuid          not null references auth.users(id) on delete cascade,
  friend_name           varchar(100)  not null,
  friend_phone_number   varchar(16)   not null,
  status                friend_status not null default 'pending',
  invitation_timestamp  timestamptz   not null default now(),
  unique (user_id, friend_phone_number),  -- one contact per phone number per user

  constraint friend_phone_number_e164 check (friend_phone_number ~ '^\+[1-9]\d{7,14}$')
);

-- SMS nudges sent to friends and their replies.
-- The app user is reachable via friend.user_id — no direct user_id column needed.
-- Inbound replies are written by the receive-reply Edge Function via service role.
create table public.nudge (
  id           bigint       generated always as identity primary key,
  friend_id    bigint       not null references public.friend(id) on delete cascade,
  prompt       varchar(500) not null,  -- message options sent to the friend
  friend_reply varchar(500),           -- friend's reply text, populated by Twilio webhook
  type         nudge_type   not null,
  status       nudge_status not null default 'sent_to_friend',
  sent_timestamp    timestamptz  not null default now()
);


-- ============================================================
-- INDEXES
-- ============================================================

-- Usage queries are almost always scoped to a user + date range.
create index usage_user_date_idx on public.usage(user_id, date desc);

-- app_category_member: composite PK covers bundle_id-first lookups; category_id index covers category-first lookups.
create index app_category_member_category_idx on public.app_category_member(category_id);

-- Goals and reminders queried by user.
create index goal_user_idx     on public.goal(user_id);

-- Prevent duplicate non-temporary goals for the same target and frequency.
-- Temporary goals are excluded — they have date ranges and can coexist with permanent goals.
-- Three separate indexes are required because PostgreSQL treats NULL != NULL in unique indexes,
-- so a single index on (bundle_id, category_id) would not enforce uniqueness for total-type goals
-- where both columns are NULL.
create unique index goal_unique_active_total
  on public.goal(user_id, frequency)
  where temporary = false and target_type = 'total';

create unique index goal_unique_active_app
  on public.goal(user_id, bundle_id, frequency)
  where temporary = false and target_type = 'app';

create unique index goal_unique_active_category
  on public.goal(user_id, category_id, frequency)
  where temporary = false and target_type = 'category';
create index reminder_user_idx on public.why_reminder(user_id);

-- Friend list is queried by user; phone number is used for inbound webhook routing.
create index friend_user_idx   on public.friend(user_id);
create index friend_phone_idx  on public.friend(friend_phone_number);

-- Nudge history is queried by friend.
create index nudge_friend_idx  on public.nudge(friend_id);


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table public.profile              enable row level security;
alter table public.app                  enable row level security;
alter table public.app_category         enable row level security;
alter table public.app_category_member  enable row level security;
alter table public.usage                enable row level security;
alter table public.goal                 enable row level security;
alter table public.why_reminder         enable row level security;
alter table public.friend               enable row level security;
alter table public.nudge                enable row level security;

alter table public.profile              force row level security;
alter table public.app                  force row level security;
alter table public.app_category         force row level security;
alter table public.app_category_member  force row level security;
alter table public.usage                force row level security;
alter table public.goal                 force row level security;
alter table public.why_reminder         force row level security;
alter table public.friend               force row level security;
alter table public.nudge                force row level security;


-- ============================================================
-- RLS POLICIES
-- ============================================================

-- profile
create policy "Users can manage their own profile"
  on public.profile for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- app: read-only for all authenticated users; no user-facing writes
-- (rows are inserted by the usage sync pipeline via service role)
create policy "Authenticated users can read apps"
  on public.app for select
  to authenticated
  using (true);

-- app_category
create policy "Users can manage their own categories"
  on public.app_category for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- app_category_member: access is gated through category ownership
create policy "Users can manage their own category member"
  on public.app_category_member for all
  to authenticated
  using (
    exists (
      select 1 from public.app_category
      where id = app_category_member.category_id
        and user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.app_category
      where id = app_category_member.category_id
        and user_id = (select auth.uid())
    )
  );

-- usage
create policy "Users can read their own usage"
  on public.usage for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- goal
create policy "Users can manage their own goals"
  on public.goal for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- why_reminder
create policy "Users can manage their own reminders"
  on public.why_reminder for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- friend
-- Update is restricted to friend_name only via column-level grant (see below).
-- Changing friend_phone_number requires delete and re-add — a new number invalidates existing consent.
-- status is managed exclusively by Edge Functions via service role:
--     - send-consent  → sets status = 'accepted' or deletes the row on rejection
--     - receive-reply → sets status = 'blocked' on Twilio STOP
-- Any status update made directly by the client would be a security violation.
create policy "Users can update their own friend contacts"
  on public.friend for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users can insert their own friend contacts"
  on public.friend for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users can delete their own friend contacts"
  on public.friend for delete
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can read their own friend contacts"
  on public.friend for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- nudge: no direct user_id — gate through friend ownership.
-- No insert policy is intentional:
--   Nudges are created exclusively by the send-nudge Edge Function (service role),
--   which validates friend status = 'accepted' before inserting.
--   Direct client inserts would bypass that check and are intentionally blocked.
-- No update/delete policy is intentional:
--   friend_reply and status are written by the receive-reply Edge Function (service role).
create policy "Users can read their own nudges"
  on public.nudge for select
  to authenticated
  using (
    exists (
      select 1 from public.friend
      where friend.id = nudge.friend_id
        and friend.user_id = (select auth.uid())
    )
  );

-- No update, insert, or delete on nudges — replies are written by the Edge Function via service role.


-- ============================================================
-- COLUMN-LEVEL GRANTS
-- ============================================================

-- Revoke broad UPDATE on friend, then re-grant only friend_name.
-- Changing phone number requires delete and re-add (invalidates consent).
-- status is managed exclusively by Edge Functions via service role.
revoke update on public.friend from authenticated;
grant update (friend_name) on public.friend to authenticated;


-- ============================================================
-- TRIGGERS
-- ============================================================

-- Enforce that new friend contacts must always start with status = pending.
-- status transitions (accepted, blocked) are handled exclusively by Edge Functions.
create or replace function enforce_friend_status_on_insert()
returns trigger as $$
begin
  if new.status <> 'pending' then
    raise exception 'New friend contacts must have status = pending';
  end if;
  return new;
end;
$$ language plpgsql set search_path = '';

create trigger friend_status_insert_check
  before insert on public.friend
  for each row execute procedure enforce_friend_status_on_insert();


-- Auto-create a profile row when a new user signs up.
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profile (user_id)
  values (new.id);
  return new;
end;
$$ language plpgsql security definer set search_path = '';

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();
