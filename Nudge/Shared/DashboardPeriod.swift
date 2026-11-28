import Foundation

// MARK: - Dashboard Day | Week navigation (Phase 2 v2)
//
// Pure date math behind the dashboard's Day | Week control, date navigator and date picker
// (docs/specs/phase-2-dashboard.md V2, V3). The host builds the report's filter from it; the
// calendar, "today" and the week's first day are injected so DST, month and year boundaries
// are unit testable. Day-level rules are `DashboardDay`'s and are reused unchanged.

/// The dashboard's period length (V2). Kept while the app runs; not persisted.
enum DashboardMode: Hashable, CaseIterable {
    case day
    case week

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        }
    }
}

/// The selected day or week.
struct DashboardPeriod: Hashable {
    let mode: DashboardMode
    /// Start of the day (Day mode) or of the week's first day (Week mode).
    let start: Date
}

/// Day and week math for the dashboard, for one `today`. Cheap to create; build a fresh one
/// per use so "today" stays current across midnight.
struct DashboardCalendar {

    /// Weeks run Sunday–Saturday for now (V2). Calendar weekday numbering: 1 = Sunday. A
    /// user-chosen week start (backlog) only needs to pass a different `firstWeekday`.
    static let defaultFirstWeekday = 1

    let calendar: Calendar
    let today: Date
    let firstWeekday: Int

    init(calendar: Calendar, today: Date) {
        self.init(calendar: calendar, today: today, firstWeekday: Self.defaultFirstWeekday)
    }

    init(calendar: Calendar, today: Date, firstWeekday: Int) {
        self.calendar = calendar
        self.today = today
        self.firstWeekday = firstWeekday
    }

    // MARK: Weeks

    /// Start of the first day of the week containing `date`.
    func weekStart(containing date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysIntoWeek = (weekday - firstWeekday + 7) % 7
        return addingDays(-daysIntoWeek, to: day)
    }

    /// The period of `mode` containing `date`, clamped to the selectable range.
    func period(containing date: Date, mode: DashboardMode) -> DashboardPeriod {
        switch mode {
        case .day:
            DashboardPeriod(mode: .day, start: DashboardDay.clamp(date, today: today, calendar: calendar))
        case .week:
            // Clamping the day first keeps the result within the reachable weeks (V3: a week is
            // reachable if any of its days is in range).
            DashboardPeriod(mode: .week, start: weekStart(containing: DashboardDay.clamp(date, today: today, calendar: calendar)))
        }
    }

    /// Normalizes `period` to its day or week start and clamps it into range.
    func clamp(_ period: DashboardPeriod) -> DashboardPeriod {
        self.period(containing: period.start, mode: period.mode)
    }

    // MARK: Filter

    /// The `DeviceActivityFilter` interval (V2), split into daily segments. Day: the whole local
    /// day. Week: the whole week, first day 00:00 to the next week's first day 00:00 — also for
    /// the current week. It is deliberately not clipped at today: a clipped week on its first
    /// day would equal that day's range, and the extension tells Day from Week by the range's
    /// length (`UsageReportScope`). Future days simply have no usage. Never zero-length (ADR-045).
    func filterInterval(for period: DashboardPeriod) -> DateInterval {
        switch period.mode {
        case .day:
            return DashboardDay.filterInterval(for: period.start, calendar: calendar)
        case .week:
            let start = weekStart(containing: period.start)
            return DateInterval(start: start, end: addingDays(7, to: start))
        }
    }

    // MARK: Title

    /// Day: "Today", "Yesterday", "Nov 25". Week: always a date range (V3) — "Nov 15 – 21",
    /// "Oct 26 – Nov 1", "Dec 27 – Jan 2"; the year is never shown.
    func title(for period: DashboardPeriod, locale: Locale) -> String {
        switch period.mode {
        case .day:
            return DashboardDay.title(for: period.start, today: today, calendar: calendar, locale: locale)
        case .week:
            let start = weekStart(containing: period.start)
            let end = addingDays(6, to: start)
            let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            let endText = format(end, template: sameMonth ? "d" : "MMMd", locale: locale)
            return "\(format(start, template: "MMMd", locale: locale)) – \(endText)"
        }
    }

    // MARK: Stepping

    /// Moves `count` days or weeks, clamped to the selectable range.
    func step(_ period: DashboardPeriod, by count: Int) -> DashboardPeriod {
        let daysPerStep = period.mode == .week ? 7 : 1
        let start = clamp(period).start
        return clamp(DashboardPeriod(mode: period.mode, start: addingDays(count * daysPerStep, to: start)))
    }

    func canStepBack(_ period: DashboardPeriod) -> Bool {
        let current = clamp(period).start
        switch period.mode {
        case .day: return DashboardDay.canStepBack(from: current, today: today, calendar: calendar)
        case .week: return current > weekStart(containing: earliestDay)
        }
    }

    /// False on today (Day) or the current week (Week).
    func canStepForward(_ period: DashboardPeriod) -> Bool {
        let current = clamp(period).start
        switch period.mode {
        case .day: return DashboardDay.canStepForward(from: current, today: today, calendar: calendar)
        case .week: return current < weekStart(containing: today)
        }
    }

    // MARK: Day <-> Week

    /// V2: Day → Week shows the week containing the selected day; Week → Day selects today in
    /// the current week, otherwise the week's last day.
    func switching(_ period: DashboardPeriod, to mode: DashboardMode) -> DashboardPeriod {
        guard period.mode != mode else { return clamp(period) }
        switch mode {
        case .week:
            return self.period(containing: period.start, mode: .week)
        case .day:
            return self.period(containing: representativeDay(ofWeek: period.start), mode: .day)
        }
    }

    // MARK: Date picker

    /// V3: today − 30 … today, through today's last second so any time of day on today is in range.
    var pickerRange: ClosedRange<Date> {
        let endOfToday = DashboardDay.filterInterval(for: today, calendar: calendar).end
        return earliestDay...endOfToday.addingTimeInterval(-1)
    }

    /// The day the picker opens on: the selected day, or in Week mode the day Week → Day would
    /// select (always in the picker's range).
    func pickerSelection(for period: DashboardPeriod) -> Date {
        switch period.mode {
        case .day: clamp(period).start
        case .week: DashboardDay.clamp(representativeDay(ofWeek: period.start), today: today, calendar: calendar)
        }
    }

    /// A picked date selects its day, or its week in Week mode.
    func select(_ date: Date, mode: DashboardMode) -> DashboardPeriod {
        period(containing: date, mode: mode)
    }

    // MARK: Private

    private var earliestDay: Date { DashboardDay.earliestDay(today: today, calendar: calendar) }

    /// Today in the current week, otherwise the week's last day.
    private func representativeDay(ofWeek date: Date) -> Date {
        let start = weekStart(containing: date)
        if start == weekStart(containing: today) { return calendar.startOfDay(for: today) }
        return addingDays(6, to: start)
    }

    /// Calendar days, so DST changes never shift the result off midnight.
    private func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    private func format(_ date: Date, template: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
