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
    func prepareAndLoad(url: URL, reason: WebPreparationReason)
    func invalidateCurrentDocument()
    func recoverFromProcessTermination()
    func close()
}

@MainActor
extension WebSessionHandle {
    func prepareAndLoad(url: URL, reason: WebPreparationReason) {
        (self as? WebSession)?.prepareAndLoad(url: url, reason: reason)
    }
    func invalidateCurrentDocument() {
        (self as? WebSession)?.invalidateCurrentDocument()
    }
    func recoverFromProcessTermination() {
        (self as? WebSession)?.recoverFromProcessTermination()
    }
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
    private let sessionManagerFactory: (AppEnvironment) -> any SessionManaging
    private let usesInjectedSessionManager: Bool
    let ownedClientDataCleaner: OwnedClientDataCleaner
    let eventStore: DiagnosticEventStore
    let sessionClock: any SessionClock
    let bindingStore: any BindingStoring
    private(set) var sessionManager: any SessionManaging
    let cameraPermission: any CameraPermissionProviding
    private var backgroundExecution: BackgroundExecution
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
    var acceptedReadyDocument: WebDocumentIdentity?
    var currentCommittedDocument: WebDocumentIdentity?
    var readinessIdentity: WebDocumentIdentity?
    var readinessURL: URL?
    var readinessReason: WebPreparationReason = .initial
    var readinessTimer: (any CancellationHandle)?
    var pendingReadinessTimerID: UUID?
    var readinessStartedAt: Duration?
    var readinessRemaining: Duration = .seconds(60)
    var readinessAcceptedScreen: WebReadyScreen?
    var didRevealWebSession = false
    var didRecoverProcess = false
    var webSession: (any WebSessionHandle)?
    private var webSessionChanges: AnyCancellable?
#if DEBUG
    private var diagnosticMailbox: DiagnosticMailbox?
#endif

    var endpoints: EnvironmentEndpoints {
        configuration.endpoints(for: environment)
    }

    var preparedWebSessionID: UUID? { webSession?.id }

    func setWebViewOpen(_ open: Bool) {
        isWebViewOpen = open
    }

    var canSwitchEnvironment: Bool { true }

    init(
        configuration: LaunchConfiguration? = nil,
        sessionFactory: (any WebSessionFactory)? = nil,
        bindingStore: (any BindingStoring)? = nil,
        sessionManager: (any SessionManaging)? = nil,
        ownedClientDataCleaner: OwnedClientDataCleaner? = nil,
        eventStore: DiagnosticEventStore? = nil,
        cameraPermission: (any CameraPermissionProviding)? = nil,
        sessionClock suppliedSessionClock: (any SessionClock)? = nil
    ) {
        let configuration = configuration ?? .current
        self.configuration = configuration
        self.environment = configuration.environment
        self.sessionFactory = sessionFactory ?? DefaultWebSessionFactory()
        self.ownedClientDataCleaner = ownedClientDataCleaner ?? OwnedClientDataCleaner()
        let store = bindingStore ?? BindingStore()
        self.bindingStore = store
        self.cameraPermission = cameraPermission ?? SystemCameraPermissionProvider()
        let clock = suppliedSessionClock ?? ContinuousSessionClock()
        self.sessionClock = clock
        let authClient = AuthClient(
            bindingStore: store, transport: URLSessionAuthHTTPTransport(), clock: clock,
            endpoints: configuration.endpoints(for: configuration.environment)
        )
        let injectedManager = sessionManager
        let manager = injectedManager ?? SessionManager(bindingStore: store, authClient: authClient, clock: clock)
        self.sessionManager = manager
        usesInjectedSessionManager = injectedManager != nil
        sessionManagerFactory = { environment in
            if let injectedManager { return injectedManager }
            let switchedClient = AuthClient(
                bindingStore: store, transport: URLSessionAuthHTTPTransport(), clock: clock,
                endpoints: configuration.endpoints(for: environment)
            )
            return SessionManager(bindingStore: store, authClient: switchedClient, clock: clock)
        }
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
        if active { resumeReadinessBudget() } else { pauseReadinessBudget() }
        sessionManager.setActive(active)
        nativeBridge?.setActive(active)
        backgroundExecution.setActive(active)
#if DEBUG
        if active { diagnosticMailbox?.start() } else { diagnosticMailbox?.stop() }
#endif
        if active {
            revealAcceptedWebReadyIfPossible()
            if didReceiveFirstFrame, webSession == nil, canPrepareWebSession { prepareWebSession() }
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
            await retryAuthorization(binding)
        case .web(let url, _, _):
            await retryWebDocument(url: url)
        case .environment(let target, let previous, let stage, let progress):
            guard stage == .cleanup else { return }
            await performEnvironmentCleanup(target: target, previous: previous, remaining: progress.remaining)
        case .fullReset(let progress):
            await performFullReset(remaining: progress.remaining)
        case .cleanup, .none:
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
            readinessSessionDidChange()
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
        acceptedReadyDocument = nil
        currentCommittedDocument = nil
        readinessURL = nil
        readinessIdentity = nil
        readinessAcceptedScreen = nil
        didRevealWebSession = false
        didRecoverProcess = false
        let sessionID = session.id.uuidString
        webSessionChanges = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.sessionDidPublishState(sessionID: sessionID) }
        }
        guard let activeWebSession = session as? WebSession else { return }
        self.activeWebSession = activeWebSession
        activeWebSession.onEvent = { [weak self] event in self?.webSessionDidEmit(event, scenarioID: scenario) }
        let bridge = NativeBridge(session: activeWebSession, manager: sessionManager) { [weak self] identity, readyScreen in
            guard let self,
                  activeWebSession.currentDocument == identity,
                  activeWebSession.isCurrentDocumentCommitted else {
                throw AuthFailure(kind: .local, stage: .web, attemptId: UUID(), message: "Web session is not ready", diagnosticCode: "WEB_READY")
            }
            try self.acceptWebReady(identity, scenarioID: scenario, screen: readyScreen)
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
        switch event {
        case .sessionChanged:
            readinessSessionDidChange()
            revealAcceptedWebReadyIfPossible()
        case .sessionExpired(let failure):
            guard let failure, restoredBinding != nil else { return }
            if case .error(.retryable(_, context: .web)) = screen { return }
            guard !isWebViewOpen else { return }
            screen = .error(.retryable(failure, context: .authorization(restoredBinding!)))
        case .entryFailed, .authorizationActivityChanged:
            break
        }
    }

