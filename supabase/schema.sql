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
create type nudge_type       as enum ('shame', 'encouragement');


-- ============================================================
-- TABLES
-- ============================================================

-- Global app registry. Populated by the usage sync pipeline, not by users directly.
create table public.app (
  bundle_id varchar primary key,
  name      varchar not null
);

-- Extends auth.users with user-specific settings.
create table public.profiles (
  user_id               uuid primary key references auth.users(id) on delete cascade,
  first_name            varchar,
  last_name             varchar,
  week_start            int              not null default 0,  -- 0 = Sunday, 1 = Monday, etc.
  time_zone             varchar,                              -- IANA timezone string e.g. 'America/Denver'
  settings_location_lat double precision,
  settings_location_lon double precision
);

-- User-defined custom app categories (separate from Apple's built-in categories).
create table public.app_category (
  id      bigint generated always as identity primary key,
  user_id uuid    not null references auth.users(id) on delete cascade,
  name    varchar not null,
  color   text    not null
);

-- Join table: many-to-many between apps and user-defined categories.
create table public.app_category_members (
  bundle_id   varchar not null references public.app(bundle_id) on delete cascade,
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
  app_id  varchar not null references public.app(bundle_id) on delete cascade,
  seconds bigint  not null default 0,
  pickups bigint  not null default 0,
  unique (user_id, date, app_id)  -- one row per user per app per day
);

-- Time limit goals, scoped to an app, category, or total usage.
create table public.goal (
  id            bigint           generated always as identity primary key,
  user_id       uuid             not null references auth.users(id) on delete cascade,
  limit_seconds bigint           not null,
  frequency     goal_frequency   not null,
  target_type   goal_target_type not null,
  bundle_id     varchar          references public.app(bundle_id) on delete cascade,
  category_id   bigint           references public.app_category(id) on delete cascade,
  temporary     boolean          not null default false,
  start_time    timestamptz,
  end_time      timestamptz,

  -- Exactly one target must be set, matching target_type.
  constraint goal_target_check check (
    (target_type = 'app'      and bundle_id   is not null and category_id is null    ) or
    (target_type = 'category' and category_id is not null and bundle_id   is null    ) or
    (target_type = 'total'    and bundle_id   is null     and category_id is null    )
  ),

  -- start/end times are required when temporary = true, forbidden otherwise.
  constraint goal_temporary_check check (
    (temporary = true  and start_time is not null and end_time is not null) or
    (temporary = false and start_time is null     and end_time is null    )
  )
);

-- Motivational reminders tied to a user (not to specific goals).
-- A random active reminder is selected when sending threshold notifications.
create table public.why_reminder (
  id      bigint  generated always as identity primary key,
  user_id uuid    not null references auth.users(id) on delete cascade,
  message varchar not null
);

-- Friend connections. Directional at creation (requester → addressee),
-- symmetric once accepted.
create table public.friends (
  requester_id uuid          not null references auth.users(id) on delete cascade,
  addressee_id uuid          not null references auth.users(id) on delete cascade,
  status       friend_status not null default 'pending',
  primary key (requester_id, addressee_id),
  constraint friends_no_self_friend check (requester_id != addressee_id)
);

-- Shame and encouragement messages sent between friends.
create table public.nudges (
  id          bigint      generated always as identity primary key,
  sender_id   uuid        not null references auth.users(id) on delete cascade,
  receiver_id uuid        not null references auth.users(id) on delete cascade,
  message     varchar     not null,
  timestamp   timestamptz not null default now(),
  type        nudge_type  not null
);


-- ============================================================
-- INDEXES
-- ============================================================

-- Usage queries are almost always scoped to a user + date range.
create index usage_user_date_idx on public.usage(user_id, date desc);

-- Goals, reminders queried by user.
create index goal_user_idx        on public.goal(user_id);
create index reminder_user_idx    on public.why_reminder(user_id);

-- Friend requests are often looked up from the addressee's side.
create index friends_addressee_idx on public.friends(addressee_id);

-- Nudge inbox queries hit receiver_id.
create index nudges_receiver_idx on public.nudges(receiver_id);


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table public.profiles             enable row level security;
alter table public.app                  enable row level security;
alter table public.app_category         enable row level security;
alter table public.app_category_members enable row level security;
alter table public.usage                enable row level security;
alter table public.goal                 enable row level security;
alter table public.why_reminder         enable row level security;
alter table public.friends              enable row level security;
alter table public.nudges               enable row level security;


-- ============================================================
-- RLS POLICIES
-- ============================================================

-- profiles
create policy "Users can manage their own profile"
  on public.profiles for all
  using (auth.uid() = user_id);

-- app: read-only for all authenticated users; no user-facing writes
-- (rows are inserted by the usage sync pipeline via service role)
create policy "Authenticated users can read apps"
  on public.app for select
  using (auth.role() = 'authenticated');

-- app_category
create policy "Users can manage their own categories"
  on public.app_category for all
  using (auth.uid() = user_id);

-- app_category_members: access is gated through category ownership
create policy "Users can manage their own category members"
  on public.app_category_members for all
  using (
    exists (
      select 1 from public.app_category
      where id = app_category_members.category_id
        and user_id = auth.uid()
    )
  );

-- usage
create policy "Users can manage their own usage"
  on public.usage for all
  using (auth.uid() = user_id);

-- goal
create policy "Users can manage their own goals"
  on public.goal for all
  using (auth.uid() = user_id);

-- why_reminder
create policy "Users can manage their own reminders"
  on public.why_reminder for all
  using (auth.uid() = user_id);

-- friends: separate policies per operation for fine-grained control
create policy "Users can view their own friend connections"
  on public.friends for select
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create policy "Users can send friend requests"
  on public.friends for insert
  with check (auth.uid() = requester_id);

create policy "Addressee can accept or block a request"
  on public.friends for update
  using (auth.uid() = addressee_id);

create policy "Either party can remove a friend connection"
  on public.friends for delete
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- nudges: separate policies per operation
create policy "Users can read nudges they sent or received"
  on public.nudges for select
  using (auth.uid() = sender_id or auth.uid() = receiver_id);

create policy "Users can send nudges as themselves"
  on public.nudges for insert
  with check (auth.uid() = sender_id);

-- No update or delete on nudges — they are immutable once sent.


-- ============================================================
-- TRIGGERS
-- ============================================================

-- Auto-create a profiles row when a new user signs up.
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (user_id)
  values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();
