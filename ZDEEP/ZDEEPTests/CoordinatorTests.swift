import Foundation
import Combine
import Testing
@testable import ZDEEP

@MainActor
struct CoordinatorTests {
    @Test func test_none_restores_to_welcome() async {
        let bindingStore = CoordinatorBindingStore(result: .success(nil))
        let manager = CoordinatorSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: FakeWebSessionFactory(), bindingStore: bindingStore, sessionManager: manager
        )

        await coordinator.start()

        #expect(coordinator.screen == .welcome)
        #expect(manager.updateCount == 0)
    }

    @Test func test_registered_starts_one_token_without_welcome_flash() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "certificate", carId: "car")
        let manager = CoordinatorSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: FakeWebSessionFactory(),
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )

        await coordinator.start()

        #expect(coordinator.screen != .welcome)
        #expect(manager.updateCount == 1)
        #expect(coordinator.activeScenarioID != nil)
    }

    @Test func test_restore_error_starts_no_webview() async {
        let manager = CoordinatorSessionManager()
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .failure(BindingStoreError.invalidRecord)), sessionManager: manager
        )

        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }

        #expect(coordinator.screen != .welcome)
        #expect(manager.updateCount == 0)
        #expect(coordinator.isWebPrepared == false)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_restore_retry_resets_native_frame_gate() async throws {
        let factory = FakeWebSessionFactory()
        let store = SequencedCoordinatorBindingStore([
            .failure(.invalidRecord),
            .success(nil)
        ])
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory, bindingStore: store, sessionManager: CoordinatorSessionManager()
        )

        await coordinator.start()
        let failedScenario = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: failedScenario)
        await coordinator.retry()

        let restoredScenario = try #require(coordinator.activeScenarioID)
        #expect(restoredScenario != failedScenario)
        #expect(factory.sessions.isEmpty)
        coordinator.nativeFirstFrameDidRender(scenarioID: restoredScenario)

        #expect(factory.sessions.count == 1)
    }

    @Test func test_web_factory_waits_for_native_frame() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)

        #expect(factory.sessions.isEmpty)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_stale_frame_callback_does_not_create_container() async throws {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)), sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        let stale = try #require(coordinator.activeScenarioID)
        await coordinator.startNewWelcomeScenario()

        coordinator.nativeFirstFrameDidRender(scenarioID: stale)

        #expect(factory.sessions.isEmpty)
    }

    @Test func test_background_defers_web_creation() async throws {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)), sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.setActive(false)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)

        #expect(factory.sessions.isEmpty)
        coordinator.setActive(true)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_web_reveal_keeps_the_prepared_session_instance() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "fixture",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "fixture")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        let originalID = prepared.id
        let identity = WebDocumentIdentity(containerId: originalID, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)

        try coordinator.acceptWebReady(identity, scenarioID: scenarioID)

        #expect(coordinator.isWebViewOpen)
        #expect(coordinator.screen == .web)
        #expect(coordinator.preparedWebSessionID == originalID)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_session_expiry_keeps_visible_web_session_open() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "fixture",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "fixture")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        let identity = WebDocumentIdentity(containerId: prepared.id, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)
        try coordinator.acceptWebReady(identity, scenarioID: scenarioID)

        manager.currentSession = nil
        manager.emit(.sessionExpired(AuthFailure(
            kind: .timeout, stage: .web, attemptId: UUID(), message: "expired", diagnosticCode: "TIMEOUT"
        )))

        #expect(coordinator.screen == .web)
        #expect(coordinator.isWebViewOpen)
        #expect(prepared.closeCount == 0)
        #expect(factory.sessions.count == 1)
    }

    @Test func test_web_ready_rejects_session_for_different_car() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "other-car",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "bound-car")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        let identity = WebDocumentIdentity(containerId: prepared.id, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)

        do {
            try coordinator.acceptWebReady(identity, scenarioID: scenarioID)
            Issue.record("A session for a different car must not reveal the WebView")
        } catch let failure as AuthFailure {
            #expect(failure.diagnosticCode == "WEB_READY")
        }

        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.count == 1)
        #expect(prepared.closeCount == 0)
    }

    @Test func test_reset_action_does_not_show_welcome_when_binding_cleanup_fails() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: true)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()
        #expect(coordinator.activeScenarioID != nil)

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen != .welcome)
        if case .error(let presentation) = coordinator.screen {
            #expect(presentation.retryContext == .cleanup(reason: .rebind, next: .restoreThenWelcome))
        } else {
            Issue.record("A failed reset must remain an actionable cleanup error")
        }
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 1)
    }

    @Test func test_reset_action_shows_welcome_only_after_store_is_empty() async throws {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: false)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen == .welcome)
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 2)
    }

    @Test func test_reset_action_does_not_show_welcome_when_post_reset_restore_fails() async {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "car")
        let store = ResettableCoordinatorBindingStore(binding: binding, resetFails: false, restoreFailsAfterReset: true)
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            bindingStore: store, sessionManager: CoordinatorSessionManager()
        )
        await coordinator.start()

        await coordinator.resetBindingAndShowWelcome()

        #expect(coordinator.screen != .welcome)
        #expect(store.resetCount == 1)
        #expect(store.restoreCount == 2)
    }

    @Test func test_background_execution_balances_scheduled_refresh_and_bridge_recover_without_coordinator_task() {
        let manager = CoordinatorSessionManager()
        let adapter = FakeBackgroundTaskProvider()
        let execution = BackgroundExecution(sessionManager: manager, provider: adapter)
        execution.setActive(false)

        manager.emit(.authorizationActivityChanged(true))
        #expect(adapter.beginCount == 1)
        manager.emit(.authorizationActivityChanged(false))
        #expect(adapter.endCount == 1)

        manager.emit(.authorizationActivityChanged(true))
        #expect(adapter.beginCount == 2)
        manager.emit(.authorizationActivityChanged(false))
        #expect(adapter.endCount == 2)
    }

    @Test func test_background_execution_expiration_blocks_new_tasks_until_foreground() {
        let manager = CoordinatorSessionManager()
        let adapter = FakeBackgroundTaskProvider()
        let execution = BackgroundExecution(sessionManager: manager, provider: adapter)
        execution.setActive(false)
        manager.emit(.authorizationActivityChanged(true))
        adapter.expire()

        #expect(adapter.beginCount == 1)
        #expect(adapter.endCount == 1)
        manager.emit(.authorizationActivityChanged(false))
        manager.emit(.authorizationActivityChanged(true))
        #expect(adapter.beginCount == 1)

        execution.setActive(true)
        execution.setActive(false)
        #expect(adapter.beginCount == 2)
        #expect(adapter.endCount == 1)
    }

    @Test func test_select_prod_does_not_load_web() async {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory
        )

        await coordinator.switchEnvironment(to: .prod)

        #expect(coordinator.environment == .local)
        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_environment_switch_is_blocked_until_auth_manager_rebuild() async {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: manager,
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .test)

        let panel = DebugPanel(
            coordinator: coordinator,
            eventStore: DiagnosticEventStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )
        #expect(coordinator.environment == .local)
        #expect(coordinator.endpoints == AppEnvironment.local.endpoints)
        #expect(manager.updateCount == 0)
        #expect(state.clearCount == 0)
        #expect(factory.sessions.isEmpty)
        #expect(!panel.isEnvironmentPickerEnabled)
    }

    @Test func test_debug_webview_status_tracks_prepared_to_visible_transition() async throws {
        let factory = FakeWebSessionFactory()
        let manager = CoordinatorSessionManager()
        manager.currentSession = AuthSession(
            accessToken: "local-fixture-value", userId: "fixture", carId: "fixture",
            expiresAt: "fixture", deadline: .seconds(600), serverTimeMs: 0, attemptId: UUID()
        )
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "fixture", carId: "fixture")
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]), sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(binding)), sessionManager: manager
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let prepared = try #require(factory.sessions.first)
        #expect(DebugPanel.webViewState(
            isOpen: coordinator.isWebViewOpen, isPrepared: coordinator.isWebPrepared,
            isLoading: prepared.isLoading, hasError: prepared.navigationError != nil
        ) == "Подготовлен (скрыт)")

        let identity = WebDocumentIdentity(containerId: prepared.id, attemptId: UUID(), documentId: UUID())
        coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)
        try coordinator.acceptWebReady(identity, scenarioID: scenarioID)
        #expect(DebugPanel.webViewState(
            isOpen: coordinator.isWebViewOpen, isPrepared: coordinator.isWebPrepared,
            isLoading: prepared.isLoading, hasError: prepared.navigationError != nil
        ) == "Открыт")
    }

    @Test func test_close_then_reopen_creates_new_session() async {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager()
        )

        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }
        coordinator.openWebView()
        let firstSession = factory.sessions[0]
        coordinator.closeWebView()
        coordinator.openWebView()

        #expect(factory.sessions.count == 2)
        #expect(firstSession.closeCount == 1)
        #expect(factory.sessions[0].id != factory.sessions[1].id)
    }

    @Test func test_cross_database_switch_requests_clear() async {
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            clearClientState: { await state.clear() }
        )
        await coordinator.switchEnvironment(to: .test)

        #expect(state.clearCount == 0)
        #expect(coordinator.environment == .local)
        #expect(!coordinator.isWebViewOpen)
    }

    @Test func test_suspended_environment_clear_blocks_open_and_stale_switches() async {
        let factory = FakeWebSessionFactory()
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            sessionFactory: factory,
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .test)
        await coordinator.switchEnvironment(to: .prod)

        let panel = DebugPanel(coordinator: coordinator, eventStore: DiagnosticEventStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        #expect(!panel.isEnvironmentPickerEnabled)

        #expect(coordinator.environment == .local)
        #expect(!coordinator.isTransitioning)
        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.isEmpty)
        #expect(state.clearCount == 0)
    }

    @Test func test_test_prod_switch_preserves_store() async {
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "test"], variables: [:]),
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .prod)

        #expect(state.clearCount == 0)
        #expect(coordinator.environment == .test)
    }

    @Test func test_session_published_state_updates_coordinator_and_journal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiagnosticEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: CoordinatorBindingStore(result: .success(nil)),
            sessionManager: CoordinatorSessionManager(),
            eventStore: store
        )
        await coordinator.start()
        if let scenarioID = coordinator.activeScenarioID { coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID) }
        coordinator.openWebView()
        let session = try #require(factory.sessions.first)
        let url = URL(string: "https://example.test/path?apiKey=private-value")!

        session.publishState(url: url, isLoading: false, navigationError: "failed")
        try await Task.sleep(for: .milliseconds(50))

        let stateEvent = try #require(store.snapshot().last)
        #expect(stateEvent.category == "webview.state")
        #expect(stateEvent.fields["url"] == .string("https://example.test/path?apiKey=%5BREDACTED%5D"))
        #expect(stateEvent.fields["isLoading"] == .bool(false))
        #expect(stateEvent.fields["navigationError"] == .string("failed"))
    }

}

