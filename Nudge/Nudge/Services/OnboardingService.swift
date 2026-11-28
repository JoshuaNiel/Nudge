import Foundation
import Supabase

/// Server side of onboarding progress (migration 009).
protocol OnboardingServerProtocol {
    /// `onboarding_status()` plus the profile's names (for the name merge rule).
    func fetchStatus(userId: UUID) async throws -> OnboardingServerStatus
    func updateProfileName(userId: UUID, firstName: String, lastName: String) async throws
    /// Sets `profile.onboarding_completed = true`. The app never sends `false`.
    func markOnboardingCompleted(userId: UUID) async throws
}

@MainActor
final class OnboardingService: OnboardingServerProtocol {

    nonisolated private struct ProfileNames: Decodable, Sendable {
        let firstName: String?
        let lastName: String?
        enum CodingKeys: String, CodingKey {
            case firstName = "first_name"
            case lastName = "last_name"
        }
    }

    func fetchStatus(userId: UUID) async throws -> OnboardingServerStatus {
        async let status: OnboardingStatusResponse = supabase
            .rpc("onboarding_status")
            .execute()
            .value
        async let names: ProfileNames = supabase
            .from("profile")
            .select("first_name, last_name")
            .eq("user_id", value: userId)
            .single()
            .execute()
            .value
        let (s, n) = try await (status, names)
        return OnboardingServerStatus(completed: s.completed, nextStep: s.nextStep,
                                      firstName: n.firstName, lastName: n.lastName)
    }

    func updateProfileName(userId: UUID, firstName: String, lastName: String) async throws {
        try await supabase
            .from("profile")
            .update(["first_name": firstName, "last_name": lastName])
            .eq("user_id", value: userId)
            .execute()
    }

    func markOnboardingCompleted(userId: UUID) async throws {
        try await supabase
            .from("profile")
            .update(["onboarding_completed": true])
            .eq("user_id", value: userId)
            .execute()
    }
}
