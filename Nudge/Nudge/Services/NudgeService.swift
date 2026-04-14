import Foundation
import Supabase

// MARK: - Protocol

protocol NudgeServiceProtocol {
    // Sends an automatic nudge to a friend.
    // `report` is the auto-generated context string (e.g. "Joshua has been on his
    // phone for 2 hours today and could use some support!"). The Edge Function
    // appends the numbered reply options before sending the SMS.
    func sendNudge(friendId: Int, report: String) async throws
}

// MARK: - Service

@MainActor
class NudgeService: NudgeServiceProtocol {

    func sendNudge(friendId: Int, report: String) async throws {
        struct Payload: Encodable {
            let friendId: Int
            let report: String

            enum CodingKeys: String, CodingKey {
                case friendId = "friend_id"
                case report
            }
        }

        try await supabase.functions.invoke(
            "send-nudge",
            options: FunctionInvokeOptions(body: Payload(friendId: friendId, report: report))
        )
    }
}
