import Foundation

/// Read side of `GoalProgressStore` for the Goals UI, behind a protocol so ViewModels
/// are tested without the App Group.
protocol GoalProgressReading {
    /// `{goalId: highestPercent}` recorded by the monitor extension for today's local day.
    func todayProgress() -> [Int: Int]
}

struct AppGroupGoalProgressReader: GoalProgressReading {
    func todayProgress() -> [Int: Int] {
        guard let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName) else { return [:] }
        return GoalProgressStore(defaults: defaults).progress(now: Date(), calendar: .current)
    }
}
