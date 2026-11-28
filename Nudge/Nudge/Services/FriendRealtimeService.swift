import Foundation
import os
import Supabase

// MARK: - FriendChange

/// One event from the real-time friend feed for the signed-in user: `.inserted` (a new contact),
/// `.updated` (consent accepted, rename, STOP → blocked), or `.subscribed` (the channel
/// (re)joined — refetch).
typealias FriendChange = RealtimeRowChange<Friend>

// MARK: - Protocol

protocol FriendRealtimeServiceProtocol {
    /// Live INSERT / UPDATE events on `public.friend` for one app user.
    ///
    /// The subscription starts when this is called and is torn down when the stream terminates
    /// (the consumer stops iterating or its task is cancelled). Subscribe failures are logged and
    /// non-fatal: the stream simply yields nothing, and the caller falls back to fetch + refresh.
    func changes(userId: UUID) -> AsyncStream<FriendChange>
}

// MARK: - Service

/// Supabase Realtime (Postgres Changes) wrapper for the Friends list.
///
/// Requires `public.friend` in the `supabase_realtime` publication (migration
/// `006c_realtime_friend.sql`). Realtime evaluates the "Users can read their own friend
/// contacts" select policy as the signed-in user, so only the user's own rows are delivered;
/// the `user_id` filter only narrows that. DELETE is deliberately not subscribed — Realtime
/// can't apply RLS to delete events — so declines / deletions made elsewhere appear on the
/// next fetch (every rejoin, foreground and pull-to-refresh refetches).
@MainActor
final class FriendRealtimeService: FriendRealtimeServiceProtocol {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "FriendRealtimeService")

    func changes(userId: UUID) -> AsyncStream<FriendChange> {
        // Lowercase to match how Postgres renders uuids (the server casts the value to the
        // column type either way; this just keeps the filter canonical).
        PostgresChangesFeed.changes(
            of: Friend.self,
            table: "friend",
            filter: .eq("user_id", value: userId.uuidString.lowercased()),
            topicPrefix: "friend-list",
            logger: Self.logger
        )
    }

    /// Decodes a Realtime `record` with the same decoder PostgREST uses for friend fetches.
    static func decodeFriend(from record: JSONObject) throws -> Friend {
        try PostgresChangesFeed.decodeRecord(record, as: Friend.self)
    }
}
