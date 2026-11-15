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
// GoalProgressStore and ThresholdRouter all come from the `Shared/` folder, which is
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
            handleMilestone(goal: goal, percent: percent)
        case let .goalReached(goal):
            handleGoalReached(goal: goal, eventName: eventName)
        case let .sessionTimeout(session):
            handleSessionTimeout(session: session, eventName: eventName)
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

    /// p10–p90. Progress is already recorded by `ThresholdRouter`.
    private func handleMilestone(goal: GoalSummary, percent: Int) {
        logger.log("goal \(goal.goalId) reached \(percent)%")
        // Phase 4 seam: why-reminders hook in here, switching on `percent`.
    }

    /// p100 — the goal's limit was reached (Phase 3 G5).
    private func handleGoalReached(goal: GoalSummary, eventName: String) {
        postLocalNotification(
            eventName: eventName,
            title: NudgeMessages.limitReachedTitle(label: goal.targetLabel),
            body: NudgeMessages.limitReachedBody(label: goal.targetLabel, limitSeconds: goal.limitSeconds)
        )

        guard shouldSendGoalBreachNudge else { return }
        let userName = defaults?.string(forKey: AppGroupKeys.userFirstName) ?? "Your friend"
        let report = NudgeMessages.reportForGoal(userName: userName, goalSummary: goal)
        logger.log("goal \(goal.goalId) limit reached — queueing nudge: \(report, privacy: .public)")
        queueNudge(eventName: eventName, report: report)
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
    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.log("intervalDidStart — clearing day-scoped state and re-arming")
        if let defaults {
            defaults.removeObject(forKey: AppGroupKeys.midnightSyncNeeded)
            GoalProgressStore(defaults: defaults).prune(keepingDaysFrom: Date(), calendar: .current)
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

        var pending = MonitoringPlan.loadPendingTriggers(from: defaults)
        pending.append(PendingTrigger(eventName: eventName, report: report, timestamp: Date()))

        guard let encoded = try? JSONEncoder().encode(pending) else {
            logger.error("failed to encode pending triggers")
            return
        }
        defaults.set(encoded, forKey: AppGroupKeys.triggersPending)
        logger.log("enqueued pending trigger — queue size now \(pending.count)")
    }

    private func scheduleMainAppProcessing() {
        let request = BGProcessingTaskRequest(identifier: BGTaskIdentifiers.nudgeTrigger)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.log("scheduled main-app nudge-trigger processing")
        } catch {
            // Non-fatal: the queue still drains the next time the app is foregrounded.
            logger.error("failed to schedule BG task: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Local notification

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
                logger.error("failed to post local notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
