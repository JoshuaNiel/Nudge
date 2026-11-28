import SwiftUI

struct AppsView: View {
    var body: some View {
        NavigationStack {
            Text("Apps coming soon")
                .mainTabHeader(title: "Apps")
        }
    }
}

#Preview {
    AppsView()
}
