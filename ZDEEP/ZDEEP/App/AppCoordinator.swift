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
    @Published var screen: AppScreen = .logo
    @Published var isTransitioning = false
    @Published var canCancelAuthorization = false
    @Published private(set) var activeWebSession: WebSession?
    @Published private(set) var sessionStateRevision = 0

    let configuration: LaunchConfiguration
    private let sessionFactory: any WebSessionFactory
    private let clearClientState: () async -> Void
    private let eventStore: DiagnosticEventStore
    let bindingStore: any BindingStoring
    let sessionManager: any SessionManaging
    let cameraPermission: any CameraPermissionProviding
    private let backgroundExecution: BackgroundExecution
    @Published var activeScenarioID: UUID?
    var isActive = true
    private var didStart = false
    var didReceiveFirstFrame = false
    var restoredBinding: RegisteredBinding?
    var cameraScanIntentID: UUID?
    var didConsumeCameraResult = false
    var cameraPermissionRecheckPending = false
    var restoreAfterCleanup: CleanupNextStep?
    var restoreAfterCleanupFailure: AuthFailure?
#if DEBUG && targetEnvironment(simulator)
    var syntheticAuthorizationUITestEnabled = false
#endif
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

    var canSwitchEnvironment: Bool { false }

    init(
        configuration: LaunchConfiguration? = nil,
        sessionFactory: (any WebSessionFactory)? = nil,
        bindingStore: (any BindingStoring)? = nil,
        sessionManager: (any SessionManaging)? = nil,
        clearClientState: (() async -> Void)? = nil,
        eventStore: DiagnosticEventStore? = nil,
        cameraPermission: (any CameraPermissionProviding)? = nil
    ) {
        let configuration = configuration ?? .current
        self.configuration = configuration
        self.environment = configuration.environment
        self.sessionFactory = sessionFactory ?? DefaultWebSessionFactory()
        self.clearClientState = clearClientState ?? Self.clearOwnedClientState
        let store = bindingStore ?? BindingStore()
        self.bindingStore = store
        self.cameraPermission = cameraPermission ?? SystemCameraPermissionProvider()
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
            canCancelAuthorization = true
            screen = .loading
            Task { @MainActor [weak self] in await self?.refresh(binding) }
        } else {
            canCancelAuthorization = false
            screen = .welcome
        }
        await Task.yield()
    }

    func startNewWelcomeScenario() async {
        closeCurrentWebSession()
        cameraScanIntentID = nil
        didConsumeCameraResult = false
        canCancelAuthorization = false
        restoredBinding = nil
        didReceiveFirstFrame = false
        activeScenarioID = UUID()
        screen = .welcome
    }

    func startOverAfterError(_ presentation: NativeErrorPresentation) async {
        guard case .initialRegistrationFailure = presentation else { return }
        await startNewWelcomeScenario()
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
        if active {
            if cameraScanIntentID == activeScenarioID { cameraPermissionRecheckPending = true }
            Task { await cameraPermissionDidReturn() }
        }
    }

    func retry() async {
        guard case .error(let presentation) = screen else { return }
        switch presentation.retryContext {
        case .restore:
            screen = .logo
            await startNewRestoreScenario()
        case .authorization(let binding):
            canCancelAuthorization = true
            screen = .loading
            await refresh(binding)
        case .web(let url, _, _):
            guard let activeWebSession else { return }
            screen = .loading
            activeWebSession.load(url: url)
        case .cleanup, .environment, .fullReset, .none:
            if case .cleanup(let reason, let next) = presentation.retryContext {
                await retryBindingCleanup(reason: reason, next: next)
            }
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
        let scenarioID = activeScenarioID
        do {
            _ = try await sessionManager.updateSession(binding: binding)
            guard activeScenarioID == scenarioID else { return }
        } catch {
            guard activeScenarioID == scenarioID else { return }
            let failure = sessionManager.lastError ?? Self.restoreFailure(error)
            screen = .error(.retryable(failure, context: .authorization(binding)))
        }
    }

    func startNewRestoreScenario() async {
        didReceiveFirstFrame = false
        do {
            restoredBinding = try await bindingStore.restore()
            let scenario = UUID()
            activeScenarioID = scenario
            if let binding = restoredBinding {
                if restoreAfterCleanup != nil, let failure = restoreAfterCleanupFailure {
                    canCancelAuthorization = false
                    screen = .error(.retryable(failure, context: .restore))
                } else {
                    canCancelAuthorization = true
                    screen = .loading
                    await refresh(binding)
                }
            } else {
                canCancelAuthorization = false
                if case .showRegistrationError(let failure) = restoreAfterCleanup {
                    restoreAfterCleanup = nil
                    restoreAfterCleanupFailure = nil
                    screen = .error(.initialRegistrationFailure(failure))
                } else {
                    restoreAfterCleanup = nil
                    restoreAfterCleanupFailure = nil
                    screen = .welcome
                }
            }
        } catch {
            activeScenarioID = UUID()
            canCancelAuthorization = false
            let failure = Self.restoreFailure(error)
            if restoreAfterCleanup != nil { restoreAfterCleanupFailure = failure }
            screen = .error(.retryable(failure, context: .restore))
        }
    }

    func prepareWebSession() {
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
        case .welcome, .web:
            true
        case .loading:
            restoredBinding != nil
        case .scanner, .cameraPermissionDenied, .cameraPermissionRestricted:
            false
        case .error(let presentation):
            switch presentation.retryContext {
            case .restore, .cleanup: false
            default: true
            }
        case .logo:
            false
        }
    }

    private func sessionManagerDidEmit(_ event: SessionManagerEvent) {
        if case .sessionExpired(let failure) = event, let failure, restoredBinding != nil {
            guard !isWebViewOpen else { return }
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
              let binding = restoredBinding,
              let session = sessionManager.currentSession,
              session.carId == binding.carId else {
            throw AuthFailure(kind: .local, stage: .web, attemptId: identity.attemptId, message: "Web session is not ready", diagnosticCode: "WEB_READY")
        }
        acceptedReadyDocument = identity
        isWebViewOpen = true
        screen = .web
        sessionManager.webViewDidBecomeVisible()
        eventStore.record(category: "webview.opened", operationID: identity.containerId.uuidString)
    }

    static func restoreFailure(_ error: Error) -> AuthFailure {
        AuthFailure(kind: .local, stage: .storage, attemptId: UUID(), message: String(describing: error), diagnosticCode: "KEYCHAIN")
    }

    func switchEnvironment(to newEnvironment: AppEnvironment) async {
        guard canSwitchEnvironment, !isTransitioning, environment != newEnvironment else { return }
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

    func closeCurrentWebSession() {
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
