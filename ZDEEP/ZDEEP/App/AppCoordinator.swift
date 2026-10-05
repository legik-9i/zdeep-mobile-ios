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
struct DefaultWebSessionFactory: WebSessionFactory {
    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        WebSession(trustedURL: endpoints.web)
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var environment: AppEnvironment
    @Published private(set) var isWebViewOpen = false
    @Published private(set) var isWebPrepared = false
    @Published private(set) var screen: AppScreen = .logo
    @Published private(set) var isTransitioning = false
    @Published private(set) var activeWebSession: WebSession?
    @Published private(set) var sessionStateRevision = 0

    private let configuration: LaunchConfiguration
    private let sessionFactory: any WebSessionFactory
    private let clearClientState: () async -> Void
    private let eventStore: DiagnosticEventStore
    private let bindingStore: any BindingStoring
    private let sessionManager: any SessionManaging
    private let backgroundExecution: BackgroundExecution
    @Published private(set) var activeScenarioID: UUID?
    private var isActive = true
    private var didStart = false
    private var didReceiveFirstFrame = false
    private var restoredBinding: RegisteredBinding?
    private var managerSubscription: (any CancellationHandle)?
    private var nativeBridge: NativeBridge?
    private var acceptedReadyDocument: WebDocumentIdentity?
    private var currentCommittedDocument: WebDocumentIdentity?
    private var webSession: (any WebSessionHandle)?
    private var webSessionChanges: AnyCancellable?
#if DEBUG
    private var diagnosticMailbox: DiagnosticMailbox?
#endif

    var endpoints: EnvironmentEndpoints {
        configuration.endpoints(for: environment)
    }

    var preparedWebSessionID: UUID? { webSession?.id }

    init(
        configuration: LaunchConfiguration? = nil,
        sessionFactory: (any WebSessionFactory)? = nil,
        bindingStore: (any BindingStoring)? = nil,
        sessionManager: (any SessionManaging)? = nil,
        clearClientState: (() async -> Void)? = nil,
        eventStore: DiagnosticEventStore? = nil
    ) {
        let configuration = configuration ?? .current
        self.configuration = configuration
        self.environment = configuration.environment
        self.sessionFactory = sessionFactory ?? DefaultWebSessionFactory()
        self.clearClientState = clearClientState ?? Self.clearOwnedClientState
        let store = bindingStore ?? BindingStore()
        self.bindingStore = store
        let clock = ContinuousSessionClock()
        let authClient = AuthClient(
            bindingStore: store, transport: URLSessionAuthHTTPTransport(), clock: clock,
            endpoints: configuration.endpoints(for: configuration.environment)
        )
        let manager = sessionManager ?? SessionManager(bindingStore: store, authClient: authClient, clock: clock)
        self.sessionManager = manager
        backgroundExecution = BackgroundExecution(sessionManager: manager)
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
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        screen = .logo
        managerSubscription = sessionManager.subscribe { [weak self] event in
            self?.sessionManagerDidEmit(event)
        }
        do {
            restoredBinding = try await bindingStore.restore()
        } catch {
            screen = .error(.retryable(Self.restoreFailure(error), context: .restore))
            activeScenarioID = UUID()
            return
        }

        let scenario = UUID()
        activeScenarioID = scenario
        if let binding = restoredBinding {
            screen = .loading
            Task { @MainActor [weak self] in await self?.refresh(binding) }
        } else {
            screen = .welcome
        }
        await Task.yield()
    }

    func startNewWelcomeScenario() async {
        closeCurrentWebSession()
        restoredBinding = nil
        didReceiveFirstFrame = false
        activeScenarioID = UUID()
        screen = .welcome
    }

    func nativeFirstFrameDidRender(scenarioID: UUID) {
        guard activeScenarioID == scenarioID, !didReceiveFirstFrame else { return }
        didReceiveFirstFrame = true
        if isActive, canPrepareWebSession { prepareWebSession() }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        sessionManager.setActive(active)
        nativeBridge?.setActive(active)
        backgroundExecution.setActive(active)
#if DEBUG
        if active { diagnosticMailbox?.start() } else { diagnosticMailbox?.stop() }
#endif
        if active, didReceiveFirstFrame, webSession == nil, canPrepareWebSession { prepareWebSession() }
    }

    func retry() async {
        guard case .error(let presentation) = screen else { return }
        switch presentation.retryContext {
        case .restore:
            screen = .logo
            await startNewRestoreScenario()
        case .authorization(let binding):
            screen = .loading
            await refresh(binding)
        case .web(let url, _, _):
            guard let activeWebSession else { return }
            screen = .loading
            activeWebSession.load(url: url)
        case .cleanup, .environment, .fullReset, .none:
            break
        }
    }

    func openWebView() {
        // Diagnostic preparation never reveals the business WebView.
        guard !isTransitioning, didReceiveFirstFrame, !isWebPrepared else { return }
        prepareWebSession()
    }

