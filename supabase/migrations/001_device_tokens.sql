-- ============================================================
-- Migration 001: device_tokens table
-- Run in Supabase SQL editor after schema.sql
-- ============================================================

-- Stores APNs device tokens for push notification delivery.
-- One user may have multiple devices. Tokens are upserted on
-- each app launch so stale tokens are automatically refreshed.
create table public.device_tokens (
  id         bigint      generated always as identity primary key,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  token      text        not null,
  platform   text        not null default 'apns',
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);

-- Index: fetch tokens by user (for push delivery)
create index device_tokens_user_idx on public.device_tokens(user_id);

-- RLS
alter table public.device_tokens enable row level security;
alter table public.device_tokens force row level security;

-- Users can manage their own device tokens
create policy "Users can manage their own device tokens"
  on public.device_tokens for all
  to authenticated
  using  ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
