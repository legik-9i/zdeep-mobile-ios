//
//  ContentView.swift
//  ZDEEP
//
//  Created by Олег on 02.10.2026.
//

import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Hello, world3!")
                .font(.title2)

            Text("Окружение: \(coordinator.environment.rawValue)")
                .accessibilityIdentifier("current-environment")
            Text(coordinator.endpoints.web.absoluteString)
                .font(.footnote)
                .textSelection(.enabled)
            Text(coordinator.endpoints.backend.absoluteString)
                .font(.footnote)
                .textSelection(.enabled)

            Picker("Окружение", selection: Binding(
                get: { coordinator.environment },
                set: { environment in
                    Task { await coordinator.switchEnvironment(to: environment) }
                }
            )) {
                ForEach(AppEnvironment.allCases) { environment in
                    Text(environment.rawValue).tag(environment)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("environment-picker")
            .disabled(coordinator.isTransitioning)

            if coordinator.isWebViewOpen {
                Text("WebView будет подключён в следующей задаче")
                Button("Закрыть WebView") {
                    coordinator.closeWebView()
                }
                .accessibilityIdentifier("close-webview")
                .disabled(coordinator.isTransitioning)
            } else {
                Button("Открыть WebView") {
                    coordinator.openWebView()
                }
                .accessibilityIdentifier("open-webview")
                .disabled(coordinator.isTransitioning)
            }
        }
        .padding()
    }
}

#Preview {
    ContentView(coordinator: AppCoordinator())
}
