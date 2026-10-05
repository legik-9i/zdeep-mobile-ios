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
        ZStack {
            if let session = coordinator.activeWebSession {
                WebViewHost(session: session, isVisible: coordinator.isWebViewOpen)
                    .opacity(coordinator.isWebViewOpen ? 1 : 0)
                    .allowsHitTesting(coordinator.isWebViewOpen)
                    .accessibilityHidden(!coordinator.isWebViewOpen)
            }
            switch coordinator.screen {
            case .logo:
                StartupLogoView()
            case .welcome:
                WelcomeView(onScan: {})
            case .loading:
                NativeLoadingView(canCancel: false, onCancel: {})
            case .web:
                EmptyView()
            case .error(let presentation):
                NativeErrorView(
                    presentation: presentation,
                    onRetry: { Task { await coordinator.retry() } },
                    onStartOver: { Task { await coordinator.startNewWelcomeScenario() } },
                    onRebind: { Task { await coordinator.startNewWelcomeScenario() } }
                )
            }
            if coordinator.screen != .logo, let scenarioID = coordinator.activeScenarioID {
                FirstFrameProbe(scenarioID: scenarioID) { coordinator.nativeFirstFrameDidRender(scenarioID: $0) }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
