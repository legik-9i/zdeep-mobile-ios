import Foundation
import Combine
import SwiftUI

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
    private var webSession: (any WebSessionHandle)?

    var endpoints: EnvironmentEndpoints {
        configuration.endpoints(for: environment)
    }

    init(
        configuration: LaunchConfiguration? = nil,
        sessionFactory: (any WebSessionFactory)? = nil,
        clearClientState: @escaping () async -> Void = {}
    ) {
        let configuration = configuration ?? .current
        self.configuration = configuration
        self.environment = configuration.environment
        self.sessionFactory = sessionFactory ?? DefaultWebSessionFactory()
        self.clearClientState = clearClientState
    }

    func openWebView() {
        guard !isTransitioning, webSession == nil else { return }
        webSession = sessionFactory.makeSession(for: environment, endpoints: endpoints)
        if let activeWebSession = webSession as? WebSession {
            self.activeWebSession = activeWebSession
            activeWebSession.load(url: endpoints.web)
        }
        isWebViewOpen = true
    }

    func closeWebView() {
        guard !isTransitioning else { return }
        closeCurrentWebSession()
    }

    func switchEnvironment(to newEnvironment: AppEnvironment) async {
        guard !isTransitioning, environment != newEnvironment else { return }
        let shouldClearClientState = environment.databaseScope != newEnvironment.databaseScope
        isTransitioning = true
        closeCurrentWebSession()
        if shouldClearClientState {
            await clearClientState()
        }
        environment = newEnvironment
        isTransitioning = false
    }

    func resetClientData() async {
        guard !isTransitioning else { return }
        isTransitioning = true
        closeCurrentWebSession()
        await clearClientState()
        isTransitioning = false
    }

    private func closeCurrentWebSession() {
        webSession?.close()
        webSession = nil
        activeWebSession = nil
        isWebViewOpen = false
    }
}
