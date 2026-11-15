// NudgeActivityMonitor/MonitorExtension.swift
//
// DeviceActivityMonitor extension target.
//
// SETUP (already done in Xcode):
// 1. Target type "Device Activity Monitor Extension", named "NudgeActivityMonitor"
// 2. Capabilities: Family Controls + App Groups (group.com.joshuaqn.Nudge)
// 3. NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).NudgeMonitor
//
// SHARED TYPES:
// GoalSummary, PendingTrigger, AppGroupKeys, NudgeMessages, MonitoringPlan, NudgeTriggerSettings,
// GoalProgressStore, ThresholdRouter, WhyReminderStore, GoalNotificationComposer,
// PendingTriggerQueue and DailyReport all come from the `Shared/` folder, which is
// compiled into this target as well as the main app. Do not re-declare them here — a
// private copy that drifts from the app's version silently disarms monitoring.
//
// This file only performs side effects. What a threshold *means* (parsing, matching,
// once-per-day dedup, progress) is decided by `ThresholdRouter`, which is unit-tested.

import Foundation
import DeviceActivity
import UserNotifications
import BackgroundTasks
import os

private let logger = Logger(subsystem: "com.joshuaqn.Nudge.NudgeActivityMonitor", category: "NudgeMonitor")

class NudgeMonitor: DeviceActivityMonitor {

    private var defaults: UserDefaults? { UserDefaults(suiteName: AppGroupKeys.suiteName) }

    // MARK: - Threshold fired

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        let eventName = event.rawValue
        logger.log("eventDidReachThreshold: \(eventName, privacy: .public)")

        guard let defaults else {
            logger.error("App Group defaults unavailable — cannot handle \(eventName, privacy: .public)")
            return
        }

        let catalog = MonitoringPlan.loadSummaries(from: defaults)
        let outcome = ThresholdRouter.route(
            eventName: eventName,
            catalog: catalog,
            store: GoalProgressStore(defaults: defaults),
            day: MonitoringPlan.dayStamp(for: Date(), calendar: .current)
        )

        switch outcome {
        case let .milestone(goal, percent):
            handleMilestone(goal: goal, percent: percent, eventName: eventName)
        case let .goalReached(goal):
            handleGoalReached(goal: goal, eventName: eventName)
        case let .sessionTimeout(session):
            handleSessionTimeout(session: session, eventName: eventName)
        case let .dailyTotal(minutes):
            // Recorded by ThresholdRouter for the daily report; no notification, no nudge.
            logger.log("total usage reached \(minutes) min today")
        case .duplicate:
            logger.log("\(eventName, privacy: .public) already handled today — skipping side effects")
        case .unmatched:
            // Surfaced as a notification, not just a log line: an unmatched event is
            // indistinguishable from "the threshold never fired" from the user's side,
            // which is exactly what made the day-2 silence so hard to diagnose.
            logger.error("no goal matched event '\(eventName, privacy: .public)' — catalog: \(catalog.map(\.eventName).joined(separator: ", "), privacy: .public)")
            postLocalNotification(
                eventName: eventName,
                title: "Nudge misconfigured",
                body: "A limit was reached but Nudge has no matching goal saved. Open Nudge to resync."
            )
            return
        }

