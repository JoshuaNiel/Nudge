import Foundation

// Goal enums shared by the app (Supabase models) and the monitor extension
// (`GoalSummary`, `MonitoringPlan`). Raw values match the Postgres enums exactly.

enum GoalFrequency: String, Codable {
    case daily
    case weekly
    case monthly
}

enum GoalTargetType: String, Codable {
    case app
    case category
    case total
}
