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

private enum AppGroupSuite {
    static let name          = "group.com.joshuaqn.Nudge"
    static let supabaseUrl   = "nudge.auth.supabaseUrl"
    static let anonKey       = "nudge.auth.anonKey"
    static let jwt           = "nudge.auth.jwt"
    static let userFirstName = "nudge.user.firstName"
    static let goalsActive   = "nudge.goals.active"
    static let friendsAccepted = "nudge.friends.accepted"
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
        let friends = loadFriendSummaries(from: defaults)

        logger.debug("[NudgeMonitor] loaded \(goals.count) goals, \(friends.count) friends")

        guard let matchedGoal = goals.first(where: { $0.eventName == eventName }) else {
            logger.error("[NudgeMonitor] no goal matched event '\(eventName, privacy: .public)' — registered goals: \(goals.map(\.eventName).joined(separator: ", "), privacy: .public)")
            return
        }

        logger.debug("[NudgeMonitor] matched goal: \(matchedGoal.targetLabel, privacy: .public), limit: \(matchedGoal.limitSeconds)s")

        let reportText = buildReport(userName: userName, goal: matchedGoal)
        logger.debug("[NudgeMonitor] report text: \(reportText, privacy: .public)")

        // 1. Post local notification immediately (no network needed)
        postLocalNotification(eventName: eventName, body: reportText)

        // 2. Strategy 1: background URLSession to send-nudge for each accepted friend
        if friends.isEmpty {
            logger.debug("[NudgeMonitor] no accepted friends — skipping network nudge")
            return
        }

        guard let urlString = defaults?.string(forKey: AppGroupSuite.supabaseUrl),
              let anonKey = defaults?.string(forKey: AppGroupSuite.anonKey),
              let jwt = defaults?.string(forKey: AppGroupSuite.jwt) else {
            logger.error("[NudgeMonitor] missing App Group secrets (supabaseUrl/anonKey/jwt) — cannot send nudge")
            return
        }

        logger.debug("[NudgeMonitor] sending nudge to \(friends.count) friend(s)")
        for friend in friends {
            sendNudge(
                friendId: friend.id,
                report: reportText,
                supabaseUrl: urlString,
                anonKey: anonKey,
                jwt: jwt
            )
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

    // MARK: - Strategy 1: background URLSession

    private func sendNudge(
        friendId: Int,
        report: String,
        supabaseUrl: String,
        anonKey: String,
        jwt: String
    ) {
        let urlString = "\(supabaseUrl)/functions/v1/send-nudge"
        guard let url = URL(string: urlString), url.scheme != nil else {
            logger.error("[NudgeMonitor] invalid supabaseUrl — raw value: '\(supabaseUrl, privacy: .public)'")
            return
        }
        logger.debug("[NudgeMonitor] posting to: \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        let body = ["friend_id": friendId, "report": report] as [String: Any]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            logger.error("[NudgeMonitor] failed to serialize request body")
            return
        }

        // Background URLSession: the OS manages the transfer after the extension's
        // execution window closes. Only uploadTask/downloadTask are supported —
        // dataTask is silently dropped when the extension window closes.
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.joshuaqn.Nudge.monitor.nudge.\(friendId)"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config)
        let task = session.uploadTask(with: request, from: bodyData)
        task.resume()

        logger.debug("[NudgeMonitor] background upload task enqueued for friend \(friendId)")
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

    private func loadFriendSummaries(from defaults: UserDefaults?) -> [FriendSummary] {
        guard let data = defaults?.data(forKey: AppGroupSuite.friendsAccepted),
              let friends = try? JSONDecoder().decode([FriendSummary].self, from: data) else {
            logger.error("[NudgeMonitor] failed to load friends from App Group")
            return []
        }
        return friends
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
