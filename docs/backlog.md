# Backlog

Parking lot for future features and known bugs. Nothing here is actively scheduled — move items into a phase spec when they become real work.

---

## Future Features

- **Mac sync** — sync usage data and goals across Mac using the same Supabase backend
- **WidgetKit** — home/lock screen widget showing today's total usage or goal progress
- **App blocking** — hard-block apps when a goal limit is hit (requires ManagedSettings entitlement, separate Apple approval)
- **Location-based settings lock** — lock app settings when the user is at a specified location (e.g. work); implemented via CoreLocation check when settings screen opens
- **Notification customization** — let users configure why reminder frequency and time of day

---

## Known Bugs / Tech Debt

- **Email confirmation deep link not wired up** — Supabase sends a `localhost` confirmation URL. Fix: register `nudge://` URL scheme, set Site URL + Redirect URLs in Supabase dashboard, handle `.onOpenURL` in `NudgeApp.swift` calling `supabase.auth.session(from: url)`. Email confirmation is currently disabled in Supabase for development.
- **`AppUsage.swift` and `Goal.swift` models don't match DB schema** — written before the schema was finalized. Fix tracked in phase-2 and phase-3 specs respectively.
