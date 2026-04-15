-- Phase 1: Add session_timeout_minutes to profile
--
-- NULL  = session timeout nudge is disabled for this user.
-- Value = send a nudge after the user has accumulated N minutes of phone use today.
--
-- Exposed in Settings so the user can configure or disable it.
-- Read by MonitoringRegistrationService to register the session.timeout DeviceActivityEvent.

ALTER TABLE public.profile
  ADD COLUMN session_timeout_minutes integer
  CONSTRAINT session_timeout_minutes_positive
    CHECK (session_timeout_minutes IS NULL OR session_timeout_minutes > 0);
