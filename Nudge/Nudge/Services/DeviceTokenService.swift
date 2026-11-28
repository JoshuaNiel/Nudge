import Foundation
import Supabase

// MARK: - Protocol

/// Stores / removes this device's APNs token in `public.device_tokens`.
/// RLS limits every call to the signed-in user's own rows, so both calls need a live session.
protocol DeviceTokenServiceProtocol {
    /// Upserts `(userId, token)`; an existing row has `platform` and `updated_at` refreshed.
    func registerToken(_ token: String, userId: UUID) async throws
    /// Deletes `(userId, token)` so this device stops receiving the user's pushes.
    func deleteToken(_ token: String, userId: UUID) async throws
}

// MARK: - Service

@MainActor
class DeviceTokenService: DeviceTokenServiceProtocol {

    func registerToken(_ token: String, userId: UUID) async throws {
        try await supabase
            .from("device_tokens")
            .upsert(
                DeviceTokenInsert(userId: userId, token: token, updatedAt: Date()),
                onConflict: "user_id,token",
                returning: .minimal
            )
            .execute()
    }

    func deleteToken(_ token: String, userId: UUID) async throws {
        try await supabase
            .from("device_tokens")
            .delete()
            .eq("user_id", value: userId)
            .eq("token", value: token)
            .execute()
    }
}
