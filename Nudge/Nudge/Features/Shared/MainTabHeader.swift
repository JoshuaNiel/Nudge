import SwiftUI

// Main-tab header (docs/specs/onboarding-progress.md §5c): every main tab always shows the
// navigation bar's system background, whether or not content is scrolled under it.

extension View {
    /// Keeps the navigation bar's background visible. Apply inside the tab's `NavigationStack`.
    func mainTabHeader() -> some View {
        toolbarBackground(.visible, for: .navigationBar)
    }
}
