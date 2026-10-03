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
        Group {
            if coordinator.isWebViewOpen, let session = coordinator.activeWebSession {
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
            } else {
                WelcomeView()
            }
        }
#if DEBUG
        .overlay(alignment: .topTrailing) {
            DebugOverlay { isShowingDebugPanel = true }
                .padding(.top, 8)
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
