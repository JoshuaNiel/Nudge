import SwiftUI

// Main-tab header (docs/specs/onboarding-progress.md §5c, §5d): every main tab shares one
// header — the compact (inline-height) navigation bar with its system background always
// visible, and the tab's title at the leading edge in a slightly larger, bold font. Pushed
// screens and sheets keep the standard centered inline title.

extension View {
    /// The shared main-tab header. Apply inside the tab's `NavigationStack`, on its root
    /// screen only. Trailing toolbar items the tab adds itself stay where they are.
    ///
    /// The `navigationTitle` is still set: it is the back-button label on pushed screens
    /// (e.g. the friend screen reads "Friends"). The centered system title it would draw is
    /// replaced by an empty principal item; the visible title is the leading item instead.
    func mainTabHeader(title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { MainTabTitleToolbar(title: title) }
    }
}

/// The leading title, plus the empty principal item that hides the centered system title.
private struct MainTabTitleToolbar: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // A custom principal view takes the place of the centered title. Zero-size and
            // hidden from VoiceOver, which reads the leading title (a header) instead.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .withoutSharedBackground()

        ToolbarItem(placement: .topBarLeading) {
            Text(title)
                .font(.title3.bold())
                // Without this the bar sizes the item like an icon button and truncates it.
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
        .withoutSharedBackground()
    }
}

private extension ToolbarContent {
    /// On iOS 26 toolbar items sit in a Liquid Glass bubble by default; the header's items are
    /// plain text, not buttons, so they must not get one (§5d). No-op on earlier versions.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
