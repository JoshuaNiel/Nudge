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
            eventName: "goal.1",
            limitSeconds: 1800,
            targetLabel: "Instagram",
            targetType: .app,
            selectionData: Data([1, 2, 3])
        )
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(GoalSummary.self, from: data)

        #expect(decoded == summary)
    }

    @Test func roundTripTotal() throws {
        let summary = GoalSummary(
            goalId: 2,
            eventName: "goal.2",
            limitSeconds: 7200,
            targetLabel: "All Apps",
            targetType: .total
        )
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(GoalSummary.self, from: data)

        #expect(decoded.goalId == 2)
        #expect(decoded.targetType == .total)
        #expect(decoded.selectionData == nil)
    }

    @Test func encodesSnakeCaseKeys() throws {
        let summary = GoalSummary(goalId: 1, eventName: "goal.1", limitSeconds: 3600, targetLabel: "All Apps", targetType: .total)
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

    // Daily report copy: see DailyReportTests.swift (Phase 5E-2).

    @Test func reportForGoalApp() {
        let summary = GoalSummary(
            goalId: 1,
            eventName: "goal.1",
            limitSeconds: 1800,
            targetLabel: "Instagram",
            targetType: .app
        )
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary)
        #expect(msg.contains("Josh"))
        #expect(msg.contains("Instagram"))
        #expect(msg.contains("30"))
    }

    @Test func reportForGoalTotal() {
        let summary = GoalSummary(
            goalId: 2,
            eventName: "goal.2",
            limitSeconds: 3600,
            targetLabel: "All Apps",
            targetType: .total
        )
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary)
        #expect(msg.contains("daily screen time limit"))
    }

    @Test func reportForSessionTimeout() {
        let summary = MonitoringPlan.sessionTimeoutSummary(minutes: 45)
        let msg = NudgeMessages.reportForGoal(userName: "Josh", goalSummary: summary)
        #expect(msg.contains("on their phone for 45 minutes"))
    }

    // Event name parsing is covered by "Goals core — event name parsing" (GoalsCoreTests).
}
