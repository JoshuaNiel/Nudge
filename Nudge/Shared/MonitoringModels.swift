import Foundation

// MARK: - App Group data structures
// These types are serialized to/from the shared App Group container to pass data
// between the main app and the DeviceActivityMonitor extension.

/// A fired trigger written by the DeviceActivityMonitor extension (Strategy 2 fallback).
/// Read by NudgeTriggerService when the main app wakes via BGProcessingTask.
struct PendingTrigger: Codable {
    let eventName: String   // e.g. "app.com.instagram.Instagram", "total", "session.timeout"
    let report: String      // pre-built SMS report text (composed by the extension)
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case report
        case timestamp
    }
}

/// A goal's monitoring configuration written to App Group by MonitoringRegistrationService.
/// Read by the DeviceActivityMonitor extension to compose nudge messages.
struct GoalSummary: Codable {
    let goalId: Int
    let eventName: String           // matches DeviceActivityEvent.Name raw value
    let limitSeconds: Int
    let targetLabel: String         // e.g. "Instagram", "Social Media", "All Apps"
    let appBundleId: String?        // nil for category / total / session goals

    enum CodingKeys: String, CodingKey {
        case goalId      = "goal_id"
        case eventName   = "event_name"
        case limitSeconds = "limit_seconds"
        case targetLabel  = "target_label"
        case appBundleId  = "app_bundle_id"
    }
}

/// Minimal friend info written to App Group by AppState after loading friends.
/// Read by the DeviceActivityMonitor extension to know which friend IDs to notify.
struct FriendSummary: Codable {
    let id: Int

    enum CodingKeys: String, CodingKey {
        case id
    }
}
