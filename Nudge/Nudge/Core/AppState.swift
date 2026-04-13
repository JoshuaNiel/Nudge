import SwiftUI
import Supabase
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User? = nil
    @Published var isLoading: Bool = true  // true until first session check completes

    let authService = AuthService()

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
            case .signedIn, .tokenRefreshed, .userUpdated:
                currentUser = session?.user
                isAuthenticated = session != nil
            case .signedOut, .passwordRecovery, .userDeleted:
                currentUser = nil
                isAuthenticated = false
            default:
                break
            }
        }
    }
}
