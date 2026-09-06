import Testing
import Foundation
@testable import Nudge

// MARK: - PendingTrigger Codable

@Suite("PendingTrigger")
@MainActor
struct PendingTriggerTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test func roundTrip() throws {
        let trigger = PendingTrigger(
            eventName: "app.com.instagram.Instagram",
            report: "Josh just hit their 30-minute limit on Instagram.",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try encoder.encode(trigger)
        let decoded = try decoder.decode(PendingTrigger.self, from: data)

        #expect(decoded.eventName == trigger.eventName)
        #expect(decoded.report == trigger.report)
        #expect(decoded.timestamp == trigger.timestamp)
    }

    @Test func encodesSnakeCaseKeys() throws {
        let trigger = PendingTrigger(eventName: "total", report: "r", timestamp: Date())
        let data = try encoder.encode(trigger)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["event_name"] != nil, "event_name key missing")
        #expect(json["eventName"] == nil, "camelCase should not appear")
    }
}

// MARK: - GoalSummary Codable

@Suite("GoalSummary")
@MainActor
struct GoalSummaryTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test func roundTripApp() throws {
        let summary = GoalSummary(
            goalId: 1,
            eventName: "app.com.instagram.Instagram",
            limitSeconds: 1800,
            targetLabel: "Instagram",
            appBundleId: "com.instagram.Instagram"
        )
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(GoalSummary.self, from: data)

        #expect(decoded.goalId == summary.goalId)
        #expect(decoded.eventName == summary.eventName)
        #expect(decoded.limitSeconds == summary.limitSeconds)
        #expect(decoded.targetLabel == summary.targetLabel)
        #expect(decoded.appBundleId == summary.appBundleId)
    }

    @Test func roundTripTotal() throws {
        let summary = GoalSummary(
            goalId: 2,
            eventName: "total",
            limitSeconds: 7200,
            targetLabel: "All Apps",
            appBundleId: nil
        )
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(GoalSummary.self, from: data)

        #expect(decoded.goalId == 2)
        #expect(decoded.eventName == "total")
        #expect(decoded.appBundleId == nil)
    }

    @Test func encodesSnakeCaseKeys() throws {
        let summary = GoalSummary(goalId: 1, eventName: "total", limitSeconds: 3600, targetLabel: "All Apps", appBundleId: nil)
        let data = try encoder.encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["goal_id"] != nil)
        #expect(json["event_name"] != nil)
        #expect(json["limit_seconds"] != nil)
        #expect(json["target_label"] != nil)
        #expect(json["goalId"] == nil, "camelCase should not appear")
    }
}

// MARK: - NudgeMessages formatting

@Suite("NudgeMessages")
@MainActor
struct NudgeMessagesTests {

    @Test func goalBreachApp() {
        let msg = NudgeMessages.goalBreachApp(userName: "Josh", limitMinutes: 30, appName: "Instagram")
        #expect(msg == "Josh just hit their 30-minute limit on Instagram.")
    }

    @Test func goalBreachCategory() {
        let msg = NudgeMessages.goalBreachCategory(userName: "Sam", limitMinutes: 60, categoryName: "Social Media")
        #expect(msg == "Sam just hit their 60-minute limit on Social Media.")
    }

    @Test func goalBreachTotal() {
        let msg = NudgeMessages.goalBreachTotal(userName: "Alex", limitMinutes: 120)
        #expect(msg == "Alex just hit their 120-minute daily screen time limit.")
    }

    @Test func sessionTimeout() {
        let msg = NudgeMessages.sessionTimeout(userName: "Lee", minutes: 45)
        #expect(msg == "Lee has been on their phone for 45 minutes.")
    }

    @Test func dailyReportWithApps() {
        let msg = NudgeMessages.dailyReport(
            userName: "Josh",
            totalSeconds: 7200,
            topApps: [
                (name: "Instagram", seconds: 3600),
                (name: "Safari", seconds: 1800),
                (name: "YouTube", seconds: 900)
            ]
        )
        #expect(msg.contains("Josh"))
        #expect(msg.contains("2h"))
        #expect(msg.contains("Instagram"))
        #expect(msg.contains("Safari"))
        #expect(msg.contains("YouTube"))
    }

    @Test func dailyReportOnlyTopThree() {
        let topApps = [
            (name: "App1", seconds: 4000),
            (name: "App2", seconds: 3000),
            (name: "App3", seconds: 2000),
            (name: "App4", seconds: 1000),
        ]
        let msg = NudgeMessages.dailyReport(userName: "Josh", totalSeconds: 10000, topApps: topApps)
        #expect(!msg.contains("App4"), "Should only show top 3 apps")
    }

    @Test func dailyReportEmpty() {
        let msg = NudgeMessages.dailyReport(userName: "Josh", totalSeconds: 0, topApps: [])
        #expect(msg.contains("Josh"))
        #expect(!msg.contains("Top apps"))
    }

    @Test func reportForGoalApp() {
        let summary = GoalSummary(
            goalId: 1,
            eventName: "app.com.instagram.Instagram",
            limitSeconds: 1800,
            targetLabel: "Instagram",
            appBundleId: "com.instagram.Instagram"
        )
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary)
        #expect(msg.contains("Josh"))
        #expect(msg.contains("Instagram"))
        #expect(msg.contains("30"))
    }

    @Test func reportForGoalTotal() {
        let summary = GoalSummary(
            goalId: 2,
            eventName: "total",
            limitSeconds: 3600,
            targetLabel: "All Apps",
            appBundleId: nil
        )
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary)
        #expect(msg.contains("daily screen time limit"))
    }

    @Test func reportForSessionTimeout() {
        let summary = GoalSummary(
            goalId: 0,
            eventName: "session.timeout",
            limitSeconds: 2700,
            targetLabel: "Session",
            appBundleId: nil
        )
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary)
        #expect(msg.contains("on their phone for 45 minutes"))
    }

    // Event name parsing helpers
    @Test func eventNamePrefixApp() {
        let eventName = "app.com.instagram.Instagram"
        #expect(eventName.hasPrefix("app."))
        let bundleId = String(eventName.dropFirst("app.".count))
        #expect(bundleId == "com.instagram.Instagram")
    }

    @Test func eventNamePrefixCategory() {
        let eventName = "category.7"
        #expect(eventName.hasPrefix("category."))
        let categoryIdStr = String(eventName.dropFirst("category.".count))
        #expect(categoryIdStr == "7")
        #expect(Int(categoryIdStr) == 7)
    }

    @Test func eventNameTotal() {
        #expect("total" == "total")
        #expect(!"total".hasPrefix("app."))
        #expect(!"total".hasPrefix("category."))
    }
}
