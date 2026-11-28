import SwiftUI
import UIKit

// Main-tab header (docs/specs/onboarding-progress.md §5c, §5d): every main tab shares one
// header — Apple's native large navigation title, left-aligned, at ~28pt bold instead of 34pt,
// on the bar's system background, visible both expanded and collapsed. Native titles keep the
// title-morphs-into-back-button push animation (Friends → friend screen). Pushed screens and
// sheets keep their standard inline centered titles.

extension View {
    /// The shared main-tab header. Apply inside the tab's `NavigationStack`, on its root
    /// screen only. Trailing toolbar items the tab adds itself stay where they are. The title
    /// font comes from `MainTabHeaderAppearance.install()`, run once at launch.
    func mainTabHeader(title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            // §5c: the gray bar background stays visible, including the expanded large-title
            // (scroll-edge) state, where UIKit's default is transparent.
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// App-wide navigation-bar title font (§5d). Large titles exist only on the main tabs (every
/// other screen uses inline titles), so this changes nothing else.
enum MainTabHeaderAppearance {

    /// UIKit's large title is 34pt; §5d asks for ~28pt bold.
    static let largeTitlePointSize: CGFloat = 28

    /// Sets the large-title font on every bar appearance. Call once, before the first
    /// navigation bar is created (`NudgeApp.init`). Only the title attributes change; each
    /// appearance keeps UIKit's default background, which `mainTabHeader`'s
    /// `.toolbarBackground(.visible)` then forces visible on the main tabs.
    ///
    /// Scaled with Dynamic Type at launch (`UIFontMetrics(forTextStyle: .largeTitle)`); a text
    /// size change takes effect on the next launch.
    static func install() {
        let font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: .systemFont(ofSize: largeTitlePointSize, weight: .bold))

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()

        for appearance in [standard, scrollEdge] {
            appearance.largeTitleTextAttributes[.font] = font
        }

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = standard
        bar.compactAppearance = standard
        bar.scrollEdgeAppearance = scrollEdge
        bar.compactScrollEdgeAppearance = scrollEdge
    }
}
