import Foundation
import Combine
import SwiftUI
import WebKit

@MainActor
protocol WebSessionHandle: AnyObject {
    var id: UUID { get }
    func close()
}

@MainActor
protocol WebSessionFactory {
    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var environment: AppEnvironment
    @Published private(set) var isWebViewOpen = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var activeWebSession: WebSession?

    private let configuration: LaunchConfiguration
    private let sessionFactory: any WebSessionFactory
    private let clearClientState: () async -> Void
    private let eventStore: DiagnosticEventStore
    private var webSession: (any WebSessionHandle)?

    var endpoints: EnvironmentEndpoints {
        configuration.endpoints(for: environment)
    }

    init(
        configuration: LaunchConfiguration? = nil,
        sessionFactory: (any WebSessionFactory)? = nil,
        clearClientState: (() async -> Void)? = nil,
        eventStore: DiagnosticEventStore? = nil
    ) {
        let configuration = configuration ?? .current
        self.configuration = configuration
        self.environment = configuration.environment
        self.sessionFactory = sessionFactory ?? DefaultWebSessionFactory()
        self.clearClientState = clearClientState ?? Self.clearOwnedClientState
        let eventStore = eventStore ?? .shared
        self.eventStore = eventStore
        eventStore.record(category: "app.started", fields: [
            "environment": configuration.environment.rawValue,
            "webURL": configuration.endpoints(for: configuration.environment).web.absoluteString,
            "backendURL": configuration.endpoints(for: configuration.environment).backend.absoluteString
        ])
    }

    func openWebView() {
        guard !isTransitioning, webSession == nil else { return }
        webSession = sessionFactory.makeSession(for: environment, endpoints: endpoints)
        if let activeWebSession = webSession as? WebSession {
            self.activeWebSession = activeWebSession
            activeWebSession.load(url: endpoints.web)
        }
        isWebViewOpen = true
        eventStore.record(category: "webview.opened", operationID: webSession?.id.uuidString, fields: ["url": endpoints.web.absoluteString])
    }

    func closeWebView() {
        guard !isTransitioning else { return }
        let operationID = webSession?.id.uuidString
        closeCurrentWebSession()
        eventStore.record(category: "webview.closed", operationID: operationID)
    }

    func switchEnvironment(to newEnvironment: AppEnvironment) async {
        guard !isTransitioning, environment != newEnvironment else { return }
        let shouldClearClientState = environment.databaseScope != newEnvironment.databaseScope
        let previousEnvironment = environment
        isTransitioning = true
        closeCurrentWebSession()
        if shouldClearClientState {
            await clearClientState()
        }
        environment = newEnvironment
        isTransitioning = false
        eventStore.record(category: "environment.changed", fields: [
            "from": previousEnvironment.rawValue,
            "to": newEnvironment.rawValue,
            "clientDataCleared": shouldClearClientState
        ])
    }

    func resetClientData() async {
        guard !isTransitioning else { return }
        isTransitioning = true
        eventStore.record(category: "clientData.reset.started")
        closeCurrentWebSession()
        await clearClientState()
        isTransitioning = false
        eventStore.record(category: "clientData.reset.finished")
    }

    private func closeCurrentWebSession() {
        webSession?.close()
        webSession = nil
        activeWebSession = nil
        isWebViewOpen = false
    }

    private static func clearOwnedClientState() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
    }
}
