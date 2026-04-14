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

## Spec-first development

**Never implement a feature without a complete spec.** If asked to implement something and the spec is missing or not fleshed out:

1. Stop — do not guess at requirements or begin coding.
2. Ask the user the clarifying questions needed to fully define the feature (data model, business rules, edge cases, UI behavior, acceptance criteria).
3. Write or update the spec in `docs/specs/` until it is complete enough to implement from.
4. Get confirmation from the user that the spec is correct before writing any code.

A spec is complete when it defines: what data is stored/read, what the user sees and does, all edge cases and error states, and what "done" looks like.

---

## Test-driven development (TDD)

For every new feature: **write tests first, then implement.**

1. Add `@Suite` + `@Test` cases to `NudgeTests/NudgeTests.swift` covering the new contracts (model coding, business logic, computed properties, enum raw values).
2. Run the test suite — new tests must fail before implementation.
3. Implement until all tests pass.
4. Run again to confirm no regressions.

Run the full test suite:
```bash
xcodebuild test \
  -project Nudge.xcodeproj \
  -scheme Nudge \
  -destination 'platform=iOS Simulator,arch=arm64,id=19C7BD9B-6973-4F63-8492-C8D13401B835'
```

See `docs/conventions.md` → Testing section for test file conventions.

## Code quality

After writing or editing any Swift code, check the diagnostics reported by the IDE. If there are build errors (not SourceKit indexing errors), fix them before considering the task done. Iterate until there are zero build errors.

**Distinguishing real errors from stale SourceKit errors:**
Stale SourceKit errors look like "Cannot find type 'X' in scope" or "Cannot find 'supabase' in scope" immediately after creating new files — these resolve automatically when Xcode re-indexes and are not real build errors. Real build errors persist after indexing and reference logic issues (type mismatches, missing arguments, protocol conformance failures, etc.). When in doubt, note the ambiguity to the user rather than ignoring all errors.

## End of every session

Update `docs/STATUS.md`, `docs/decisions.md`, `docs/ProgressLog.md`, and any other relevant documentation to reflect what was completed, what's in progress, and any new blockers or open decisions discovered. Add bugs and future feature ideas to `docs/backlog.md`.
