//
//  ContentView.swift
//  ZDEEP
//
//  Created by Олег on 02.10.2026.
//

import AVFoundation
import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingWelcomeAbout = false
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
                    .ignoresSafeArea(.container, edges: .bottom)
                    .opacity(coordinator.isWebViewOpen || (coordinator.screen == .loading && coordinator.webLoadingImageName != nil) ? 1 : 0)
                    .allowsHitTesting(coordinator.isWebViewOpen)
                    .accessibilityHidden(!coordinator.isWebViewOpen)
            }
            switch coordinator.screen {
            case .logo:
                StartupLogoView()
            case .welcome:
                WelcomeView(
                    onScan: { Task { await coordinator.beginCameraScan() } },
                    onHelp: { isShowingWelcomeAbout = true }
                )
            case .scanner:
                scannerContent
            case .cameraPermissionDenied:
                CameraPermissionView(
                    status: .denied,
                    onSettings: { coordinator.openCameraSettings() },
                    onBack: { coordinator.cancelCameraScan() }
                )
            case .cameraPermissionRestricted:
                CameraPermissionView(
                    status: .restricted,
                    onSettings: {},
                    onBack: { coordinator.cancelCameraScan() }
                )
            case .loading:
                if coordinator.webLoadingImageName == nil {
                    NativeLoadingView()
                }
            case .web:
                EmptyView()
            case .error(let presentation):
                NativeErrorView(
                    presentation: presentation,
                    onRetry: { Task { await coordinator.retry() } },
                    onStartOver: { Task { await coordinator.startOverAfterError(presentation) } },
                    onRebind: { Task { await coordinator.resetBindingAndShowWelcome() } }
                )
            }
            if coordinator.screen != .logo, let scenarioID = coordinator.activeScenarioID {
                FirstFrameProbe(scenarioID: scenarioID) {
                    coordinator.setLaunchTheme(colorScheme)
                    coordinator.nativeFirstFrameDidRender(scenarioID: $0)
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            if let imageName = coordinator.webLoadingImageName,
               coordinator.screen == .loading || coordinator.screen == .web {
                WebLoadingView(imageName: imageName)
                    .opacity(coordinator.screen == .web ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(coordinator.screen == .web)
                    .animation(.easeOut(duration: reduceMotion ? 0 : 0.25), value: coordinator.screen == .web)
                    .task(id: coordinator.screen == .web ? imageName : nil) {
                        guard coordinator.screen == .web else { return }
                        if reduceMotion {
                            coordinator.clearWebLoading()
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                        if coordinator.screen == .web, coordinator.webLoadingImageName == imageName {
                            coordinator.clearWebLoading()
                        }
                    }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WelcomeStyle.background.ignoresSafeArea())
        .sheet(isPresented: $isShowingWelcomeAbout) {
            WelcomeAboutSheet(url: coordinator.endpoints.web.appendingPathComponent("about.html"))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: colorScheme) { _, colorScheme in coordinator.setLaunchTheme(colorScheme) }
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

    @ViewBuilder
    private var scannerContent: some View {
#if DEBUG && targetEnvironment(simulator)
        if coordinator.syntheticAuthorizationUITestEnabled {
            Button("synthetic-scan-result") {
                Task { await coordinator.scannerDidProduce("https://fixture.invalid/auth/get-otp?token=header.eyJjYXJJZCI6InN5bnRoZXRpYy1jYXIifQ.signature") }
            }
        } else {
            scanner
        }
#else
        scanner
#endif
    }

    private var scanner: some View {
        QRScannerView(
            onResult: { result in
                switch result {
                case .success(let value): Task { await coordinator.scannerDidProduce(value) }
                case .failure: coordinator.scannerDidFail()
                }
            },
            onCancel: { coordinator.cancelCameraScan() }
        )
    }
}

#Preview {
    ContentView(coordinator: AppCoordinator())
}