    func closeWebView() {
        guard !isTransitioning else { return }
        let operationID = webSession?.id.uuidString
        closeCurrentWebSession()
        if case .web = screen { screen = restoredBinding == nil ? .welcome : .loading }
        eventStore.record(category: "webview.closed", operationID: operationID)
    }

    private func refresh(_ binding: RegisteredBinding) async {
        do {
            _ = try await sessionManager.updateSession(binding: binding)
        } catch {
            guard activeScenarioID != nil else { return }
            let failure = sessionManager.lastError ?? Self.restoreFailure(error)
            screen = .error(.retryable(failure, context: .authorization(binding)))
        }
    }

    private func startNewRestoreScenario() async {
        do {
            restoredBinding = try await bindingStore.restore()
            let scenario = UUID()
            activeScenarioID = scenario
            if let binding = restoredBinding {
                screen = .loading
                await refresh(binding)
            } else {
                screen = .welcome
            }
        } catch {
            activeScenarioID = UUID()
            screen = .error(.retryable(Self.restoreFailure(error), context: .restore))
        }
    }

    private func prepareWebSession() {
        guard isActive, !isTransitioning, webSession == nil, canPrepareWebSession,
              let scenario = activeScenarioID else { return }
        let session = sessionFactory.makeSession(for: environment, endpoints: endpoints)
        webSession = session
        isWebPrepared = true
        let sessionID = session.id.uuidString
        webSessionChanges = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.sessionDidPublishState(sessionID: sessionID) }
        }
        guard let activeWebSession = session as? WebSession else { return }
        self.activeWebSession = activeWebSession
        activeWebSession.onEvent = { [weak self] event in self?.webSessionDidEmit(event, scenarioID: scenario) }
        let bridge = NativeBridge(session: activeWebSession, manager: sessionManager) { [weak self] identity, _ in
            guard let self,
                  activeWebSession.currentDocument == identity,
                  activeWebSession.isCurrentDocumentCommitted else {
                throw AuthFailure(kind: .local, stage: .web, attemptId: UUID(), message: "Web session is not ready", diagnosticCode: "WEB_READY")
            }
            try self.acceptWebReady(identity, scenarioID: scenario)
        }
        nativeBridge = bridge
#if DEBUG
        if configuration.usbDiagnosticsEnabled {
            let mailbox = DiagnosticMailbox(session: activeWebSession, environment: environment, eventStore: eventStore)
            diagnosticMailbox = mailbox
            mailbox.start()
        }
#endif
        activeWebSession.load(url: endpoints.web)
    }

    private var canPrepareWebSession: Bool {
        switch screen {
        case .welcome, .loading, .web:
            true
        case .error(let presentation):
            presentation.retryContext != .restore
        case .logo:
            false
        }
    }

    private func sessionManagerDidEmit(_ event: SessionManagerEvent) {
        if case .sessionExpired(let failure) = event, let failure, restoredBinding != nil {
            screen = .error(.retryable(failure, context: .authorization(restoredBinding!)))
        }
    }

    func webSessionDidEmit(_ event: WebSessionEvent, scenarioID: UUID) {
        guard activeScenarioID == scenarioID else { return }
        switch event {
        case .documentCommitted(let identity):
            guard identity.containerId == webSession?.id else { return }
            currentCommittedDocument = identity
        case .documentPreparing(let identity, _, _):
            if currentCommittedDocument?.containerId == identity.containerId { currentCommittedDocument = nil }
        case .documentFailed(let identity, let failure):
            if currentCommittedDocument == identity { currentCommittedDocument = nil }
            if let binding = restoredBinding {
                screen = .error(.retryable(failure, context: .web(url: endpoints.web, bindingId: binding.bindingId, reason: .explicitRetry)))
            }
        case .processTerminated:
            currentCommittedDocument = nil
        }
    }

    func acceptWebReady(_ identity: WebDocumentIdentity, scenarioID: UUID) throws {
        guard isActive, activeScenarioID == scenarioID,
              webSession?.id == identity.containerId,
              currentCommittedDocument == identity,
              restoredBinding != nil,
              sessionManager.currentSession != nil else {
            throw AuthFailure(kind: .local, stage: .web, attemptId: identity.attemptId, message: "Web session is not ready", diagnosticCode: "WEB_READY")
        }
        acceptedReadyDocument = identity
        isWebViewOpen = true
        screen = .web
        sessionManager.webViewDidBecomeVisible()
        eventStore.record(category: "webview.opened", operationID: identity.containerId.uuidString)
    }

    private static func restoreFailure(_ error: Error) -> AuthFailure {
        AuthFailure(kind: .local, stage: .storage, attemptId: UUID(), message: String(describing: error), diagnosticCode: "KEYCHAIN")
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
        activeWebSession?.onEvent = nil
        nativeBridge = nil
        acceptedReadyDocument = nil
        currentCommittedDocument = nil
        webSession?.close()
        webSession = nil
        activeWebSession = nil
        isWebViewOpen = false
        isWebPrepared = false
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
