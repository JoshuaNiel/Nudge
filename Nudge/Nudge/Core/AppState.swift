import SwiftUI
import Supabase
import Combine
import FamilyControls

@MainActor
class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User? = nil
    @Published var isLoading: Bool = true  // true until first session check completes

    /// User's first name. Used in nudge messages and written to the App Group so the monitor
    /// extension can compose SMS copy without a network call. The server profile is the
    /// source of truth; until it has a name (offline, or the queued write not sent yet) the
    /// name saved on this device in profile setup shows (`resolveFirstName`).
    @Published private(set) var userFirstName: String = ""

    /// User's IANA timezone (e.g. "America/Denver"), fetched after sign-in.
    /// Defaults to the device timezone if not yet loaded from profile.
    @Published var timeZone: TimeZone = .current

    /// Configured session timeout in minutes (nil = disabled).
    @Published var sessionTimeoutMinutes: Int? = nil

    /// "Account Deleted" page + where onboarding starts after it (account-deletion spec D).
    /// In memory only — never persisted.
    @Published private(set) var postDeletion = PostDeletionRouting()

    let authService = AuthService()
    private let friendService = FriendService()

    /// This device's APNs token, uploaded for whichever user is signed in.
    let pushTokens = PushTokenManager()

    private let appGroup: UserDefaults?
    /// The server profile's first name this session; `nil` until a fetch succeeds.
    private var serverFirstName: String?
    /// The signed-in user's name from the onboarding device copy (profile setup, offline-capable).
    private var deviceFirstName: String?

    convenience init() {
        self.init(observesAuth: true, appGroup: UserDefaults(suiteName: AppGroupKeys.suiteName))
    }

    /// `observesAuth: false` and an injected (or `nil`) App Group are for tests.
    init(observesAuth: Bool, appGroup: UserDefaults?) {
        self.appGroup = appGroup
        guard observesAuth else { return }
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
                postDeletion.signedIn()
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
                // Republish only if the user record changed (see fetchAndCacheProfile).
                if currentUser != session?.user { currentUser = session?.user }
                if let session {
                    writeSecretsToAppGroup(session: session)
                }
            case .signedOut, .userDeleted:
                currentUser = nil
                isAuthenticated = false
                serverFirstName = nil
                deviceFirstName = nil
                if userFirstName != "" { userFirstName = "" }
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

    // MARK: - Account deleted (spec D)

    /// "Back to Sign In": clears the Account Deleted page; onboarding resumes at `.auth`.
    func backToSignInAfterDeletion() {
        postDeletion.backToSignIn()
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
    /// Runs on every sign-in and token refresh; unchanged values are not rewritten.
    private func writeSecretsToAppGroup(session: Session) {
        let supabaseUrl = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""

        appGroup?.setIfChanged(supabaseUrl, forKey: AppGroupKeys.supabaseUrl)
        appGroup?.setIfChanged(anonKey, forKey: AppGroupKeys.anonKey)
        appGroup?.setIfChanged(session.accessToken, forKey: AppGroupKeys.jwt)
    }

    // MARK: - First name

    /// The name to show: the server's when it has one (source of truth), else the name saved on
    /// this device, else whatever the server said (possibly empty). Blank names count as none.
    static func resolveFirstName(server: String?, device: String?) -> String {
        func trimmed(_ value: String?) -> String {
            value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if !trimmed(server).isEmpty { return server ?? "" }
        if !trimmed(device).isEmpty { return trimmed(device) }
        return server ?? ""
    }

    /// The signed-in user's name from the onboarding device copy, as soon as profile setup saves
    /// it (offline too) or a re-sign-in loads it. Shows until the server profile has a name.
    func setDeviceFirstName(_ name: String?) {
        deviceFirstName = name
        publishFirstName()
    }

    private func publishFirstName() {
        let name = Self.resolveFirstName(server: serverFirstName, device: deviceFirstName)
        // Assign only real changes: every @Published write re-renders every AppState observer.
        if userFirstName != name { userFirstName = name }
        // No empty write: signed out (or after account deletion) the key must stay absent.
        if !name.isEmpty { appGroup?.setIfChanged(name, forKey: AppGroupKeys.userFirstName) }
    }

    /// Loads the profile into `AppState` and mirrors the first name to the App Group.
    ///
    /// Returns whether the fetch succeeded. Callers that arm DeviceActivity
    /// monitoring must check it: a silent failure leaves `sessionTimeoutMinutes`
    /// at `nil`, which would register monitoring without the session-timeout event.
    @discardableResult
    func fetchAndCacheProfile(userId: UUID) async -> Bool {
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
            .value else { return false }

        // Assign only real changes: every @Published write sends objectWillChange,
        // re-rendering every view that observes AppState (the whole app), even when the
        // value is the same — and this runs on every sign-in and foreground.
        serverFirstName = row.firstName ?? ""
        publishFirstName()
        if sessionTimeoutMinutes != row.sessionTimeoutMinutes {
            sessionTimeoutMinutes = row.sessionTimeoutMinutes
        }
        if let tzId = row.timeZone, let tz = TimeZone(identifier: tzId), timeZone != tz {
            timeZone = tz
        }
        return true
    }

    private func syncFriendsToAppGroup(userId: UUID) async {
        guard let friends = try? await friendService.fetchFriends(userId: userId) else { return }
        let summaries = friends
            .filter { $0.status == .accepted }
            .map { FriendSummary(id: $0.id) }
        guard let data = try? JSONEncoder().encode(summaries) else { return }
        appGroup?.setIfChanged(data, forKey: AppGroupKeys.friendsAccepted)
    }

    private func clearAppGroup() {
        let defaults = appGroup
        defaults?.removeObject(forKey: AppGroupKeys.jwt)
        defaults?.removeObject(forKey: AppGroupKeys.userFirstName)
        defaults?.removeObject(forKey: AppGroupKeys.friendsAccepted)
        defaults?.removeObject(forKey: AppGroupKeys.goalsActive)
    }
}

extension AppState: AccountDeletedPresenting {
    /// Called by the deletion flow once the server confirms, *before* local cleanup ends the
    /// session — so RootView switches to the page before `.signedOut` flips `isAuthenticated`.
    func presentAccountDeleted() {
        postDeletion.accountDeleted()
    }
}
