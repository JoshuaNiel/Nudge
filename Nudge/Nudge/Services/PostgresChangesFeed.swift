import Foundation
import os
import Supabase

// MARK: - RealtimeRowChange

/// One event from a live INSERT + UPDATE feed on a single table.
enum RealtimeRowChange<Row: Equatable>: Equatable {
    /// A new row was inserted.
    case inserted(Row)
    /// An existing row changed.
    case updated(Row)
    /// The channel (re)joined. Rows may have changed while we weren't listening — refetch.
    case subscribed
}

// MARK: - PostgresChangesFeed

/// Shared Supabase Realtime (Postgres Changes) plumbing for the app's live lists.
///
/// Opens one channel with INSERT + UPDATE bindings on `public.<table>` narrowed by `filter`,
/// decodes each record into `Row`, and tears the channel down when the stream terminates.
/// DELETE is never subscribed: Realtime can't apply RLS to delete events.
///
/// Realtime evaluates the table's RLS select policy as the signed-in user, so the filter only
/// narrows what the user may already read; it is not the security boundary. The table must be
/// in the `supabase_realtime` publication (migrations `006b` / `006c`).
@MainActor
enum PostgresChangesFeed {

    /// Live changes for `table`.
    ///
    /// - Parameters:
    ///   - topicPrefix: Readable channel prefix. A UUID is appended: `channel(_:)` returns an
    ///     existing channel for a reused topic, which could be one a previous (still tearing
    ///     down) screen is leaving.
    ///   - logger: Where subscribe failures and undecodable records are reported.
    ///
    /// Yields `.subscribed` on every transition into `RealtimeChannelStatus.subscribed` — the
    /// first join and each automatic rejoin after a socket reconnect. Stream termination (the
    /// consumer stops iterating / its task is cancelled) cancels the listeners, lets an
    /// in-flight join settle, then removes the channel. A subscribe failure is logged and
    /// non-fatal: the stream just yields nothing and the caller falls back to fetch + refresh.
    static func changes<Row: Decodable & Equatable>(
        of _: Row.Type,
        table: String,
        filter: RealtimePostgresFilter,
        topicPrefix: String,
        logger: Logger
    ) -> AsyncStream<RealtimeRowChange<Row>> {
        let (stream, continuation) = AsyncStream<RealtimeRowChange<Row>>.makeStream()

        let channel = supabase.channel("\(topicPrefix)-\(UUID().uuidString)")

        // All postgres_changes bindings must be registered before subscribing.
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: table, filter: filter)
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: table, filter: filter)

        let insertTask = Task {
            for await action in inserts {
                if let row = decode(Row.self, from: action.record, table: table, event: "INSERT", logger: logger) {
                    continuation.yield(.inserted(row))
                }
            }
        }
        let updateTask = Task {
            for await action in updates {
                if let row = decode(Row.self, from: action.record, table: table, event: "UPDATE", logger: logger) {
                    continuation.yield(.updated(row))
                }
            }
        }
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
                logger.error(
                    "Realtime subscribe failed for \(table, privacy: .public): \(error.localizedDescription, privacy: .public)"
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

    /// Decodes a Realtime `record` with the same decoder PostgREST uses for fetches, so the
    /// models' snake_case `CodingKeys` apply and microsecond `+00:00` timestamps parse.
    static func decodeRecord<Row: Decodable>(_ record: JSONObject, as _: Row.Type) throws -> Row {
        try record.decode(as: Row.self, decoder: PostgrestClient.Configuration.jsonDecoder)
    }

    private static func decode<Row: Decodable>(
        _ type: Row.Type,
        from record: JSONObject,
        table: String,
        event: String,
        logger: Logger
    ) -> Row? {
        do {
            return try decodeRecord(record, as: type)
        } catch {
            // Skipped, not fatal: the next resubscribe / foreground / pull-to-refresh refetches.
            logger.error(
                "Undecodable \(table, privacy: .public) \(event, privacy: .public) record: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
