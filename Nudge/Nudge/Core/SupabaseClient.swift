import Foundation
import Supabase

private enum SupabaseConfig {
    static let url: URL = {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: string) else {
            fatalError("SUPABASE_URL missing or invalid in Info.plist")
        }
        return url
    }()

    static let publishableKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
              !key.isEmpty else {
            fatalError("SUPABASE_PUBLISHABLE_KEY missing in Info.plist")
        }
        return key
    }()
}

let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.publishableKey,
    options: .init(
        auth: .init(
            // PKCE is the SDK default (2.43.1), but it is load-bearing for security
            // so it is pinned here. Auth emails redirect to the custom scheme
            // `nudge://`, which any app can register. With PKCE the redirect only
            // carries a one-time code; exchanging it requires the code verifier
            // this device stored (in the keychain) when it requested the email,
            // so an app that intercepts the link can't turn it into a session.
            // The implicit flow would put the access + refresh tokens in the URL.
            flowType: .pkce,
            emitLocalSessionAsInitialSession: true
        )
    )
)
