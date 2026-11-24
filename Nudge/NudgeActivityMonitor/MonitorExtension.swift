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
// GoalSummary, PendingTrigger, AppGroupKeys, NudgeMessages, MonitoringPlan and
// FiredEventStore all come from the `Shared/` folder, which is compiled into this
// target as well as the main app. Do not re-declare them here — a private copy
// that drifts from the app's version silently disarms monitoring.

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

        let defaults = self.defaults
        let userName = defaults?.string(forKey: AppGroupKeys.userFirstName) ?? "Your friend"
        let goals = MonitoringPlan.loadSummaries(from: defaults)

        // Events count past activity (ADR-054 amendment), so a threshold already
        // passed today fires again on every mid-day re-registration. The store
        // lets side effects run once per day per (event, threshold). Without App
        // Group defaults there is nowhere to record that, so we fall back to the
        // old always-notify behaviour rather than going silent.
        let firedStore = defaults.map { FiredEventStore(defaults: $0) }
        let day = MonitoringPlan.dayStamp(for: Date(), calendar: .current)

        guard let matchedGoal = goals.first(where: { $0.eventName == eventName }) else {
            // Surfaced as a notification, not just a log line: an unmatched event is
            // indistinguishable from "the threshold never fired" from the user's side,
            // which is exactly what made the day-2 silence so hard to diagnose.
            logger.error("no goal matched event '\(eventName, privacy: .public)' — registered: \(goals.map(\.eventName).joined(separator: ", "), privacy: .public)")
            let unmatchedKey = FiredEventStore.unmatchedKey(eventName: eventName)
            if firedStore?.markFired(unmatchedKey, onDay: day) ?? true {
                postLocalNotification(
                    eventName: eventName,
                    title: "Nudge misconfigured",
                    body: "A limit was reached but Nudge has no matching goal saved. Open Nudge to resync."
                )
            } else {
                logger.log("duplicate \(unmatchedKey, privacy: .public) suppressed")
            }
            return
        }

        // On this branch each GoalSummary registers exactly one event whose
        // threshold is `limitSeconds` (see `MonitoringPlan.events(for:)`), so the
        // summary's limit *is* the threshold that just fired.
        let dedupKey = FiredEventStore.dedupKey(eventName: eventName, thresholdSeconds: matchedGoal.limitSeconds)
        guard firedStore?.markFired(dedupKey, onDay: day) ?? true else {
            // Already notified (and queued the SMS) for this threshold today —
            // this is a re-registration replaying past activity.
            logger.log("duplicate \(dedupKey, privacy: .public) suppressed")
            reregisterIfNeeded(reason: "eventDidReachThreshold")
            return
        }

        let reportText = NudgeMessages.reportForGoal(userName: userName, goalSummary: matchedGoal)
        logger.log("matched \(matchedGoal.targetLabel, privacy: .public) — report: \(reportText, privacy: .public)")

        // 1. Local notification — no network needed, so this always lands.
        postLocalNotification(eventName: eventName, title: "Nudge sent", body: reportText)

        // 2. Strategy 2 (ADR-034): the extension's own network calls never reach
        //    Supabase, so queue the trigger for the main app to send.
        enqueuePendingTrigger(eventName: eventName, report: reportText)

        // 3. Ask the OS to wake the main app to drain the queue.
        scheduleMainAppProcessing()

        // 4. Safety net: if this event fired on a day we have not registered for,
        //    the registration is stale. Re-arm now (no-op on the normal path).
        reregisterIfNeeded(reason: "eventDidReachThreshold")
    }

    // MARK: - Interval boundaries

    /// Midnight. **This is the primary re-arm path** and the reason monitoring keeps
    /// working with the app never opened: a `DeviceActivityEvent` threshold fires at
    /// most once per `startMonitoring` call, and iOS does not reliably re-arm spent
    /// thresholds when a `repeats: true` interval rolls over (ADR-054).
    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.log("intervalDidStart — clearing day-scoped state and re-arming")
        defaults?.removeObject(forKey: AppGroupKeys.midnightSyncNeeded)
        reregisterIfNeeded(reason: "intervalDidStart")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        logger.log("intervalDidEnd — setting midnightSyncNeeded flag")
        defaults?.set(true, forKey: AppGroupKeys.midnightSyncNeeded)
    }

    // MARK: - Re-registration

    /// Re-registers monitoring from the App Group copy of the goal set, but only
    /// when the day stamp or goal signature says the current registration is stale.
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
