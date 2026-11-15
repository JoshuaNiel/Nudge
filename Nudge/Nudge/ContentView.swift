//
//  ContentView.swift
//  Nudge
//
//  Created by Joshua Nielsen on 4/6/26.
//

import SwiftUI

/// Main-app tabs. Selection is state-driven so a push deep link can switch tabs.
enum AppTab: Hashable {
    case dashboard, apps, goals, friends, settings
}

struct ContentView: View {
    @EnvironmentObject private var pushRouter: PushRouter

    @State private var selectedTab: AppTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.bar.fill")
                }
                .tag(AppTab.dashboard)

            CategoriesView()
                .tabItem {
                    Label("Categories", systemImage: "square.grid.2x2.fill")
                }
                .tag(AppTab.apps)

            GoalsView()
                .tabItem {
                    Label("Goals", systemImage: "target")
                }
                .tag(AppTab.goals)

            SocialView()
                .tabItem {
                    Label("Friends", systemImage: "person.2.fill")
                }
                .tag(AppTab.friends)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        // A reply-push tap (cold or warm start) lands on Friends; SocialView then opens
        // the friend's history and consumes the pending id. `initial: true` covers a tap
        // that arrived before this view existed.
        .onChange(of: pushRouter.pendingNudgeId, initial: true) { _, nudgeId in
            if nudgeId != nil {
                selectedTab = .friends
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(PushRouter())
}
