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
            if ProcessInfo.processInfo.environment["ZDEEP_PASSIVE_TEST_HOST"] == "1" {
                PassiveHostedTestRoot()
            } else if let scenario = AuthorizationUITestHost.scenario(arguments: ProcessInfo.processInfo.arguments) {
                AuthorizationUITestHost(scenario: scenario)
            } else if let fixture = SessionUITestFixture.configuration(arguments: ProcessInfo.processInfo.arguments) {
                SessionUITestFixture(configuration: fixture)
            } else {
                AppRootView()
            }
            #else
            AppRootView()
            #endif
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct PassiveHostedTestRoot: View {
    var body: some View { Color.clear }
}
#endif