        // Safety net: if this event fired on a day we have not registered for, the
        // registration is stale. Re-arm now (no-op on the normal path).
        reregisterIfNeeded(reason: "eventDidReachThreshold")
    }

    // MARK: - Milestone side effects

    /// p10–p90. Progress and once-per-day dedup are already handled by `ThresholdRouter`.
    /// Phase 4: when the user has a why at this percent, show one (round-robin).
    private func handleMilestone(goal: GoalSummary, percent: Int, eventName: String) {
        logger.log("goal \(goal.goalId) reached \(percent)%")
        let why = nextWhy(goalId: goal.goalId, percent: percent)
        guard let content = GoalNotificationComposer.milestone(goal: goal, percent: percent, why: why) else { return }
        postLocalNotification(eventName: eventName, title: content.title, body: content.body)
    }

    /// p100 — the goal's limit was reached (Phase 3 G5). A why at 100 becomes the body of
    /// this same notification (Phase 4) — one notification, not two.
    private func handleGoalReached(goal: GoalSummary, eventName: String) {
        let why = nextWhy(goalId: goal.goalId, percent: 100)
        let content = GoalNotificationComposer.limitReached(goal: goal, why: why)
        postLocalNotification(eventName: eventName, title: content.title, body: content.body)

        guard shouldSendGoalBreachNudge else { return }
        let userName = defaults?.string(forKey: AppGroupKeys.userFirstName) ?? "Your friend"
        let report = NudgeMessages.reportForGoal(userName: userName, goalSummary: goal)
        logger.log("goal \(goal.goalId) limit reached — queueing nudge: \(report, privacy: .public)")
        queueNudge(eventName: eventName, report: report)
    }

    /// The why to show for (goal, percent), advancing its rotation; `nil` when there is none.
    private func nextWhy(goalId: Int, percent: Int) -> String? {
        guard let defaults else { return nil }
        return WhyReminderStore(defaults: defaults).nextMessage(goalId: goalId, percent: percent)
    }

    /// The user's "Goal limit reached" toggle (Phase 5E), mirrored to the App Group by the
    /// app. Missing or undecodable settings read as **off** — the DB default, and the safe
    /// side: a wrong "on" texts the user's friends without consent, a wrong "off" only
    /// skips a nudge. The local "limit reached" notification above fires either way.
    private var shouldSendGoalBreachNudge: Bool {
        NudgeTriggerSettings.load(from: defaults).goalBreachEnabled
    }

    private func handleSessionTimeout(session: GoalSummary, eventName: String) {
        let userName = defaults?.string(forKey: AppGroupKeys.userFirstName) ?? "Your friend"
        let report = NudgeMessages.reportForGoal(userName: userName, goalSummary: session)
        logger.log("session timeout — report: \(report, privacy: .public)")

        // Local notification — no network needed, so this always lands.
        postLocalNotification(eventName: eventName, title: "Nudge sent", body: report)
        queueNudge(eventName: eventName, report: report)
    }

    /// Strategy 2 (ADR-034): the extension's own network calls never reach Supabase, so
    /// queue the trigger and ask the OS to wake the main app to send it.
    private func queueNudge(eventName: String, report: String) {
        enqueuePendingTrigger(eventName: eventName, report: report)
        scheduleMainAppProcessing()
    }

    // MARK: - Interval boundaries

    /// Midnight. **This is the primary re-arm path** and the reason monitoring keeps
    /// working with the app never opened: a `DeviceActivityEvent` threshold fires at
    /// most once per `startMonitoring` call, and iOS does not reliably re-arm spent
    /// thresholds when a `repeats: true` interval rolls over (ADR-054).
    ///
    /// Before re-arming it queues yesterday's daily report (Phase 5E-2). Prune keeps
    /// yesterday's total, and `DailyReport.enqueueIfNeeded` is idempotent per reported
    /// day, so the second `intervalDidStart` that re-registering provokes is a no-op. A
    /// mid-day `intervalDidStart` (an app registration after a missed midnight) catches
    /// up on a report that was never queued.
    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.log("intervalDidStart — clearing day-scoped state and re-arming")
        if let defaults {
            let now = Date()
            defaults.removeObject(forKey: AppGroupKeys.midnightSyncNeeded)
            GoalProgressStore(defaults: defaults).prune(keepingDaysFrom: now, calendar: .current)
            if DailyReport.enqueueIfNeeded(defaults: defaults, now: now, calendar: .current) != nil {
                scheduleMainAppProcessing()
            }
        }
        reregisterIfNeeded(reason: "intervalDidStart")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        logger.log("intervalDidEnd — setting midnightSyncNeeded flag")
        defaults?.set(true, forKey: AppGroupKeys.midnightSyncNeeded)
    }

    // MARK: - Re-registration

    /// Re-registers monitoring from the App Group catalog, but only when the day stamp
    /// or goal signature says the current registration is stale.
    ///
    /// The guard is what makes this loop-safe: re-registering inside
    /// `intervalDidStart` provokes another `intervalDidStart`, and that second pass
    /// sees today's stamp already written and stops.
    private func reregisterIfNeeded(reason: String) {
        let didRegister = MonitoringPlan.reregisterFromAppGroupIfNeeded(
            center: DeviceActivityCenter(),
            defaults: defaults,
            now: Date(),
            calendar: .current
        )
        logger.log("reregisterIfNeeded(\(reason, privacy: .public)) — registered: \(didRegister)")
    }

    // MARK: - Strategy 2 queue

    private func enqueuePendingTrigger(eventName: String, report: String) {
        guard let defaults else {
            logger.error("App Group defaults unavailable — cannot enqueue trigger")
            return
        }
        let size = PendingTriggerQueue.append(
            PendingTrigger(eventName: eventName, report: report, timestamp: Date()),
            to: defaults
        )
        logger.log("enqueued pending trigger — queue size now \(size)")
    }

    /// `earliestBeginDate` follows the queue: held until the earliest `notBefore` only
    /// when nothing queued is due yet (`PendingTriggerQueue.earliestBeginDate`).
    private func scheduleMainAppProcessing() {
        let request = BGProcessingTaskRequest(identifier: BGTaskIdentifiers.nudgeTrigger)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = PendingTriggerQueue.earliestBeginDate(
            for: PendingTriggerQueue.load(from: defaults),
            now: Date()
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.log("scheduled main-app nudge-trigger processing")
        } catch {
            // Non-fatal: the queue still drains the next time the app is foregrounded.
            logger.error("failed to schedule BG task: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Local notification

    /// Posts immediately. Without notification permission `add` fails (UNErrorDomain,
    /// "notifications not allowed"): that is logged and nothing else happens — no crash,
    /// and the rest of the threshold handling (nudges) is unaffected. No settings
    /// pre-check: an extra async hop would only widen the window in which the extension
    /// can be suspended before the post.
    private func postLocalNotification(eventName: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "nudge.\(eventName).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to post local notification for \(eventName, privacy: .public) (permission denied or not asked?): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
