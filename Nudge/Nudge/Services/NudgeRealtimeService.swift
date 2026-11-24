import Foundation
import os
import Supabase

// MARK: - NudgeChange

/// One event from the real-time nudge feed for a single friend: `.inserted` (send-nudge),
/// `.updated` (receive-reply: `replied` → `reply_delivered`, type, reply text), or
/// `.subscribed` (the channel (re)joined — refetch).
typealias NudgeChange = RealtimeRowChange<Nudge>

// MARK: - Protocol

protocol NudgeRealtimeServiceProtocol {
    /// Live INSERT / UPDATE events on `public.nudge` for one friend.
    ///
    /// The subscription starts when this is called and is torn down when the stream terminates
    /// (the consumer stops iterating or its task is cancelled). Subscribe failures are logged and
    /// non-fatal: the stream simply yields nothing, and the caller falls back to fetch + refresh.
    func changes(friendId: Int) -> AsyncStream<NudgeChange>
}

// MARK: - Service

/// Supabase Realtime (Postgres Changes) wrapper for nudge status updates.
///
/// Requires `public.nudge` in the `supabase_realtime` publication (migration
/// `006b_realtime_nudge.sql`). Realtime evaluates the table's RLS select policy as the signed-in
/// user, so only the user's own nudges are ever delivered; the `friend_id` filter narrows that
/// to the history currently on screen. DELETE is not subscribed (nudges are only deleted by FK
/// cascade when the friend is removed).
@MainActor
final class NudgeRealtimeService: NudgeRealtimeServiceProtocol {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeRealtimeService")

    func changes(friendId: Int) -> AsyncStream<NudgeChange> {
        PostgresChangesFeed.changes(
            of: Nudge.self,
            table: "nudge",
            filter: .eq("friend_id", value: friendId),
            topicPrefix: "nudge-history-\(friendId)",
            logger: Self.logger
        )
    }

    /// Decodes a Realtime `record` with the same decoder PostgREST uses for history fetches.
    static func decodeNudge(from record: JSONObject) throws -> Nudge {
        try PostgresChangesFeed.decodeRecord(record, as: Nudge.self)
    }
}
