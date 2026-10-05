import Foundation
import Combine
import Testing
@testable import ZDEEP

@MainActor
@Suite(.serialized)
struct WebReadinessTests {
    private let url = AppEnvironment.local.endpoints.web

    @Test func test_reveal_requires_ready_valid_session_and_foreground() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)
        let wrongDocument = WebDocumentIdentity(containerId: h.web.id, attemptId: UUID(), documentId: UUID())
        h.coordinator.webSessionDidEmit(.documentCommitted(wrongDocument), scenarioID: h.scenarioID)
        try assertRejectedReady(wrongDocument, h: h)

        h.coordinator.setActive(false)
        h.manager.currentSession = nil
        try assertRejectedReady(identity, h: h)
        h.manager.currentSession = Self.session(carId: h.binding.carId)
        try h.coordinator.acceptWebReady(identity, scenarioID: h.scenarioID, screen: .content)
        #expect(!h.coordinator.isWebViewOpen)
        #expect(h.coordinator.screen == .loading)
        h.coordinator.setActive(true)
        await Task.yield()
        #expect(h.coordinator.screen == .web)
        #expect(h.coordinator.isWebViewOpen)
    }

    @Test func test_readiness_budget_counts_60_active_seconds() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)

        clock.advance(by: .seconds(59))
        #expect(h.coordinator.screen == .loading)
        clock.advance(by: .seconds(1))
        guard case .error(let error) = h.coordinator.screen else {
            Issue.record("Readiness timeout should be a native error")
            return
        }
        #expect(error.retryContext == .web(url: self.url, bindingId: h.binding.bindingId, reason: .initial))
        #expect(identity.containerId == h.web.id)
    }

    @Test func test_new_document_gets_a_fresh_readiness_budget() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        _ = h.beginDocument(reason: .initial)
        clock.advance(by: .seconds(20))

        let navigation = WebDocumentIdentity(containerId: h.web.id, attemptId: UUID(), documentId: UUID())
        h.coordinator.webSessionDidEmit(.documentPreparing(navigation, url, .fullNavigation), scenarioID: h.scenarioID)
        h.coordinator.webSessionDidEmit(.documentCommitted(navigation), scenarioID: h.scenarioID)

        clock.advance(by: .seconds(59))
        #expect(h.coordinator.screen == .loading)
        clock.advance(by: .seconds(1))
        guard case .error(let error) = h.coordinator.screen else {
            Issue.record("A newly prepared document should receive a fresh 60 active seconds")
            return
        }
        #expect(error.retryContext == .web(url: self.url, bindingId: h.binding.bindingId, reason: .fullNavigation))
    }

    @Test func test_old_scenario_readiness_timeout_cannot_override_restore() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        _ = h.beginDocument(reason: .initial)

        await h.coordinator.startNewRestoreScenario()
        #expect(h.coordinator.activeScenarioID != h.scenarioID)
        #expect(h.coordinator.screen == .loading)

        clock.advance(by: .seconds(60))
        #expect(h.coordinator.screen == .loading)
    }

    @Test func test_readiness_budget_pauses_in_background_and_resumes_remaining_time() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        _ = h.beginDocument(reason: .initial)
        clock.advance(by: .seconds(20))
        h.coordinator.setActive(false)
        clock.advance(by: .seconds(90))
        #expect(h.coordinator.screen == .loading)
        h.coordinator.setActive(true)
        await Task.yield()
        clock.advance(by: .seconds(39))
        #expect(h.coordinator.screen == .loading)
        clock.advance(by: .seconds(1))
        guard case .error = h.coordinator.screen else {
            Issue.record("Only the 40 remaining active seconds should expire")
            return
        }
    }

    @Test func test_refresh_and_redirect_do_not_restart_budget() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)
        clock.advance(by: .seconds(25))
        h.manager.emit(.sessionChanged(Self.session(carId: h.binding.carId)))
        h.coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: h.scenarioID)
        #expect(clock.activeScheduleCount == 1)
        clock.advance(by: .seconds(34))
        #expect(h.coordinator.screen == .loading)
        clock.advance(by: .seconds(1))
        guard case .error = h.coordinator.screen else {
            Issue.record("Refresh or redirect must not restart the readiness deadline")
            return
        }
    }

    @Test func test_accepted_ready_cancels_budget_when_view_is_hidden_by_background() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)
        h.coordinator.setActive(false)
        try h.coordinator.acceptWebReady(identity, scenarioID: h.scenarioID, screen: .error)
        clock.advance(by: .seconds(60))
        #expect(h.coordinator.screen == .loading)
        #expect(!h.coordinator.isWebViewOpen)
        #expect(h.web.recoveryCount == 0)
        h.coordinator.setActive(true)
        #expect(h.coordinator.screen == .web)
        #expect(h.coordinator.isWebViewOpen)
        #expect(h.manager.visibleCount == 1)
    }

    @Test func test_auth_retry_after_background_ready_replaces_document() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)
        h.coordinator.setActive(false)
        try h.coordinator.acceptWebReady(identity, scenarioID: h.scenarioID, screen: .content)
        h.manager.currentSession = nil
        h.manager.emit(.sessionExpired(Self.webFailure()))
        guard case .error = h.coordinator.screen else {
            Issue.record("Passive expiry after background-ready should offer explicit auth retry")
            return
        }
        h.manager.nextUpdate = .success(Self.session(carId: h.binding.carId))
        await h.coordinator.retry()
        #expect(h.manager.updateCount == 2)
        #expect(h.web.loadCount == 1)
        #expect(h.web.lastLoadReason == .explicitRetry)
    }

    @Test func test_web_retry_uses_valid_jwt_without_http() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)
        h.coordinator.webSessionDidEmit(.documentFailed(identity, Self.webFailure()), scenarioID: h.scenarioID)
        h.coordinator.screen = .error(.retryable(
            Self.webFailure(), context: .web(url: url, bindingId: h.binding.bindingId, reason: .explicitRetry)
        ))
        let updateCount = h.manager.updateCount
        await h.coordinator.retry()
        #expect(h.manager.updateCount == updateCount)
        #expect(h.web.loadCount == 1)
        #expect(h.web.lastLoadReason == .explicitRetry)
    }

    @Test func test_native_error_survives_passive_auth_failure_and_success() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let failure = Self.webFailure()
        h.coordinator.screen = .error(.retryable(
            failure, context: .web(url: url, bindingId: h.binding.bindingId, reason: .explicitRetry)
        ))
        h.manager.emit(.entryFailed(failure))
        #expect(h.coordinator.screen == .error(.retryable(
            failure, context: .web(url: url, bindingId: h.binding.bindingId, reason: .explicitRetry)
        )))
        h.manager.emit(.sessionChanged(Self.session(carId: h.binding.carId)))
        #expect(h.coordinator.screen == .error(.retryable(
            failure, context: .web(url: url, bindingId: h.binding.bindingId, reason: .explicitRetry)
        )))
    }

    @Test func test_full_navigation_preserves_working_mode_and_shows_cancel() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let original = h.beginDocument(reason: .initial)
        try h.coordinator.acceptWebReady(original, scenarioID: h.scenarioID, screen: .content)
        let visibleCount = h.manager.visibleCount

        let navigation = WebDocumentIdentity(containerId: h.web.id, attemptId: UUID(), documentId: UUID())
        h.coordinator.webSessionDidEmit(.documentPreparing(navigation, url, .fullNavigation), scenarioID: h.scenarioID)

        #expect(h.coordinator.screen == .loading)
        #expect(h.coordinator.canCancelAuthorization)
        #expect(h.manager.visibleCount == visibleCount)
    }

    @Test func test_process_death_gets_one_recovery_then_error() async throws {
        let clock = TestSessionClock()
        let h = try await makeHarness(clock: clock)
        let identity = h.beginDocument(reason: .initial)
        try h.coordinator.acceptWebReady(identity, scenarioID: h.scenarioID, screen: .content)

        h.coordinator.webSessionDidEmit(.processTerminated, scenarioID: h.scenarioID)
        #expect(h.web.recoveryCount == 1)

        let recoveredIdentity = h.beginDocument(reason: .processRecovery)
        try h.coordinator.acceptWebReady(recoveredIdentity, scenarioID: h.scenarioID, screen: .content)
        h.coordinator.webSessionDidEmit(.processTerminated, scenarioID: h.scenarioID)
        #expect(h.web.recoveryCount == 2)
        h.coordinator.webSessionDidEmit(.processTerminated, scenarioID: h.scenarioID)
        guard case .error(let error) = h.coordinator.screen else {
            Issue.record("A repeated process death should require explicit recovery")
            return
        }
        #expect(error.retryContext == .web(url: url, bindingId: h.binding.bindingId, reason: .processRecovery))
    }

    @Test func test_process_death_before_first_reveal_shows_native_error() async throws {
        let h = try await makeHarness(clock: TestSessionClock())
        h.coordinator.webSessionDidEmit(.processTerminated, scenarioID: h.scenarioID)

        guard case .error(let error) = h.coordinator.screen else {
            Issue.record("A process death before first reveal should show a native error")
            return
        }
        #expect(error.retryContext == .web(url: url, bindingId: h.binding.bindingId, reason: .processRecovery))
        #expect(h.web.recoveryCount == 0)
        #expect(!h.coordinator.isWebViewOpen)
    }

    private func makeHarness(clock: TestSessionClock) async throws -> Harness {
        let binding = RegisteredBinding(bindingId: UUID(), publicCertificate: "synthetic", carId: "synthetic-car")
        let manager = ReadinessTestSessionManager(currentSession: Self.session(carId: binding.carId))
        let factory = ReadinessTestWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory,
            bindingStore: ReadinessTestBindingStore(binding: binding),
            sessionManager: manager,
            sessionClock: clock
        )
        await coordinator.start()
        let scenarioID = try #require(coordinator.activeScenarioID)
        coordinator.nativeFirstFrameDidRender(scenarioID: scenarioID)
        let web = try #require(factory.sessions.first)
        return Harness(coordinator: coordinator, manager: manager, factory: factory, web: web, binding: binding, scenarioID: scenarioID, url: url)
    }

    private func assertRejectedReady(_ identity: WebDocumentIdentity, h: Harness) throws {
        do {
            try h.coordinator.acceptWebReady(identity, scenarioID: h.scenarioID, screen: .content)
            Issue.record("Stale, background, or unauthenticated readiness must be rejected")
        } catch is AuthFailure { }
    }

    private static func session(carId: String) -> AuthSession {
        AuthSession(accessToken: "synthetic-token", userId: "synthetic-user", carId: carId,
            expiresAt: "2030-01-01T00:00:00Z", deadline: .seconds(900), serverTimeMs: 0, attemptId: UUID())
    }

    private static func webFailure() -> AuthFailure {
        AuthFailure(kind: .network, stage: .web, attemptId: UUID(), message: "fixture", diagnosticCode: "WEB")
    }

    @MainActor
    private struct Harness {
        let coordinator: AppCoordinator
        let manager: ReadinessTestSessionManager
        let factory: ReadinessTestWebSessionFactory
        let web: ReadinessTestWebSession
        let binding: RegisteredBinding
        let scenarioID: UUID
        let url: URL

        func beginDocument(reason: WebPreparationReason) -> WebDocumentIdentity {
            let identity = WebDocumentIdentity(containerId: web.id, attemptId: UUID(), documentId: UUID())
            coordinator.webSessionDidEmit(.documentPreparing(identity, url, reason), scenarioID: scenarioID)
            coordinator.webSessionDidEmit(.documentCommitted(identity), scenarioID: scenarioID)
            return identity
        }
    }
}

