//
//  ZDEEPApp.swift
//  ZDEEP
//
//  Created by Олег on 02.10.2026.
//

import SwiftUI

@main
struct ZDEEPApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
        }
    }
}