@MainActor
private final class FakeWebSessionFactory: WebSessionFactory {
    private(set) var sessions: [FakeWebSession] = []

    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        let session = FakeWebSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class FakeWebSession: WebSessionHandle, ObservableObject {
    let id = UUID()
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var navigationError: String?
    private(set) var closeCount = 0

    func publishState(url: URL?, isLoading: Bool, navigationError: String?) {
        currentURL = url
        self.isLoading = isLoading
        self.navigationError = navigationError
    }

    func close() {
        closeCount += 1
    }
}

private struct CoordinatorBindingStore: BindingStoring {
    let result: Result<RegisteredBinding?, BindingStoreError>

    func restore() async throws -> RegisteredBinding? { try result.get() }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

private final class ResettableCoordinatorBindingStore: BindingStoring, @unchecked Sendable {
    private var binding: RegisteredBinding?
    private let resetFails: Bool
    private let restoreFailsAfterReset: Bool
    private(set) var resetCount = 0
    private(set) var restoreCount = 0
    private var hasReset = false

    init(binding: RegisteredBinding, resetFails: Bool, restoreFailsAfterReset: Bool = false) {
        self.binding = binding
        self.resetFails = resetFails
        self.restoreFailsAfterReset = restoreFailsAfterReset
    }

    func restore() async throws -> RegisteredBinding? {
        restoreCount += 1
        if hasReset && restoreFailsAfterReset { throw BindingStoreError.invalidRecord }
        return binding
    }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {
        resetCount += 1
        if resetFails { throw BindingStoreError.invalidRecord }
        hasReset = true
        binding = nil
    }
}

private final class SequencedCoordinatorBindingStore: BindingStoring {
    private var results: [Result<RegisteredBinding?, BindingStoreError>]

