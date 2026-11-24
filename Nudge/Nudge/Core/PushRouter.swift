import Foundation
import Combine

// MARK: - PushRoute

/// Where a tapped push should take the user.
nonisolated enum PushRoute: Equatable, Sendable {
    /// A friend replied to a nudge (receive-reply): open that friend's nudge history.
    case nudgeReply(nudgeId: Int)
    /// A friend accepted the consent request (receive-reply, YES): show the Friends list.
    case friendAccepted(friendId: Int)
}

// MARK: - PushPayload

/// Parses the custom data the Edge Functions attach to a push.
///
/// `supabase/functions/_shared/apns.ts` builds `{ aps: {...}, ...data }`, so custom keys
/// sit at the **top level** of `userInfo`, beside `aps` — not nested inside it.
///
/// Payloads:
/// - Reply: `{ "nudge_id": <id> }` (no `type`).
/// - Friend accepted: `{ "type": "friend_accepted", "friend_id": <id> }`.
enum PushPayload {
    nonisolated static let friendAcceptedType = "friend_accepted"

    /// The route for a tapped push, or nil (open the app normally) when the payload is
    /// unknown or malformed.
    ///
    /// `type == "friend_accepted"` needs a positive `friend_id`; if it's missing or invalid the
    /// push routes nowhere (no fallback to `nudge_id`). Any other payload is parsed exactly as
    /// before 5I: a valid `nudge_id` → `.nudgeReply`, otherwise nil.
    nonisolated static func route(from userInfo: [AnyHashable: Any]) -> PushRoute? {
        if userInfo["type"] as? String == friendAcceptedType {
            return positiveId(userInfo["friend_id"]).map { .friendAccepted(friendId: $0) }
        }
        return nudgeId(from: userInfo).map { .nudgeReply(nudgeId: $0) }
    }

    /// Returns the positive integer `nudge_id`, or nil when it is missing or malformed.
    nonisolated static func nudgeId(from userInfo: [AnyHashable: Any]) -> Int? {
        positiveId(userInfo["nudge_id"])
    }

    /// Accepts Int / NSNumber (incl. integral floating point) and numeric strings; rejects
    /// missing values, booleans, fractional numbers, non-positive values and anything else.
    nonisolated private static func positiveId(_ raw: Any?) -> Int? {
        guard let raw else { return nil }

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

/// Holds the route produced by tapping a push until the UI can act on it.
///
/// The tap can arrive before any view exists (cold start) or while the app is running
/// (warm start). Either way the route waits here; `ContentView` switches to the route's tab
/// (`AppTab.destination(for:)`) while one is pending, and the destination screen
/// (`SocialView`, once its friend list has loaded) consumes it.
@MainActor
final class PushRouter: ObservableObject {
    @Published private(set) var pendingRoute: PushRoute?

    /// A later tap replaces an earlier one that hasn't been acted on yet.
    func handle(_ route: PushRoute) {
        pendingRoute = route
    }

    /// Returns the pending route and clears it, so exactly one consumer acts on each tap
    /// (and a second tap with the same payload is still observed as a change).
    func consumePendingRoute() -> PushRoute? {
        guard let route = pendingRoute else { return nil }
        pendingRoute = nil
        return route
    }

    func reset() {
        pendingRoute = nil
    }
}
