import Testing
import Foundation
@testable import Nudge

// MARK: - Int.formattedDuration

@Suite("Int.formattedDuration")
@MainActor
struct FormattedDurationTests {

    @Test func zero() {
        #expect(0.formattedDuration == "0m")
    }

    @Test func minutesOnly() {
        #expect((30 * 60).formattedDuration == "30m")
        #expect((1 * 60).formattedDuration == "1m")
        #expect((59 * 60).formattedDuration == "59m")
    }

    @Test func hoursOnly() {
        #expect(3600.formattedDuration == "1h")
        #expect((2 * 3600).formattedDuration == "2h")
        #expect((10 * 3600).formattedDuration == "10h")
    }

    @Test func hoursAndMinutes() {
        #expect((3600 + 30 * 60).formattedDuration == "1h 30m")
        #expect((2 * 3600 + 15 * 60).formattedDuration == "2h 15m")
        #expect((3600 + 60).formattedDuration == "1h 1m")
    }

    @Test func secondsOnly_roundsToZeroM() {
        // Under 1 minute with no hours returns "0m"
        #expect(45.formattedDuration == "0m")
        #expect(1.formattedDuration == "0m")
    }
}

// MARK: - GoalWithProgress Logic

@Suite("GoalWithProgress")
@MainActor
struct GoalWithProgressTests {

    private func makeGoal(limitSeconds: Int) -> Goal {
        Goal(
            id: 1,
            userId: UUID(),
            limitSeconds: limitSeconds,
            frequency: .daily,
            targetType: .total,
            bundleId: nil,
            categoryId: nil,
            temporary: false,
            startDate: nil,
            endDate: nil
        )
    }

    @Test func progressFractionBelowLimit() {
        let gwp = GoalWithProgress(goal: makeGoal(limitSeconds: 3600), usedSeconds: 1800)
        #expect(gwp.progressFraction == 0.5)
        #expect(!gwp.isExceeded)
    }

    @Test func progressFractionCappedAtOne() {
        let gwp = GoalWithProgress(goal: makeGoal(limitSeconds: 3600), usedSeconds: 7200)
        #expect(gwp.progressFraction == 1.0)
        #expect(gwp.isExceeded)
    }

    @Test func progressFractionAtExactLimit() {
        let gwp = GoalWithProgress(goal: makeGoal(limitSeconds: 3600), usedSeconds: 3600)
        #expect(gwp.progressFraction == 1.0)
        #expect(gwp.isExceeded)
    }

    @Test func progressFractionAtZero() {
        let gwp = GoalWithProgress(goal: makeGoal(limitSeconds: 3600), usedSeconds: 0)
        #expect(gwp.progressFraction == 0.0)
        #expect(!gwp.isExceeded)
    }

    @Test func idMatchesGoalId() {
        let goal = makeGoal(limitSeconds: 100)
        let gwp = GoalWithProgress(goal: goal, usedSeconds: 0)
        #expect(gwp.id == goal.id)
    }
}

// MARK: - Goal Model Coding

@Suite("Goal Model Coding")
@MainActor
struct GoalCodingTests {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // Verify GoalFrequency raw values match DB enum strings
    @Test func goalFrequencyRawValues() {
        #expect(GoalFrequency.daily.rawValue == "daily")
        #expect(GoalFrequency.weekly.rawValue == "weekly")
        #expect(GoalFrequency.monthly.rawValue == "monthly")
    }

    // Verify GoalTargetType raw values match DB enum strings
    @Test func goalTargetTypeRawValues() {
        #expect(GoalTargetType.app.rawValue == "app")
        #expect(GoalTargetType.category.rawValue == "category")
        #expect(GoalTargetType.total.rawValue == "total")
    }

    // GoalInsert must encode property names as snake_case keys
    @Test func goalInsertEncodesSnakeCaseKeys() throws {
        let insert = GoalInsert(
            userId: UUID(),
            limitSeconds: 3600,
            frequency: .daily,
            targetType: .total,
            bundleId: nil,
            categoryId: nil,
            temporary: false,
            startDate: nil,
            endDate: nil
        )
        let data = try encoder.encode(insert)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["user_id"] != nil,    "user_id key missing — explicit CodingKeys required")
        #expect(json["limit_seconds"] != nil, "limit_seconds key missing")
        #expect(json["target_type"] != nil, "target_type key missing")
        #expect(json["bundle_id"] != nil || insert.bundleId == nil)   // nil is encoded as NSNull
        #expect(json["category_id"] != nil || insert.categoryId == nil)
        #expect(json["start_date"] != nil || insert.startDate == nil)
        #expect(json["end_date"] != nil || insert.endDate == nil)

