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
#if DEBUG
    @State private var isShowingDebugPanel = false
#endif

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

#if DEBUG
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
#endif

            if coordinator.isWebViewOpen {
                if let session = coordinator.activeWebSession {
                    ZStack(alignment: .top) {
                        WebViewHost(session: session)
                        VStack(spacing: 8) {
                            if session.isLoading {
                                ProgressView()
                                    .padding(8)
                            }
                            if let url = session.currentURL {
                                Text(url.absoluteString)
                                    .font(.caption2)
                                    .textSelection(.enabled)
                            }
                            if let error = session.navigationError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("webview-error")
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
#if DEBUG
        .overlay(alignment: .bottomTrailing) {
            DebugOverlay { isShowingDebugPanel = true }
                .padding(.bottom, 12)
                .padding(.trailing, 8)
        }
        .sheet(isPresented: $isShowingDebugPanel) {
            DebugPanel(coordinator: coordinator, eventStore: .shared)
        }
        .onChange(of: coordinator.activeWebSession?.currentURL) { _, url in
            guard let url else { return }
            DiagnosticEventStore.shared.record(category: "webview.navigation", operationID: coordinator.activeWebSession?.id.uuidString, fields: ["url": url.absoluteString])
        }
        .onChange(of: coordinator.activeWebSession?.navigationError) { _, error in
            guard let error else { return }
            DiagnosticEventStore.shared.record(category: "webview.navigation.failed", operationID: coordinator.activeWebSession?.id.uuidString, fields: ["error": error])
        }
#endif
    }
}

#Preview {
    ContentView(coordinator: AppCoordinator())
}
