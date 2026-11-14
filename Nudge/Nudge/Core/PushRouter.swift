import Foundation
import Combine

// MARK: - PushPayload

/// Parses the custom data the `receive-reply` Edge Function attaches to a reply push.
///
/// `supabase/functions/_shared/apns.ts` builds `{ aps: {...}, ...data }`, so custom keys
/// sit at the **top level** of `userInfo`, beside `aps` — not nested inside it.
enum PushPayload {
    /// Returns the positive integer `nudge_id`, or nil when it is missing or malformed.
    /// Accepts Int / NSNumber (incl. integral floating point) and numeric strings; rejects
    /// booleans, fractional numbers, non-positive values and anything else.
    nonisolated static func nudgeId(from userInfo: [AnyHashable: Any]) -> Int? {
        guard let raw = userInfo["nudge_id"] else { return nil }

        let value: Int?
        switch raw {
        case let string as String:
            value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case let number as NSNumber:
            // JSON `true` and Swift `Bool` both bridge to a CFBoolean NSNumber; `1` does not.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                value = nil
            } else if CFNumberIsFloatType(number) {
                value = Int(exactly: number.doubleValue)
            } else {
                value = number.intValue
            }
        default:
            value = nil
        }

        guard let value, value > 0 else { return nil }
        return value
    }
}

// MARK: - PushRouter

/// Holds a deep-link request produced by tapping a push until the UI can act on it.
///
/// The tap can arrive before any view exists (cold start) or while the app is running
/// (warm start). Either way the id waits here; `ContentView` switches to the Friends tab
/// while one is pending, and `SocialView` consumes it once its friend list has loaded.
@MainActor
final class PushRouter: ObservableObject {
    @Published private(set) var pendingNudgeId: Int?

    func handleNudgeTap(nudgeId: Int) {
        pendingNudgeId = nudgeId
    }

    /// Returns the pending id and clears it, so exactly one consumer acts on each tap.
    func consumePendingNudgeId() -> Int? {
        guard let id = pendingNudgeId else { return nil }
        pendingNudgeId = nil
        return id
    }

    func reset() {
        pendingNudgeId = nil
    }
}
