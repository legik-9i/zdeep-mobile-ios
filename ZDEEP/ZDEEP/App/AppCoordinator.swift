import Foundation
import Combine
import SwiftUI
import WebKit

@MainActor
protocol WebSessionHandle: AnyObject, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var id: UUID { get }
    var currentURL: URL? { get }
    var isLoading: Bool { get }
    var navigationError: String? { get }
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
    @Published private(set) var sessionStateRevision = 0

    private let configuration: LaunchConfiguration
    private let sessionFactory: any WebSessionFactory
    private let clearClientState: () async -> Void
    private let eventStore: DiagnosticEventStore
    private var webSession: (any WebSessionHandle)?
    private var webSessionChanges: AnyCancellable?
#if DEBUG
    private var diagnosticMailbox: DiagnosticMailbox?
#endif

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
#if DEBUG
        if configuration.usbDiagnosticsEnabled {
            DiagnosticMailbox.removeStaleHandshake()
        }
#endif
        eventStore.record(category: "app.started", fields: [
            "environment": configuration.environment.rawValue,
            "webURL": configuration.endpoints(for: configuration.environment).web.absoluteString,
            "backendURL": configuration.endpoints(for: configuration.environment).backend.absoluteString
        ])
#if DEBUG
        if configuration.usbDiagnosticsOpenWebViewEnabled {
            openWebView()
        }
#endif
    }

    func openWebView() {
        guard !isTransitioning, webSession == nil else { return }
        let session = sessionFactory.makeSession(for: environment, endpoints: endpoints)
        webSession = session
        let sessionID = session.id.uuidString
        webSessionChanges = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sessionDidPublishState(sessionID: sessionID)
            }
        }
        if let activeWebSession = webSession as? WebSession {
            self.activeWebSession = activeWebSession
            activeWebSession.load(url: endpoints.web)
#if DEBUG
            if configuration.usbDiagnosticsEnabled {
                let mailbox = DiagnosticMailbox(session: activeWebSession, environment: environment, eventStore: eventStore)
                diagnosticMailbox = mailbox
                mailbox.start()
            }
#endif
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
#if DEBUG
        diagnosticMailbox?.stop()
        diagnosticMailbox = nil
#endif
        webSessionChanges?.cancel()
        webSessionChanges = nil
        webSession?.close()
        webSession = nil
        activeWebSession = nil
        isWebViewOpen = false
    }

    private func sessionDidPublishState(sessionID: String) {
        guard let session = webSession, session.id.uuidString == sessionID else { return }
        sessionStateRevision += 1
        eventStore.record(category: "webview.state", operationID: sessionID, fields: [
            "url": session.currentURL?.absoluteString as Any? ?? NSNull(),
            "isLoading": session.isLoading,
            "navigationError": session.navigationError as Any? ?? NSNull()
        ])
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
