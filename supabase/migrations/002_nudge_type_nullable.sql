-- ============================================================
-- Migration 002: make nudge.type nullable
--
-- NudgeType is determined by the friend's reply (encouragement/shame/custom).
-- Before the friend responds the type is unknown, so NOT NULL is incorrect.
-- Run in Supabase SQL editor after 001_device_tokens.sql.
-- ============================================================

alter table public.nudge alter column type drop not null;
