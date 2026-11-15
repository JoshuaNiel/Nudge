import Foundation
import os

/// The daily report nudge (Phase 5E-2): yesterday's approximate total screen time,
/// texted to friends at or after the user's chosen time.
///
/// Pipeline (all in the monitor extension, app closed):
/// 1. While the report is on, registration adds the `total.m<NN>` milestones
///    (`MonitoringPlan.registrationEvents`).
/// 2. Each one that fires max-merges into `nudge.dailyTotal.<day>` (`ThresholdRouter`).
/// 3. At `intervalDidStart`, *before* re-registering, `enqueueIfNeeded` queues one
///    `PendingTrigger` about yesterday with `notBefore` = today at the report time.
/// 4. The app's drain sends it once due (`PendingTriggerQueue.partition`).
///
/// Per-app numbers are not available outside the report extension (ADR-049), so the
/// report is total-only, accurate to the 15-minute milestone step.
enum DailyReport {

    /// `PendingTrigger.eventName` of a queued daily report. Not a `DeviceActivity`
    /// event name.
    static let triggerEventName = "daily.report"

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "DailyReport")

    // MARK: - Pure rules

    /// The local day a report generated at `now` is about: yesterday.
    static func reportedDay(now: Date, calendar: Calendar) -> String {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        return MonitoringPlan.dayStamp(for: yesterday, calendar: calendar)
    }

    /// Today (the local day of `now`) at `time`. On a spring-forward day where `time`
    /// does not exist, `Calendar` resolves to the next valid time that day. May be
    /// earlier than `now` (late `intervalDidStart`), which simply makes the report due.
    static func notBefore(time: TimeOfDay, now: Date, calendar: Calendar) -> Date {
        time.date(on: now, calendar: calendar)
    }

    /// The report to queue at `now`, or `nil` when the report is off, nothing was
    /// recorded for yesterday (device off, or no usage reached 15 min), or yesterday's
    /// report was already queued.
    static func makeTrigger(
        settings: NudgeTriggerSettings,
        recordedMinutes: Int?,
        alreadyEnqueued: Bool,
        userName: String,
        now: Date,
        calendar: Calendar
    ) -> PendingTrigger? {
        guard settings.dailyReportEnabled,
              let minutes = recordedMinutes, minutes > 0,
              !alreadyEnqueued else { return nil }
        return PendingTrigger(
            eventName: triggerEventName,
            report: NudgeMessages.dailyReport(userName: userName, totalMinutes: minutes),
            timestamp: now,
            notBefore: notBefore(time: settings.dailyReportTime, now: now, calendar: calendar)
        )
    }

    /// A queued report expires at the end of the local day it was due: after that its
    /// "yesterday" would name the wrong day.
    static func isExpired(_ trigger: PendingTrigger, now: Date, calendar: Calendar) -> Bool {
        guard let notBefore = trigger.notBefore,
              let expiry = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: notBefore))
        else { return false }
        return now >= expiry
    }

    // MARK: - Side effect (monitor extension, intervalDidStart)

    /// Queues yesterday's report if `makeTrigger` says so, marking it queued first so a
    /// second `intervalDidStart` the same night — which re-registration provokes
    /// (ADR-054) — is a no-op. Marking before appending means a crash in between loses
    /// one report rather than texting friends twice. Returns the queued trigger.
    @discardableResult
    static func enqueueIfNeeded(defaults: UserDefaults, now: Date, calendar: Calendar) -> PendingTrigger? {
        let store = GoalProgressStore(defaults: defaults)
        let day = reportedDay(now: now, calendar: calendar)

        guard let trigger = makeTrigger(
            settings: NudgeTriggerSettings.load(from: defaults),
            recordedMinutes: store.dailyTotalMinutes(onDay: day),
            alreadyEnqueued: store.isDailyReportEnqueued(forDay: day),
            userName: defaults.string(forKey: AppGroupKeys.userFirstName) ?? "Your friend",
            now: now,
            calendar: calendar
        ) else { return nil }

        guard store.markDailyReportEnqueued(forDay: day) else { return nil }   // lost a race
        let size = PendingTriggerQueue.append(trigger, to: defaults)
        logger.log("queued daily report for \(day, privacy: .public) — queue size now \(size)")
        return trigger
    }
}
