import Foundation
import FamilyControls
import ManagedSettings

/// What a goal limits, as shown in its row.
enum GoalItemTarget: Equatable {
    /// `token` renders the real app name/icon via `Label(token)`; `nil` when the stored
    /// selection could not be decoded.
    case app(label: String, token: ApplicationToken?)
    case category(name: String, colorHex: String)
    case total
}

/// Whether a goal is being monitored today, or why not.
enum GoalItemStatus: Equatable {
    case active
    /// The app/category selection is missing, undecodable (e.g. tokens from another
    /// device) or empty. `MonitoringPlan` skips it; the user must pick again.
    case needsReselect
    /// Weekly/monthly goals from older versions: `MonitoringPlan` skips them (G6).
    case notMonitored
    /// A temporary goal whose date range does not include today (G7).
    case notActiveToday
}

/// One row of the Goals list: a `Goal` resolved against its category, its decoded
/// selection and today's milestone progress. Built by a pure factory so every rule is
/// unit-tested.
struct GoalListItem: Identifiable {
    let goal: Goal
    let target: GoalItemTarget
    let status: GoalItemStatus
    /// The tokens to filter the exact-usage report by: the goal's own (app) or its
    /// category's. `nil` for total goals and for undecodable selections.
    let selection: FamilyActivitySelection?
    /// Highest milestone recorded today; `nil` = none yet (under 10%).
    let percent: Int?

    var id: Int { goal.id }

    var title: String {
        switch target {
        case .app(let label, _): return label
        case .category(let name, _): return name
        case .total: return "All Apps"
        }
    }

    var limitText: String {
        // Never print "/ day" for a goal that isn't daily (G6: no weekly/monthly UI).
        status == .notMonitored ? goal.limitSeconds.formattedDuration : GoalDisplay.limitText(seconds: goal.limitSeconds)
    }

    var caption: String {
        switch status {
        case .active:
            return GoalProgressDisplay.caption(percent: percent)
        case .needsReselect:
            return goal.targetType == .app ? "Re-select app" : "Re-select apps"
        case .notMonitored:
            return "Not monitored"
        case .notActiveToday:
            return "Not active today"
        }
    }

    var filledSteps: Int { GoalProgressDisplay.filledSteps(percent: percent) }

    /// Temporary range for display, e.g. "Nov 14 – Nov 21".
    func dateRangeText(calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard goal.temporary, let start = goal.startDate, let end = goal.endDate else { return nil }
        return GoalDateRange.displayText(start: start, end: end, calendar: calendar, locale: locale)
    }

    // MARK: - Factory

    /// - Parameters:
    ///   - progress: `{goalId: highestPercent}` for today (`GoalProgressStore`). Unknown
    ///     ids (deleted goals) are simply never looked up.
    ///   - today: local `yyyy-MM-dd` (`MonitoringPlan.dayStamp`).
    static func make(goal: Goal, categories: [AppCategory], progress: [Int: Int], today: String) -> GoalListItem {
        let target: GoalItemTarget
        let selection: FamilyActivitySelection?
        var selectionUsable = true

        switch goal.targetType {
        case .app:
            selection = usableSelection(goal.selection)
            selectionUsable = selection != nil
            target = .app(label: goal.label ?? "App", token: selection?.applicationTokens.first)
        case .category:
            let category = categories.first { $0.id == goal.categoryId }
            selection = usableSelection(category?.selection)
            selectionUsable = category != nil && selection != nil
            target = .category(
                name: category?.name ?? "Unknown category",
                colorHex: category?.color ?? CategoryPalette.defaultColor
            )
        case .total:
            selection = nil
            target = .total
        }

        let status: GoalItemStatus
        if !selectionUsable {
            status = .needsReselect
        } else if goal.frequency != .daily {
            status = .notMonitored
        } else if !isInDateRange(goal, today: today) {
            status = .notActiveToday
        } else {
            status = .active
        }

        return GoalListItem(goal: goal, target: target, status: status, selection: selection, percent: progress[goal.id])
    }

    /// Mirrors `MonitoringPlan`'s skip rule: missing, undecodable and empty selections
    /// are all unusable (an empty token set would monitor everything).
    private static func usableSelection(_ base64: String?) -> FamilyActivitySelection? {
        guard let base64, let decoded = SelectionCodec.decode(base64), !SelectionCodec.isEmpty(decoded) else { return nil }
        return decoded
    }

    /// Same inclusive, string-ordered comparison as `MonitoringPlan.isActive`.
    private static func isInDateRange(_ goal: Goal, today: String) -> Bool {
        if let start = goal.startDate, today < start { return false }
        if let end = goal.endDate, today > end { return false }
        return true
    }
}

extension Goal {
    /// A copy with a new app selection (after "Re-select app").
    func withSelection(_ selection: String) -> Goal {
        Goal(
            id: id, userId: userId, limitSeconds: limitSeconds, frequency: frequency,
            targetType: targetType, bundleId: bundleId, categoryId: categoryId,
            temporary: temporary, startDate: startDate, endDate: endDate,
            selection: selection, label: label
        )
    }
}
