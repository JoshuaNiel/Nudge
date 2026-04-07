import Foundation
// import Supabase  // Uncomment after adding the Supabase Swift package via SPM

// Add the Supabase package in Xcode:
// File → Add Package Dependencies → https://github.com/supabase/supabase-swift

enum SupabaseConfig {
    static let url = URL(string: "YOUR_SUPABASE_URL")!
    static let anonKey = "YOUR_SUPABASE_ANON_KEY"
}

// Once the package is added, replace the above with:
// import Supabase
// let supabase = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
