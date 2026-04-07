//
//  NudgeApp.swift
//  Nudge
//
//  Created by Joshua Nielsen on 4/6/26.
//

import SwiftUI

@main
struct NudgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
