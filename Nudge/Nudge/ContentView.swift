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

    /// The tab a tapped push lands on. Both current routes belong to Friends: a reply opens
    /// the friend's history there; a friend-accepted push just shows the list.
    static func destination(for route: PushRoute) -> AppTab {
        switch route {
        case .nudgeReply, .friendAccepted:
            return .friends
        }
    }
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

            AppsView()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2.fill")
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
        // A push tap (cold or warm start) lands on its route's tab; the destination screen
        // (SocialView) then acts on and consumes the pending route. `initial: true` covers a
        // tap that arrived before this view existed.
        .onChange(of: pushRouter.pendingRoute, initial: true) { _, route in
            if let route {
                selectedTab = AppTab.destination(for: route)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(PushRouter())
        .environmentObject(PermissionStatusStore())
}