    static func restoreFailure(_ error: Error) -> AuthFailure {
        AuthFailure(kind: .local, stage: .storage, attemptId: UUID(), message: String(describing: error), diagnosticCode: "KEYCHAIN")
    }

    func switchEnvironment(to newEnvironment: AppEnvironment) async {
        guard canSwitchEnvironment, !isTransitioning, environment != newEnvironment else { return }
        let previous = environment
        let needsCleanup = previous.databaseScope != newEnvironment.databaseScope
        isTransitioning = true
        await beginNewScenarioAndStopSession()
        if needsCleanup {
            await closeForOwnedCleanup()
            let progress = await ownedClientDataCleaner.clean(remaining: OwnedClientDataCleaner.allCategories)
            guard progress.remaining.isEmpty else {
                isTransitioning = false
                screen = .error(.retryable(Self.cleanupFailure(progress), context: .environment(
                    target: newEnvironment, previous: previous, stage: .cleanup, progress: progress
                )))
                return
            }
        }
        await applyEnvironment(newEnvironment, previous: previous, didClearClientData: needsCleanup)
    }

    func resetClientData() async {
        guard !isTransitioning else { return }
        await performFullReset(remaining: OwnedClientDataCleaner.allCategories)
    }

    private func performFullReset(remaining: Set<OwnedDataCategory>) async {
        isTransitioning = true
        eventStore.suspendWrites()
        await beginNewScenarioAndStopSession()
        await closeForOwnedCleanup()
        screen = .logo
        canCancelAuthorization = false

        let progress = await ownedClientDataCleaner.clean(remaining: remaining)
        guard progress.remaining.isEmpty else {
            isTransitioning = false
            screen = .error(.retryable(Self.cleanupFailure(progress), context: .fullReset(progress)))
            return
        }

        eventStore.resumeWrites()
        isTransitioning = false
        restoreAfterCleanup = nil
        restoreAfterCleanupFailure = nil
        eventStore.record(category: "clientData.reset.finished")
        await startNewRestoreScenario()
    }

    private func performEnvironmentCleanup(
        target: AppEnvironment,
        previous: AppEnvironment,
        remaining: Set<OwnedDataCategory>
    ) async {
        guard !isTransitioning, environment == previous else { return }
        isTransitioning = true
        await closeForOwnedCleanup()
        let progress = await ownedClientDataCleaner.clean(remaining: remaining)
        guard progress.remaining.isEmpty else {
            isTransitioning = false
            screen = .error(.retryable(Self.cleanupFailure(progress), context: .environment(
                target: target, previous: previous, stage: .cleanup, progress: progress
            )))
            return
        }
        await applyEnvironment(target, previous: previous, didClearClientData: true)
    }

    private func beginNewScenarioAndStopSession() async {
        cameraScanIntentID = nil
        didConsumeCameraResult = false
        canCancelAuthorization = false
        activeScenarioID = UUID()
        didReceiveFirstFrame = false
        restoredBinding = nil
        await sessionManager.stopAndWait()
    }

    private func closeForOwnedCleanup() async {
#if DEBUG
        let mailbox = diagnosticMailbox
        mailbox?.stop()
        closeCurrentWebSession()
        await mailbox?.waitUntilStopped()
#else
        closeCurrentWebSession()
#endif
    }

    private func applyEnvironment(
        _ target: AppEnvironment,
        previous: AppEnvironment,
        didClearClientData: Bool
    ) async {
        closeCurrentWebSession()
        if !usesInjectedSessionManager {
            managerSubscription?.cancel()
            sessionManager = sessionManagerFactory(target)
            managerSubscription = sessionManager.subscribe { [weak self] event in
                self?.sessionManagerDidEmit(event)
            }
            backgroundExecution = BackgroundExecution(sessionManager: sessionManager)
            sessionManager.setActive(isActive)
        }
        environment = target
        isTransitioning = false
        activeScenarioID = UUID()
        screen = .logo
        eventStore.record(category: "environment.changed", fields: [
            "from": previous.rawValue,
            "to": target.rawValue,
            "clientDataCleared": didClearClientData
        ])
        await startNewRestoreScenario()
    }

    private static func cleanupFailure(_ progress: OwnedCleanupProgress) -> AuthFailure {
        let failure = progress.failures.values.first
        return failure ?? AuthFailure(
            kind: .local, stage: .storage, attemptId: UUID(),
            message: "Application data cleanup is incomplete.", diagnosticCode: "CLEANUP"
        )
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
        cancelReadinessBudget(reset: true)
        readinessIdentity = nil
        readinessURL = nil
        readinessAcceptedScreen = nil
        didRevealWebSession = false
        didRecoverProcess = false
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

}
