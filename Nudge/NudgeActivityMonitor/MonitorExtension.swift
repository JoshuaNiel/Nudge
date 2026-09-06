// NudgeMonitor/MonitorExtension.swift
//
// DeviceActivityMonitor extension target.
//
// SETUP REQUIRED (Xcode GUI):
// 1. File → New → Target → "Device Activity Monitor Extension"
// 2. Name it "NudgeMonitor"
// 3. Add capabilities: Family Controls + App Groups (group.com.joshuaqn.Nudge)
// 4. Add this file to the NudgeMonitor target
// 5. Set NSExtensionPrincipalClass in NudgeMonitor's Info.plist to:
//    $(PRODUCT_MODULE_NAME).NudgeMonitor
//
// SHARED TYPES NOTE:
// GoalSummary, FriendSummary, PendingTrigger, and AppGroupKeys constants are
// duplicated below because this extension is a separate bundle from the main app.
// When Phase 3 adds a shared framework, move them there.

import Foundation
import DeviceActivity
import UserNotifications
import BackgroundTasks
import os

private let logger = Logger(subsystem: "com.joshuaqn.Nudge.NudgeActivityMonitor", category: "NudgeMonitor")

// MARK: - Shared type copies (duplicated from main app — move to shared framework later)

private struct GoalSummary: Codable {
    let goalId: Int
    let eventName: String
    let limitSeconds: Int
    let targetLabel: String
    let appBundleId: String?

    enum CodingKeys: String, CodingKey {
        case goalId       = "goal_id"
        case eventName    = "event_name"
        case limitSeconds = "limit_seconds"
        case targetLabel  = "target_label"
        case appBundleId  = "app_bundle_id"
    }
}

private struct FriendSummary: Codable {
    let id: Int
}

/// Strategy 2: the extension can't see the main app's `PendingTrigger` type
/// (separate bundle), so it keeps an inline copy with matching CodingKeys.
private struct PendingTrigger: Codable {
    let eventName: String
    let report: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case report
        case timestamp
    }
}

private enum AppGroupSuite {
    static let name          = "group.com.joshuaqn.Nudge"
    static let supabaseUrl   = "nudge.auth.supabaseUrl"
    static let anonKey       = "nudge.auth.anonKey"
    static let jwt           = "nudge.auth.jwt"
    static let userFirstName = "nudge.user.firstName"
    static let goalsActive   = "nudge.goals.active"
    static let friendsAccepted = "nudge.friends.accepted"
    static let triggersPending = "nudge.triggers.pending"
    static let midnightSyncNeeded = "nudge.sync.midnightNeeded"
}

private enum BGTaskIDs {
    static let nudgeTrigger = "com.joshuaqn.Nudge.nudge-trigger"
}

// MARK: - Monitor

class NudgeMonitor: DeviceActivityMonitor {

    // MARK: - Threshold fired

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        let eventName = event.rawValue
        logger.debug("[NudgeMonitor] eventDidReachThreshold: \(eventName, privacy: .public)")

        let defaults = UserDefaults(suiteName: AppGroupSuite.name)
        let userName = defaults?.string(forKey: AppGroupSuite.userFirstName) ?? "Your friend"
        let goals = loadGoalSummaries(from: defaults)

        logger.debug("[NudgeMonitor] loaded \(goals.count) goals")

        guard let matchedGoal = goals.first(where: { $0.eventName == eventName }) else {
            logger.error("[NudgeMonitor] no goal matched event '\(eventName, privacy: .public)' — registered goals: \(goals.map(\.eventName).joined(separator: ", "), privacy: .public)")
            return
        }

        logger.debug("[NudgeMonitor] matched goal: \(matchedGoal.targetLabel, privacy: .public), limit: \(matchedGoal.limitSeconds)s")

        let reportText = buildReport(userName: userName, goal: matchedGoal)
        logger.debug("[NudgeMonitor] report text: \(reportText, privacy: .public)")

        // 1. Post local notification immediately (no network needed)
        postLocalNotification(eventName: eventName, body: reportText)

        // 2. Strategy 2: enqueue a PendingTrigger for the main app to send. The
        //    extension's own network calls have proven unreliable on-device.
        enqueuePendingTrigger(eventName: eventName, report: reportText, defaults: defaults)

        // 3. Best-effort: ask the OS to wake the main app sooner to drain the queue.
        scheduleMainAppProcessing()
    }

    // MARK: - Strategy 2: enqueue pending trigger

    private func enqueuePendingTrigger(eventName: String, report: String, defaults: UserDefaults?) {
        guard let defaults else {
            logger.error("[NudgeMonitor] App Group defaults unavailable — cannot enqueue trigger")
            return
        }

        var pending: [PendingTrigger] = []
        if let data = defaults.data(forKey: AppGroupSuite.triggersPending),
           let existing = try? JSONDecoder().decode([PendingTrigger].self, from: data) {
            pending = existing
        }

        pending.append(PendingTrigger(eventName: eventName, report: report, timestamp: Date()))

        guard let encoded = try? JSONEncoder().encode(pending) else {
            logger.error("[NudgeMonitor] failed to encode pending triggers")
            return
        }
        defaults.set(encoded, forKey: AppGroupSuite.triggersPending)
        logger.debug("[NudgeMonitor] enqueued pending trigger — queue size now \(pending.count)")
    }

    private func scheduleMainAppProcessing() {
        let request = BGProcessingTaskRequest(identifier: BGTaskIDs.nudgeTrigger)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("[NudgeMonitor] scheduled main-app nudge-trigger processing")
        } catch {
            logger.error("[NudgeMonitor] failed to schedule BG task: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Schedule end (midnight)

    override func intervalDidEnd(for activity: DeviceActivityName) {
        logger.debug("[NudgeMonitor] intervalDidEnd — setting midnightSyncNeeded flag")
        let defaults = UserDefaults(suiteName: AppGroupSuite.name)
        defaults?.set(true, forKey: AppGroupSuite.midnightSyncNeeded)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        logger.debug("[NudgeMonitor] intervalDidStart — clearing day-scoped state")
        let defaults = UserDefaults(suiteName: AppGroupSuite.name)
        defaults?.removeObject(forKey: AppGroupSuite.midnightSyncNeeded)
    }

    // MARK: - Local notification

    private func postLocalNotification(eventName: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Nudge sent"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "nudge.\(eventName).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("[NudgeMonitor] failed to post local notification: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.debug("[NudgeMonitor] local notification posted")
            }
        }
    }

    // MARK: - App Group readers

    private func loadGoalSummaries(from defaults: UserDefaults?) -> [GoalSummary] {
        guard let data = defaults?.data(forKey: AppGroupSuite.goalsActive),
              let goals = try? JSONDecoder().decode([GoalSummary].self, from: data) else {
            logger.error("[NudgeMonitor] failed to load goals from App Group")
            return []
        }
        return goals
    }

    // MARK: - Message formatting (duplicated from NudgeMessages.swift — move to shared framework)

    private func buildReport(userName: String, goal: GoalSummary) -> String {
        let limitMinutes = goal.limitSeconds / 60

        if goal.eventName == "session.timeout" {
            return "\(userName) has been on their phone for \(limitMinutes) minutes."
        }
        if goal.eventName.hasPrefix("app.") {
            return "\(userName) just hit their \(limitMinutes)-minute limit on \(goal.targetLabel)."
        }
        if goal.eventName.hasPrefix("category.") {
            return "\(userName) just hit their \(limitMinutes)-minute limit on \(goal.targetLabel)."
        }
        return "\(userName) just hit their \(limitMinutes)-minute daily screen time limit."
    }
}
