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

    /// Configured session timeout in minutes (nil = disabled), from `nudge_settings`
    /// (Phase 5E). Refreshed by `fetchAndCacheNudgeSettings`.
    @Published var sessionTimeoutMinutes: Int? = nil

    let authService = AuthService()
    private let friendService = FriendService()
    private let nudgeSettingsService: NudgeSettingsServiceProtocol = NudgeSettingsService()

    /// This device's APNs token, uploaded for whichever user is signed in.
    let pushTokens = PushTokenManager()

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
            case .tokenRefreshed, .passwordRecovery:
                // `.passwordRecovery` carries a valid session (it follows `.signedIn`
                // in the implicit flow; the PKCE flow never emits it). It must not
                // be treated as a sign-out. Recovery UI is driven by the deep-link
                // route in AuthRecoveryCoordinator, not by this event.
                currentUser = session?.user
                if let session {
                    writeSecretsToAppGroup(session: session)
                }
            case .signedOut, .userDeleted:
                currentUser = nil
                isAuthenticated = false
                userFirstName = ""
                pushTokens.userDidSignOut()
                clearAppGroup()
            default:
                break
            }
        }
    }

    // MARK: - Sign out

    /// Signs the user out, first removing this device's push token so a signed-out device
    /// stops receiving the user's reply pushes. The token delete must run while the session
    /// is still valid (RLS), and is best-effort: sign-out proceeds even if it fails.
    func signOut() async throws {
        if let userId = currentUser?.id {
            await pushTokens.unregisterDevice(userId: userId)
        }
        try await authService.signOut()
    }

    // MARK: - App Group sync

    /// Called on sign-in and initial session. Writes auth secrets and fetches
    /// profile + friends so the monitor extension has everything it needs.
    private func onSignedIn(session: Session) async {
        writeSecretsToAppGroup(session: session)
        await fetchAndCacheProfile(userId: session.user.id)
        await syncFriendsToAppGroup(userId: session.user.id)
        await pushTokens.userDidSignIn(userId: session.user.id)
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

    /// Loads the profile into `AppState` and mirrors the first name to the App Group.
    /// Returns whether the fetch succeeded.
    ///
    /// The session timeout no longer comes from here (Phase 5E): see
    /// `fetchAndCacheNudgeSettings`.
    @discardableResult
    func fetchAndCacheProfile(userId: UUID) async -> Bool {
        struct ProfileRow: Decodable {
            let firstName: String?
            let timeZone: String?
            enum CodingKeys: String, CodingKey {
                case firstName = "first_name"
                case timeZone = "time_zone"
            }
        }

        guard let row: ProfileRow = try? await supabase
            .from("profile")
            .select("first_name, time_zone")
            .eq("user_id", value: userId)
            .single()
            .execute()
            .value else { return false }

        let name = row.firstName ?? ""
        userFirstName = name
        if let tzId = row.timeZone, let tz = TimeZone(identifier: tzId) {
            timeZone = tz
        }
        UserDefaults(suiteName: AppGroupKeys.suiteName)?.set(name, forKey: AppGroupKeys.userFirstName)
        return true
    }

    /// Loads `nudge_settings` (defaults when the user has no row), sets
    /// `sessionTimeoutMinutes`, and mirrors the trigger toggles to the App Group for the
    /// monitor extension.
    ///
    /// Returns whether the fetch succeeded. Callers that arm DeviceActivity monitoring
    /// must check it (ADR-055): on failure nothing is changed — neither
    /// `sessionTimeoutMinutes` nor the App Group — so a failed request can never be
    /// mistaken for "session timeout off".
    @discardableResult
    func fetchAndCacheNudgeSettings(userId: UUID) async -> Bool {
        guard let settings = try? await nudgeSettingsService.fetch(userId: userId) else { return false }
        sessionTimeoutMinutes = settings.effectiveSessionTimeoutMinutes
        NudgeTriggerSettings.persist(settings.triggerSettings, defaults: UserDefaults(suiteName: AppGroupKeys.suiteName))
        return true
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
        // Why-reminders and their rotation are the signed-out user's personal text.
        if let defaults { WhyReminderStore(defaults: defaults).clear() }
        // Signed out → the extension fails closed (no goal-breach nudges).
        defaults?.removeObject(forKey: AppGroupKeys.nudgeSettings)
    }
}
