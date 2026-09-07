import Foundation
import Supabase

// MARK: - Protocol

protocol ProfileServiceProtocol {
    func fetchProfile(userId: UUID) async throws -> Profile
    func updateProfile(userId: UUID, firstName: String, lastName: String, phoneNumber: String?) async throws
}

// MARK: - Service

@MainActor
class ProfileService: ProfileServiceProtocol {

    func fetchProfile(userId: UUID) async throws -> Profile {
        try await supabase
            .from("profile")
            .select()
            .eq("user_id", value: userId)
            .single()
            .execute()
            .value
    }

    func updateProfile(userId: UUID, firstName: String, lastName: String, phoneNumber: String?) async throws {
        // Use AnyJSON so a cleared phone number can be sent as an explicit SQL NULL.
        // A plain [String: String] dictionary cannot represent null, which is required
        // to let the user remove a previously-saved number.
        let payload: [String: AnyJSON] = [
            "first_name": .string(firstName),
            "last_name": .string(lastName),
            "phone_number": phoneNumber.map { AnyJSON.string($0) } ?? .null
        ]

        try await supabase
            .from("profile")
            .update(payload)
            .eq("user_id", value: userId)
            .execute()
    }
}
