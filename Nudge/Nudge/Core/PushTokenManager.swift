import Foundation
import os

/// Owns this device's APNs token across the auth session lifecycle.
///
/// - The token can arrive before auth is ready (cold start), so it is persisted and uploaded
///   as soon as a user is signed in.
/// - Each (user, token) pair is uploaded at most once per process; a failed upload is retried
///   on the next trigger (next token callback or sign-in).
/// - On sign-out the row is deleted *before* the session is cleared (RLS needs the user's JWT).
///   The delete is best-effort and time-boxed so sign-out never hangs or fails because of it.
@MainActor
final class PushTokenManager {

    private struct UploadKey: Equatable {
        let userId: UUID
        let token: String
    }

    static let tokenDefaultsKey = "apnsDeviceToken"

    private static let logger = Logger(subsystem: "com.joshuaqn.Nudge", category: "PushTokenManager")

    private let service: DeviceTokenServiceProtocol
    private let defaults: UserDefaults
    private let deleteTimeout: Duration

    private var signedInUserId: UUID?
    private var uploadedKey: UploadKey?
    private var inFlightKey: UploadKey?

    /// The latest token APNs gave this device (persists across launches; device-scoped, not user-scoped).
    var currentToken: String? {
        defaults.string(forKey: Self.tokenDefaultsKey)
    }

    // Production init — uses real service
    init() {
        self.service = DeviceTokenService()
        self.defaults = .standard
        self.deleteTimeout = .seconds(5)
    }

    // Test init — accepts a mock and an isolated defaults suite
    init(service: DeviceTokenServiceProtocol, defaults: UserDefaults, deleteTimeout: Duration) {
        self.service = service
        self.defaults = defaults
        self.deleteTimeout = deleteTimeout
    }

    // MARK: - Lifecycle events

    func didReceiveDeviceToken(_ token: String) async {
        guard !token.isEmpty else { return }
        if token != currentToken {
            defaults.set(token, forKey: Self.tokenDefaultsKey)
        }
        await uploadIfNeeded()
    }

    func userDidSignIn(userId: UUID) async {
        if signedInUserId != userId {
            uploadedKey = nil
        }
        signedInUserId = userId
        await uploadIfNeeded()
    }

    /// Forget the session. Call when auth reports the user is gone.
    func userDidSignOut() {
        signedInUserId = nil
        uploadedKey = nil
    }

    /// Best-effort removal of this device's row for `userId`. Must run while the session is
    /// still valid. Never throws; gives up after `deleteTimeout`.
    func unregisterDevice(userId: UUID) async {
        // Whatever happens below, the next token callback / sign-in should upload again.
        uploadedKey = nil
        guard let token = currentToken else { return }

        let service = self.service
        let deletion = Task {
            try await service.deleteToken(token, userId: userId)
        }
        let timeout = Task { [deleteTimeout] in
            try await Task.sleep(for: deleteTimeout)
            deletion.cancel()
        }
        defer { timeout.cancel() }

        if case .failure(let error) = await deletion.result {
            Self.logger.error("device token delete failed (continuing sign-out): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Upload

    private func uploadIfNeeded() async {
        guard let userId = signedInUserId, let token = currentToken else { return }
        let key = UploadKey(userId: userId, token: token)
        guard key != uploadedKey, key != inFlightKey else { return }

        inFlightKey = key
        defer { if inFlightKey == key { inFlightKey = nil } }

        do {
            try await service.registerToken(token, userId: userId)
            // Only record success if the session didn't change while the request was in flight.
            if signedInUserId == userId {
                uploadedKey = key
            }
        } catch {
            Self.logger.error("device token upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
