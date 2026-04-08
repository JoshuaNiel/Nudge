import SwiftUI

private struct TourPage {
    let icon: String
    let title: String
    let description: String
}

private let pages: [TourPage] = [
    TourPage(
        icon: "chart.bar.fill",
        title: "See Where Your Time Goes",
        description: "Track exactly how much time you spend in each app — by day, week, or month."
    ),
    TourPage(
        icon: "target",
        title: "Set Goals That Mean Something",
        description: "Set time limits and write down *why* you want to change. Your reasons show up as reminders when you need them most."
    ),
    TourPage(
        icon: "person.2.fill",
        title: "Stay Accountable with Friends",
        description: "Connect with friends and send nudges when someone's been on their phone too long — or send encouragement when they're doing well."
    )
]

struct OnboardingTourView: View {
    var onFinished: () -> Void

    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    TourPageView(page: pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut, value: currentPage)

            Button(action: advance) {
                Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func advance() {
        if currentPage < pages.count - 1 {
            currentPage += 1
        } else {
            onFinished()
        }
    }
}

#Preview {
    OnboardingTourView(onFinished: {})
}

private struct TourPageView: View {
    let page: TourPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.icon)
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
            Text(page.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            Text(page.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}
