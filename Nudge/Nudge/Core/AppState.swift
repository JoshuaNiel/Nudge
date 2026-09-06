import SwiftUI
import Supabase
import Combine
import FamilyControls

@MainActor
class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User? = nil
    @Published var isLoading: Bool = true  // true until first session check completes

    /// User's first name, fetched after sign-in. Used in nudge messages and written
    /// to App Group so the monitor extension can compose SMS copy without a network call.
    @Published var userFirstName: String = ""

    /// User's IANA timezone (e.g. "America/Denver"), fetched after sign-in.
    /// Defaults to the device timezone if not yet loaded from profile.
    @Published var timeZone: TimeZone = .current

    /// Configured session timeout in minutes (nil = disabled).
    @Published var sessionTimeoutMinutes: Int? = nil

    let authService = AuthService()
    private let friendService = FriendService()

    init() {
        Task {
            await observeAuthState()
        }
    }

    private func observeAuthState() async {
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .initialSession:
                currentUser = session?.user
                isAuthenticated = session != nil
                isLoading = false
                if let session {
                    await onSignedIn(session: session)
                } else {
                    clearAppGroup()
                }
            case .signedIn:
                currentUser = session?.user
                isAuthenticated = session != nil
                let status = AuthorizationCenter.shared.authorizationStatus
                 print("[NudgeApp] Family Controls authorization status: \(status)")
                if let session {
                    await onSignedIn(session: session)
                }
            case .tokenRefreshed:
                currentUser = session?.user
                if let session {
                    writeSecretsToAppGroup(session: session)
                }
            case .signedOut, .passwordRecovery, .userDeleted:
                currentUser = nil
                isAuthenticated = false
                userFirstName = ""
                clearAppGroup()
            default:
                break
            }
        }
    }

    // MARK: - App Group sync

    /// Called on sign-in and initial session. Writes auth secrets and fetches
    /// profile + friends so the monitor extension has everything it needs.
    private func onSignedIn(session: Session) async {
        writeSecretsToAppGroup(session: session)
        await fetchAndCacheProfile(userId: session.user.id)
        await syncFriendsToAppGroup(userId: session.user.id)
    }

    /// Writes the three App Group secrets the monitor extension needs to call send-nudge.
    private func writeSecretsToAppGroup(session: Session) {
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        let supabaseUrl = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""

        defaults?.set(supabaseUrl, forKey: AppGroupKeys.supabaseUrl)
        defaults?.set(anonKey, forKey: AppGroupKeys.anonKey)
        defaults?.set(session.accessToken, forKey: AppGroupKeys.jwt)
    }

    func fetchAndCacheProfile(userId: UUID) async {
        struct ProfileRow: Decodable {
            let firstName: String?
            let timeZone: String?
            let sessionTimeoutMinutes: Int?
            enum CodingKeys: String, CodingKey {
                case firstName = "first_name"
                case timeZone = "time_zone"
                case sessionTimeoutMinutes = "session_timeout_minutes"
            }
        }

        guard let row: ProfileRow = try? await supabase
            .from("profile")
            .select("first_name, time_zone, session_timeout_minutes")
            .eq("user_id", value: userId)
            .single()
            .execute()
            .value else { return }

        let name = row.firstName ?? ""
        userFirstName = name
        sessionTimeoutMinutes = row.sessionTimeoutMinutes
        if let tzId = row.timeZone, let tz = TimeZone(identifier: tzId) {
            timeZone = tz
        }
        UserDefaults(suiteName: AppGroupKeys.suiteName)?.set(name, forKey: AppGroupKeys.userFirstName)
    }

    private func syncFriendsToAppGroup(userId: UUID) async {
        guard let friends = try? await friendService.fetchFriends(userId: userId) else { return }
        let summaries = friends
            .filter { $0.status == .accepted }
            .map { FriendSummary(id: $0.id) }
        guard let data = try? JSONEncoder().encode(summaries) else { return }
        UserDefaults(suiteName: AppGroupKeys.suiteName)?.set(data, forKey: AppGroupKeys.friendsAccepted)
    }

    private func clearAppGroup() {
        let defaults = UserDefaults(suiteName: AppGroupKeys.suiteName)
        defaults?.removeObject(forKey: AppGroupKeys.jwt)
        defaults?.removeObject(forKey: AppGroupKeys.userFirstName)
        defaults?.removeObject(forKey: AppGroupKeys.friendsAccepted)
        defaults?.removeObject(forKey: AppGroupKeys.goalsActive)
    }
}
