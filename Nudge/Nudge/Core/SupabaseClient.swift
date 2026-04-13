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
        auth: .init(emitLocalSessionAsInitialSession: true)
    )
)
