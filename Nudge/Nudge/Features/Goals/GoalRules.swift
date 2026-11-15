import Foundation
import FamilyControls

// Pure rules behind the Goals UI (Phase 3b). Kept out of views and ViewModels so each
// rule is unit-tested directly (NudgeTests/GoalsUITests.swift).

// MARK: - Target validation

enum GoalTargetValidation {

    /// `goal.label` is `varchar(100)`.
    static let labelMaxLength = 100

    /// An app goal monitors exactly one application token (G1). Categories and web
    /// domains are rejected rather than silently dropped, so what the user picked is
    /// exactly what gets monitored.
    static func appSelectionError(applicationCount: Int, categoryCount: Int, webDomainCount: Int) -> String? {
        if categoryCount > 0 || webDomainCount > 0 { return "Choose a single app, not a category or website." }
        if applicationCount == 0 { return "Choose an app." }
        if applicationCount > 1 { return "Choose only one app." }
        return nil
    }

    static func appSelectionError(for selection: FamilyActivitySelection) -> String? {
        appSelectionError(
            applicationCount: selection.applicationTokens.count,
            categoryCount: selection.categoryTokens.count,
            webDomainCount: selection.webDomainTokens.count
        )
    }

    static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// App goals need a typed name (G2): tokens have no readable name outside a SwiftUI
    /// `Label`, and SMS nudges need a string.
    static func labelError(_ label: String) -> String? {
        let trimmed = normalizedLabel(label)
        if trimmed.isEmpty { return "Enter a name for this app." }
        if trimmed.count > labelMaxLength { return "Name must be 100 characters or fewer." }
        return nil
    }
}

// MARK: - Limit

enum GoalLimit {
    static let minimumSeconds = 5 * 60
    /// A daily limit must fit inside the day: 23h 59m.
    static let maximumSeconds = 23 * 3600 + 59 * 60

    static func seconds(hours: Int, minutes: Int) -> Int {
        hours * 3600 + minutes * 60
    }

    static func error(hours: Int, minutes: Int) -> String? {
        guard hours >= 0, (0..<60).contains(minutes) else { return "Enter a valid limit." }
        let total = seconds(hours: hours, minutes: minutes)
        if total < minimumSeconds { return "Limit must be at least 5 minutes." }
        if total > maximumSeconds { return "Limit can't be more than 23h 59m." }
        return nil
    }
}

// MARK: - Temporary date range

enum GoalDateRange {

    /// Compared by local calendar day: any time today is a valid start.
    static func error(start: Date, end: Date, today: Date, calendar: Calendar) -> String? {
        let startDay = calendar.startOfDay(for: start)
        if startDay < calendar.startOfDay(for: today) { return "Start date can't be in the past." }
        if calendar.startOfDay(for: end) < startDay { return "End date must be on or after the start date." }
        return nil
    }

    /// `yyyy-MM-dd` strings for `goal.start_date` / `end_date`, using the same
    /// locale-independent stamp `MonitoringPlan` filters on (G7).
    static func dayStrings(start: Date, end: Date, calendar: Calendar) -> (start: String, end: String) {
        (MonitoringPlan.dayStamp(for: start, calendar: calendar),
         MonitoringPlan.dayStamp(for: end, calendar: calendar))
    }

    /// "Nov 14 – Nov 21" for display, or `nil` when either stamp is malformed.
    static func displayText(start: String, end: String, calendar: Calendar, locale: Locale) -> String? {
        guard let startDate = date(fromDayStamp: start, calendar: calendar),
              let endDate = date(fromDayStamp: end, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }

    static func date(fromDayStamp stamp: String, calendar: Calendar) -> Date? {
        let parts = stamp.split(separator: "-")
        guard parts.count == 3, stamp.count == 10,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        guard let date = calendar.date(from: components),
              MonitoringPlan.dayStamp(for: date, calendar: calendar) == stamp else { return nil }
        return date
    }
}

// MARK: - Progress display

/// The 10%-step milestone bar (G3/G4): the app only knows the highest milestone the
/// monitor extension recorded today, never the exact number.
enum GoalProgressDisplay {
    static let stepCount = 10

    static func filledSteps(percent: Int?) -> Int {
        guard let percent else { return 0 }
        return min(stepCount, max(0, percent / (100 / stepCount)))
    }

    static func caption(percent: Int?) -> String {
        let percent = percent ?? 0
        if percent >= 100 { return "Limit reached" }
        if percent < 10 { return "Under 10%" }
        return "≈ \(percent)% used"
    }
}

// MARK: - Display

enum GoalDisplay {
    /// Goals are daily only in the UI (G6), so the unit is always "day".
    static func limitText(seconds: Int) -> String {
        "\(seconds.formattedDuration) / day"
    }
}
