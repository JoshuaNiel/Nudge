import Foundation
import Combine
import UIKit

/// The one sheet the Goals tab shows at a time.
enum GoalsSheet: Identifiable, Hashable {
    case addGoal
    case ask(PermissionAsk)

    var id: Self { self }
}

/// The Goals tab's in-context permission asks around adding a goal
/// (docs/specs/onboarding-progress.md §5b):
/// - **+ without Screen Time approved** → the Screen Time ask. Allow shows the system prompt
///   and, on approval, continues into add-goal; Not now closes (goals can't work without it).
/// - **A goal saved with notifications off** → the notification ask (Turn On / Open Settings /
///   Not now). The goal is already saved either way.
///
/// "Not now" is never remembered: the ask appears again on the next attempt.
@MainActor
final class GoalsSheetFlow: ObservableObject {

    /// The sheet on screen; `nil` when none. Swapping one for another dismisses the first.
    @Published var sheet: GoalsSheet?
    /// A system prompt from an ask is up.
    @Published private(set) var isRequesting = false

    private let requester: PermissionRequesting
    private let openURL: (URL) -> Void

    /// `openURL` defaults to `UIApplication.shared.open`.
    init(requester: PermissionRequesting, openURL: ((URL) -> Void)? = nil) {
        self.requester = requester
        self.openURL = openURL ?? { UIApplication.shared.open($0) }
    }

    // MARK: - Add goal

    func addGoalTapped() {
        sheet = requester.status(of: .screenTime) == .granted ? .addGoal : .ask(.screenTimeForGoals)
    }

    func addGoalCancelled() {
        sheet = nil
    }

    /// The goal is saved: ask for notifications if they're off, otherwise just close.
    func goalSaved() {
        sheet = requester.status(of: .notifications) == .granted ? nil : .ask(.notificationsForGoalLimit)
    }

    // MARK: - Ask buttons

    /// "Allow" / "Turn On" / "Open Settings", per the permission's current status.
    func primaryTitle(for ask: PermissionAsk) -> String {
        PermissionBanners.buttonTitle(for: ask.permission, status: requester.status(of: ask.permission))
    }

    func primaryTapped() async {
        guard case .ask(let ask) = sheet, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        let status = await PermissionActionRunner.run(ask.permission, requester: requester, openURL: openURL)

        // The sheet may have changed meanwhile (e.g. swiped away); only act on this ask.
        guard sheet == .ask(ask) else { return }
        switch ask {
        case .screenTimeForGoals:
            sheet = status == .granted ? .addGoal : nil
        case .notificationsForGoalLimit:
            sheet = nil
        }
    }

    func notNowTapped() {
        sheet = nil
    }
}
