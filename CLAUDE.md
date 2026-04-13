# Nudge — Claude Instructions

## Start of every session

Read these two files before doing anything:

1. `docs/STATUS.md` — current phase, what's done, what's blocked, open decisions
2. `docs/decisions.md` — settled architectural decisions (do not re-litigate these unless you see a major flaw that needs to be addressed)

Then read the spec for whichever phase is active:
- `docs/specs/phase-1-devactivity.md`
- `docs/specs/phase-2-dashboard.md`
- `docs/specs/phase-3-goals.md`
- `docs/specs/phase-4-notifications.md`
- `docs/specs/phase-5-social.md`

Reference docs (read only when relevant):
- `docs/architecture.md` — MVVM structure, folder layout, key patterns
- `docs/conventions.md` — Swift/SwiftUI code patterns, async/error handling, button style, spacing
- `docs/database.md` — schema reference and timezone rules
- `docs/auth.md` — auth flow and onboarding sequence
- `docs/entitlements.md` — required entitlements and permission request flow

## End of every session

Update `docs/STATUS.md`, `docs/decisions.md`, `docs/ProgressLog.md`, and any other relevant documentation to reflect what was completed, what's in progress, and any new blockers or open decisions discovered. Add bugs and future feature ideas to `docs/backlog.md`.
