import Foundation
import os
import Supabase

// MARK: - NudgeChange

/// One event from the real-time nudge feed for a single friend.
enum NudgeChange: Equatable {
    /// A new nudge row was inserted (send-nudge).
    case inserted(Nudge)
    /// An existing nudge row changed (receive-reply: `replied` → `reply_delivered`, type, reply text).
    case updated(Nudge)
    /// The channel (re)joined. Rows may have changed while we weren't listening — refetch.
    case subscribed
}

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
/// to the history currently on screen.
@MainActor
final class NudgeRealtimeService: NudgeRealtimeServiceProtocol {
    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "NudgeRealtimeService")

    func changes(friendId: Int) -> AsyncStream<NudgeChange> {
        let (stream, continuation) = AsyncStream<NudgeChange>.makeStream()

        // Unique topic per subscription: `channel(_:)` returns an existing channel for a reused
        // topic, which could hand us one that a previous (still tearing down) screen is leaving.
        let channel = supabase.channel("nudge-history-\(friendId)-\(UUID().uuidString)")
        let filter = RealtimePostgresFilter.eq("friend_id", value: friendId)

        // All postgres_changes bindings must be registered before subscribing.
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "nudge", filter: filter)
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: "nudge", filter: filter)

        let insertTask = Task {
            for await action in inserts {
                if let nudge = Self.decode(action.record, event: "INSERT") {
                    continuation.yield(.inserted(nudge))
                }
            }
        }
        let updateTask = Task {
            for await action in updates {
                if let nudge = Self.decode(action.record, event: "UPDATE") {
                    continuation.yield(.updated(nudge))
                }
            }
        }
        // Emit `.subscribed` on every transition into `.subscribed` — the first join and each
        // automatic rejoin after a socket reconnect — so the consumer can refetch the gap.
        let statusTask = Task {
            var wasSubscribed = false
            for await status in channel.statusChange {
                let isSubscribed = status == .subscribed
                if isSubscribed && !wasSubscribed {
                    continuation.yield(.subscribed)
                }
                wasSubscribed = isSubscribed
            }
        }
        let subscribeTask = Task {
            do {
                try await channel.subscribeWithError()
            } catch is CancellationError {
                // Screen went away mid-subscribe; teardown below handles the channel.
            } catch {
                Self.logger.error(
                    "Nudge realtime subscribe failed for friend \(friendId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        continuation.onTermination = { _ in
            Task { @MainActor in
                insertTask.cancel()
                updateTask.cancel()
                statusTask.cancel()
                // Let an in-flight join settle first so the channel can be left cleanly
                // (removeChannel only sends `leave` for a subscribed channel).
                await subscribeTask.value
                await supabase.removeChannel(channel)
            }
        }

        return stream
    }

    /// Decodes a Realtime `record` with the same decoder PostgREST uses for history fetches.
    static func decodeNudge(from record: JSONObject) throws -> Nudge {
        try record.decode(as: Nudge.self, decoder: PostgrestClient.Configuration.jsonDecoder)
    }

    private static func decode(_ record: JSONObject, event: String) -> Nudge? {
        do {
            return try decodeNudge(from: record)
        } catch {
            // Skipped, not fatal: the next resubscribe / foreground / pull-to-refresh refetches.
            logger.error("Undecodable nudge \(event, privacy: .public) record: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