    init(_ results: [Result<RegisteredBinding?, BindingStoreError>]) {
        self.results = results
    }

    func restore() async throws -> RegisteredBinding? {
        guard !results.isEmpty else { throw BindingStoreError.invalidRecord }
        return try results.removeFirst().get()
    }

    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws {}
}

@MainActor
private final class CoordinatorSessionManager: SessionManaging {
    var currentSession: AuthSession?
    var hasPublishedSession = false
    var lastError: AuthFailure?
    var registeredBinding: RegisteredBinding?
    var isAuthorizationInFlight = false
    private(set) var updateCount = 0
    private var observers: [@MainActor (SessionManagerEvent) -> Void] = []

    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession { throw BindingStoreError.registrationNotAllowed }
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        updateCount += 1
        throw BindingStoreError.registrationNotAllowed
    }
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        observers.append(observer)
        return CoordinatorCancellation()
    }
    func emit(_ event: SessionManagerEvent) { observers.forEach { $0(event) } }
    func webViewDidBecomeVisible() {}
    func setActive(_ active: Bool) {}
    func stop() {}
}

@MainActor
private final class FakeBackgroundTaskProvider: BackgroundTaskProviding {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var expiration: (() -> Void)?

    func begin(expiration: @escaping () -> Void) -> UUID? {
        beginCount += 1
        self.expiration = expiration
        return UUID()
    }
    func end(_ identifier: UUID) { endCount += 1 }
    func expire() { expiration?() }
}

@MainActor
private final class CoordinatorCancellation: CancellationHandle {
    func cancel() {}
}

@MainActor
private final class FakeClientState {
    private(set) var clearCount = 0

    func clear() async {
        clearCount += 1
    }
}

private actor SuspendedClientStateClear {
    private(set) var count = 0
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func clear() async {
        count += 1
        guard count == 1 else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            clearContinuation = continuation
        }
    }

    func waitUntilClearStarts() async {
        guard count == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishClear() {
        clearContinuation?.resume()
        clearContinuation = nil
    }
}
