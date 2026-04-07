import SwiftUI
internal import Combine

@MainActor
class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
}