@MainActor
private final class ReadinessTestWebSessionFactory: WebSessionFactory {
    private(set) var sessions: [ReadinessTestWebSession] = []
    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        let session = ReadinessTestWebSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class ReadinessTestWebSession: WebSessionHandle, ObservableObject {
    let id = UUID()
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var navigationError: String?
    private(set) var loadCount = 0
    private(set) var lastLoadReason: WebPreparationReason?
    private(set) var recoveryCount = 0
    func prepareAndLoad(url: URL, reason: WebPreparationReason) { loadCount += 1; lastLoadReason = reason }
    func invalidateCurrentDocument() { }
    func recoverFromProcessTermination() { recoveryCount += 1 }
    func close() { }
}

private final class ReadinessTestBindingStore: BindingStoring, @unchecked Sendable {
    let binding: RegisteredBinding
    init(binding: RegisteredBinding) { self.binding = binding }
    func restore() async throws -> RegisteredBinding? { binding }
    func beginRegistration() async throws -> PendingBinding { throw BindingStoreError.registrationNotAllowed }
    func sign(bindingId: UUID, bytes: Data) async throws -> Data { throw BindingStoreError.registrationNotAllowed }
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding { throw BindingStoreError.registrationNotAllowed }
    func reset() async throws { }
}

@MainActor
private final class ReadinessTestSessionManager: SessionManaging {
    var currentSession: AuthSession?
    var hasPublishedSession = true
    var lastError: AuthFailure?
    var registeredBinding: RegisteredBinding?
    var isAuthorizationInFlight = false
    private(set) var updateCount = 0
    private(set) var visibleCount = 0
    var nextUpdate: Result<AuthSession, AuthFailure>?
    private var observers: [@MainActor (SessionManagerEvent) -> Void] = []

    init(currentSession: AuthSession?) { self.currentSession = currentSession }
    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession { throw BindingStoreError.registrationNotAllowed }
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        updateCount += 1
        if let nextUpdate { self.nextUpdate = nil; currentSession = try nextUpdate.get() }
        guard let currentSession else { throw BindingStoreError.invalidRecord }
        return currentSession
    }
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        observers.append(observer)
        return ReadinessTestCancellationHandle()
    }
    func emit(_ event: SessionManagerEvent) { observers.forEach { $0(event) } }
    func webViewDidBecomeVisible() { visibleCount += 1 }
    func setActive(_ active: Bool) { }
    func stop() { }
}

@MainActor
private final class ReadinessTestCancellationHandle: CancellationHandle { func cancel() { } }
