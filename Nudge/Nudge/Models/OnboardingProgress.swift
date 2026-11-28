import Foundation

// Onboarding progress (docs/specs/onboarding-progress.md §1–§3).
// Account steps live on the server (`onboarding_status()`) with a device copy per user;
// device steps (permissions) are never stored — they are read from the system each time.

/// Account steps, in order. Raw values match `onboarding_status().next_step`.
enum OnboardingAccountStep: String, Codable {
    case profile
}

/// The device copy of one user's onboarding progress. Stored locally only (not a DB row).
struct OnboardingProgress: Codable, Equatable {
    var completed: Bool
    var nextStep: OnboardingAccountStep?
    var firstName: String?
    var lastName: String?
    var updatedAt: Date

    /// The first account step not yet satisfied. Mirrors `public.onboarding_status()`:
    /// profile is satisfied when both names are non-blank.
    static func nextStep(firstName: String?, lastName: String?) -> OnboardingAccountStep? {
        isNonBlank(firstName) && isNonBlank(lastName) ? nil : .profile
    }

    /// Same content, ignoring `updatedAt`.
    func hasSameContent(as other: OnboardingProgress) -> Bool {
        completed == other.completed && nextStep == other.nextStep
            && firstName == other.firstName && lastName == other.lastName
    }

    private static func isNonBlank(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the server knows: `onboarding_status()` plus the profile's names.
struct OnboardingServerStatus: Equatable {
    var completed: Bool
    /// The server's own `next_step` (kept as a string: a newer server may name steps this
    /// build doesn't know). The device recomputes its own from the merged names.
    var nextStep: String?
    var firstName: String?
    var lastName: String?
}

/// `select public.onboarding_status()` → `{ "completed": bool, "next_step": "profile" | null }`.
nonisolated struct OnboardingStatusResponse: Decodable, Sendable {
    let completed: Bool
    let nextStep: String?

    enum CodingKeys: String, CodingKey {
        case completed
        case nextStep = "next_step"
    }
}

// MARK: - Outbox kinds

struct ProfileNamePayload: Codable, Equatable {
    let firstName: String
    let lastName: String
}

/// For kinds that carry no data.
struct EmptyPayload: Codable, Equatable {}

enum OnboardingOutboxKinds {
    /// Newest name wins: a newer one replaces a queued older one.
    static let updateProfileName = OutboxKind<ProfileNamePayload>(name: "updateProfileName", coalescing: .replacePending)
    /// Queued at most once; the server value never goes back to false.
    static let markOnboardingCompleted = OutboxKind<EmptyPayload>(name: "markOnboardingCompleted", coalescing: .oncePending)
}
