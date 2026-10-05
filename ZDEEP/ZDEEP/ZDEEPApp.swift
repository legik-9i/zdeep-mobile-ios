//
//  ZDEEPApp.swift
//  ZDEEP
//
//  Created by Олег on 02.10.2026.
//

import SwiftUI

@main
struct ZDEEPApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if let fixture = SessionUITestFixture.configuration(arguments: ProcessInfo.processInfo.arguments) {
                SessionUITestFixture(configuration: fixture)
            } else {
                ProductionRootView()
            }
            #else
            ProductionRootView()
            #endif
        }
    }
}

@MainActor
private struct ProductionRootView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        ContentView(coordinator: coordinator)
    }
}