        // Ensure camelCase keys are absent
        #expect(json["userId"] == nil,      "camelCase userId should not appear")
        #expect(json["limitSeconds"] == nil, "camelCase limitSeconds should not appear")
        #expect(json["targetType"] == nil,   "camelCase targetType should not appear")
    }

    // Goal must decode correctly from snake_case JSON (as Supabase returns)
    @Test func goalDecodesFromSnakeCaseJSON() throws {
        let userId = UUID()
        let json = """
        {
            "id": 42,
            "user_id": "\(userId.uuidString)",
            "limit_seconds": 7200,
            "frequency": "weekly",
            "target_type": "app",
            "bundle_id": "com.example.app",
            "category_id": null,
            "temporary": true,
            "start_date": "2026-04-01",
            "end_date": "2026-04-30"
        }
        """.data(using: .utf8)!

        let goal = try decoder.decode(Goal.self, from: json)

        #expect(goal.id == 42)
        #expect(goal.userId == userId)
        #expect(goal.limitSeconds == 7200)
        #expect(goal.frequency == .weekly)
        #expect(goal.targetType == .app)
        #expect(goal.bundleId == "com.example.app")
        #expect(goal.categoryId == nil)
        #expect(goal.temporary == true)
        #expect(goal.startDate == "2026-04-01")
        #expect(goal.endDate == "2026-04-30")
    }

    @Test func goalDecodesNullableFieldsAsNil() throws {
        let json = """
        {
            "id": 1,
            "user_id": "\(UUID().uuidString)",
            "limit_seconds": 3600,
            "frequency": "daily",
            "target_type": "total",
            "bundle_id": null,
            "category_id": null,
            "temporary": false,
            "start_date": null,
            "end_date": null
        }
        """.data(using: .utf8)!

        let goal = try decoder.decode(Goal.self, from: json)
        #expect(goal.bundleId == nil)
        #expect(goal.categoryId == nil)
        #expect(goal.startDate == nil)
        #expect(goal.endDate == nil)
    }
}

// MARK: - AppUsage Model Coding

@Suite("AppUsage Model Coding")
@MainActor
struct AppUsageCodingTests {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test func appUsageDecodesFromSnakeCaseJSON() throws {
        let userId = UUID()
        let json = """
        {
            "id": 10,
            "user_id": "\(userId.uuidString)",
            "date": "2026-04-13",
            "app_id": "com.apple.mobilesafari",
            "seconds": 1234,
            "pickups": 17
        }
        """.data(using: .utf8)!

        let usage = try decoder.decode(AppUsage.self, from: json)
        #expect(usage.id == 10)
        #expect(usage.userId == userId)
        #expect(usage.date == "2026-04-13")
        #expect(usage.appId == "com.apple.mobilesafari")
        #expect(usage.seconds == 1234)
        #expect(usage.pickups == 17)
    }

    @Test func appRecordDecodesFromSnakeCaseJSON() throws {
        let json = """
        {
            "bundle_id": "com.apple.mobilesafari",
            "name": "Safari"
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(AppRecord.self, from: json)
        #expect(record.bundleId == "com.apple.mobilesafari")
        #expect(record.name == "Safari")
        #expect(record.id == "com.apple.mobilesafari")
    }

    @Test func appUsageWithNameDecodesFromSnakeCaseJSON() throws {
        let json = """
        {
            "id": 5,
            "app_id": "com.apple.mobilesafari",
            "app_name": "Safari",
            "date": "2026-04-13",
            "seconds": 600,
            "pickups": 3
        }
        """.data(using: .utf8)!

        let usage = try decoder.decode(AppUsageWithName.self, from: json)
        #expect(usage.id == 5)
        #expect(usage.appId == "com.apple.mobilesafari")
        #expect(usage.appName == "Safari")
        #expect(usage.date == "2026-04-13")
        #expect(usage.seconds == 600)
        #expect(usage.pickups == 3)
    }

    @Test func appUsageEncodesSnakeCaseKeys() throws {
        let usage = AppUsage(
            id: 1,
            userId: UUID(),
            date: "2026-04-13",
            appId: "com.test",
            seconds: 100,
            pickups: 5
        )
        let data = try encoder.encode(usage)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["user_id"] != nil)
        #expect(json["app_id"] != nil)
        #expect(json["userId"] == nil, "camelCase should not appear")
        #expect(json["appId"] == nil,  "camelCase should not appear")
    }
}

// MARK: - AppCategory Model Coding

@Suite("AppCategory Model Coding")
@MainActor
struct AppCategoryCodingTests {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test func appCategoryDecodesFromSnakeCaseJSON() throws {
        let userId = UUID()
        let json = """
        {
            "id": 3,
            "user_id": "\(userId.uuidString)",
            "name": "Social",
            "color": "#FF5733"
        }
        """.data(using: .utf8)!

        let category = try decoder.decode(AppCategory.self, from: json)
        #expect(category.id == 3)
        #expect(category.userId == userId)
        #expect(category.name == "Social")
        #expect(category.color == "#FF5733")
    }

    @Test func appCategoryMemberDecodesFromSnakeCaseJSON() throws {
        let json = """
        {
            "bundle_id": "com.instagram.Instagram",
            "category_id": 3
        }
        """.data(using: .utf8)!

        let member = try decoder.decode(AppCategoryMember.self, from: json)
        #expect(member.bundleId == "com.instagram.Instagram")
        #expect(member.categoryId == 3)
    }

    @Test func appCategoryMemberEncodesSnakeCaseKeys() throws {
        let member = AppCategoryMember(bundleId: "com.test", categoryId: 7)
        let data = try encoder.encode(member)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["bundle_id"] != nil)
        #expect(json["category_id"] != nil)
        #expect(json["bundleId"] == nil,   "camelCase should not appear")
        #expect(json["categoryId"] == nil, "camelCase should not appear")
    }
}
