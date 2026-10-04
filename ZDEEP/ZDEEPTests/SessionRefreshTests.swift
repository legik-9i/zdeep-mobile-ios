import Foundation
import Testing
@testable import ZDEEP

@MainActor
struct SessionRefreshTests {
    @Test func test_refresh_policy_uses_120_second_lead_and_capped_backoff() {
        #expect(SessionRefreshPolicy.refreshDeadline(for: session(deadline: .seconds(900))) == .seconds(780))
        #expect(SessionRefreshPolicy.retryDelay(failureCount: 1) == .seconds(5))
        #expect(SessionRefreshPolicy.retryDelay(failureCount: 2) == .seconds(10))
        #expect(SessionRefreshPolicy.retryDelay(failureCount: 3) == .seconds(20))
        #expect(SessionRefreshPolicy.retryDelay(failureCount: 4) == .seconds(30))
        #expect(SessionRefreshPolicy.retryDelay(failureCount: 5) == .seconds(30))
        #expect(SessionRefreshPolicy.retryDelay(failureCount: 100) == .seconds(30))
    }

    @Test func test_pair_publication_schedules_refresh_120_seconds_before_expiry() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        client.enqueueToken(.success(session(token: "jwt-2", deadline: .seconds(1_800))))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")

        clock.advance(by: .seconds(779))
        await Task.yield()
        #expect(client.tokenCalls == 0)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(1, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 1)
        #expect(manager.currentSession?.accessToken == "jwt-2")
    }

    @Test func test_update_publication_replaces_refresh_deadline() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        client.enqueueToken(.success(session(token: "jwt-2", deadline: .seconds(1_800))))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        #expect(try await manager.updateSession(binding: nil).accessToken == "jwt-2")

        clock.advance(by: .seconds(1_679))
        await Task.yield()
        #expect(client.tokenCalls == 1)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(2, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 2)
    }

    @Test func test_short_ttl_starts_next_update_after_pair_finishes() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(60))))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())

        _ = try await manager.register(binding: pending, carToken: "car-token")
        await waitForTokenCalls(1, client: client)
        await waitUntilIdle(manager)
        #expect(client.pairCalls == 1)
        #expect(client.tokenCalls == 1)
    }

    @Test func test_entry_refresh_failure_keeps_expiry_but_does_not_retry_on_foreground() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        var expirations = 0
        let subscription = manager.subscribe { event in
            if case .sessionExpired = event { expirations += 1 }
        }
        defer { subscription.cancel() }
        _ = try await manager.register(binding: pending, carToken: "car-token")
        clock.advance(by: .seconds(780))
        await waitForTokenCalls(1, client: client)
        await waitUntilIdle(manager)

        manager.setActive(false)
        clock.advance(by: .seconds(120))
        #expect(manager.currentSession == nil)
        manager.setActive(true)
        await Task.yield()
        #expect(client.tokenCalls == 1)
        #expect(expirations == 1)
    }

    @Test func test_working_retry_delays_are_5_10_20_30_30() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(10_000))))
        for _ in 0..<6 { client.enqueueToken(.failure(authFailure())) }
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        manager.webViewDidBecomeVisible()

        await expectAuthFailure(Task { try await manager.updateSession(binding: nil) })
        await waitUntilIdle(manager)
        var elapsedDelays: [Duration] = []
        for delay in [5, 10, 20, 30, 30] {
            let before = clock.now
            let previousCalls = client.tokenCalls
            clock.advance(by: .seconds(delay - 1))
            await Task.yield()
            #expect(client.tokenCalls == previousCalls)
            clock.advance(by: .seconds(1))
            await waitForTokenCalls(previousCalls + 1, client: client)
            await waitUntilIdle(manager)
            elapsedDelays.append(clock.now - before)
        }
        #expect(elapsedDelays == [5, 10, 20, 30, 30].map { .seconds($0) })
        #expect(client.tokenCalls == 6)
    }

    @Test func test_retry_plan_survives_expiry_while_inactive() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        client.enqueueToken(.failure(authFailure()))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        var expirations = 0
        let subscription = manager.subscribe { event in
            if case .sessionExpired = event { expirations += 1 }
        }
        defer { subscription.cancel() }
        _ = try await manager.register(binding: pending, carToken: "car-token")
        manager.webViewDidBecomeVisible()
        await expectAuthFailure(Task { try await manager.updateSession(binding: nil) })
        await waitUntilIdle(manager)
        manager.setActive(false)
        clock.advance(by: .seconds(900))
        #expect(manager.currentSession == nil)
        #expect(expirations == 1)
        #expect(client.tokenCalls == 1)

        manager.setActive(true)
        await waitForTokenCalls(2, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 2)
        #expect(expirations == 1)
    }

    @Test func test_success_resets_working_retry_count() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(10_000))))
        client.enqueueToken(.failure(authFailure()))
        client.enqueueToken(.success(session(token: "jwt-2", deadline: .seconds(10_000))))
        client.enqueueToken(.failure(authFailure()))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        manager.webViewDidBecomeVisible()

        await expectAuthFailure(Task { try await manager.updateSession(binding: nil) })
        await waitUntilIdle(manager)
        clock.advance(by: .seconds(5))
        await waitForTokenCalls(2, client: client)
        await waitUntilIdle(manager)
        #expect(manager.currentSession?.accessToken == "jwt-2")

        await expectAuthFailure(Task { try await manager.updateSession(binding: nil) })
        await waitUntilIdle(manager)
        clock.advance(by: .seconds(4))
        await Task.yield()
        #expect(client.tokenCalls == 3)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(4, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 4)
    }

    @Test func test_joined_consumers_share_one_retry_failure_count() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient(suspendNextToken: true)
        client.enqueuePair(.success(session(deadline: .seconds(10_000))))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        manager.webViewDidBecomeVisible()
        let first = Task { try await manager.updateSession(binding: nil) }
        await waitForTokenCalls(1, client: client)
        let second = Task { try await manager.updateSession(binding: nil) }
        await Task.yield()
        client.resumeToken(.failure(authFailure()))
        await expectAuthFailure(first)
        await expectAuthFailure(second)
        await waitUntilIdle(manager)

        clock.advance(by: .seconds(4))
        await Task.yield()
        #expect(client.tokenCalls == 1)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(2, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 2)
    }

    @Test func test_manual_update_replaces_scheduled_retry() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(10_000))))
        client.enqueueToken(.failure(authFailure()))
        client.enqueueToken(.success(session(token: "jwt-2", deadline: .seconds(10_000))))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        manager.webViewDidBecomeVisible()
        await expectAuthFailure(Task { try await manager.updateSession(binding: nil) })
        await waitUntilIdle(manager)

        #expect(try await manager.updateSession(binding: nil).accessToken == "jwt-2")
        clock.advance(by: .seconds(5))
        await Task.yield()
        #expect(client.tokenCalls == 2)
    }

    @Test func test_background_preserves_absolute_refresh_deadline_and_starts_nothing() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        client.enqueueToken(.success(session(token: "jwt-2", deadline: .seconds(1_800))))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")

        manager.setActive(false)
        clock.advance(by: .seconds(800))
        await Task.yield()
        #expect(client.tokenCalls == 0)
        manager.setActive(true)
        await waitForTokenCalls(1, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 1)
    }

    @Test func test_foreground_keeps_working_mode_and_future_refresh_deadline() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        client.enqueueToken(.failure(authFailure()))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        manager.webViewDidBecomeVisible()
        manager.setActive(false)
        clock.advance(by: .seconds(700))
        #expect(client.tokenCalls == 0)

        manager.setActive(true)
        clock.advance(by: .seconds(79))
        await Task.yield()
        #expect(client.tokenCalls == 0)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(1, client: client)
        await waitUntilIdle(manager)

        manager.webViewDidBecomeVisible()
        clock.advance(by: .seconds(4))
        await Task.yield()
        #expect(client.tokenCalls == 1)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(2, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 2)
    }

    @Test func test_in_flight_update_can_finish_after_entering_background() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let client = SessionRefreshAuthClient(suspendNextToken: true)
        let first = session(deadline: .seconds(10_000))
        client.enqueuePair(.success(first))
        let renewed = session(token: "jwt-2", deadline: .seconds(20_000))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        _ = try await manager.register(binding: pending, carToken: "car-token")
        let update = Task { try await manager.updateSession(binding: nil) }
        await waitForTokenCalls(1, client: client)
        manager.setActive(false)
        client.resumeToken(.success(renewed))

        #expect(try await update.value == renewed)
        #expect(manager.currentSession == renewed)
        #expect(!manager.isAuthorizationInFlight)
    }

    @Test func test_becoming_visible_after_entry_refresh_failure_enables_persistent_retry() async throws {
        let (store, pending) = try await LocalAuthFixture.makePendingBinding()
        let clock = TestSessionClock()
        let client = SessionRefreshAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(10_000))))
        client.enqueueToken(.failure(authFailure()))
        client.enqueueToken(.failure(authFailure()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        _ = try await manager.register(binding: pending, carToken: "car-token")
        await expectAuthFailure(Task { try await manager.updateSession(binding: nil) })
        await waitUntilIdle(manager)

        manager.webViewDidBecomeVisible()
        manager.webViewDidBecomeVisible()
        clock.advance(by: .seconds(4))
        await Task.yield()
        #expect(client.tokenCalls == 1)
        clock.advance(by: .seconds(1))
        await waitForTokenCalls(2, client: client)
        await waitUntilIdle(manager)
        #expect(client.tokenCalls == 2)
    }

    private func waitForTokenCalls(_ count: Int, client: SessionRefreshAuthClient) async {
        for _ in 0..<200 {
            if client.tokenCalls >= count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for token call \(count)")
    }

    private func waitUntilIdle(_ manager: SessionManager) async {
        for _ in 0..<200 {
            if !manager.isAuthorizationInFlight { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for authorization operation to finish")
    }

    private func expectAuthFailure(_ task: Task<AuthSession, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected authorization failure")
        } catch is AuthFailure {
        } catch {
            Issue.record("Expected AuthFailure, got \(error)")
        }
    }

    private func session(token: String = "jwt-1", deadline: Duration) -> AuthSession {
        AuthSession(
            accessToken: token,
            userId: "user-1",
            carId: "car-1",
            expiresAt: "2030-01-01T00:15:00Z",
            deadline: deadline,
            serverTimeMs: 1_000_000,
            attemptId: UUID()
        )
    }

    private func authFailure() -> AuthFailure {
        AuthFailure(
            kind: .network,
            stage: .token,
            attemptId: UUID(),
            message: "Temporary test failure",
            diagnosticCode: "NETWORK"
        )
    }
}

@MainActor
private final class SessionRefreshAuthClient: AuthClientProtocol {
    private var pairResults: [Result<AuthSession, Error>] = []
    private var tokenResults: [Result<AuthSession, Error>] = []
    private var tokenContinuation: CheckedContinuation<AuthSession, Error>?
    private var shouldSuspendToken: Bool
    private(set) var pairCalls = 0
    private(set) var tokenCalls = 0
    private(set) var invalidateCalls = 0

    init(suspendNextToken: Bool = false) { shouldSuspendToken = suspendNextToken }

    func enqueuePair(_ result: Result<AuthSession, Error>) { pairResults.append(result) }
    func enqueueToken(_ result: Result<AuthSession, Error>) { tokenResults.append(result) }

    func pair(binding: PendingBinding, carToken: String) async throws -> AuthSession {
        pairCalls += 1
        guard !pairResults.isEmpty else { throw AuthFailure(kind: .network, stage: .pair, attemptId: UUID(), message: "No test pair response", diagnosticCode: "TEST") }
        return try pairResults.removeFirst().get()
    }

    func token(binding: RegisteredBinding) async throws -> AuthSession {
        tokenCalls += 1
        if shouldSuspendToken {
            shouldSuspendToken = false
            return try await withCheckedThrowingContinuation { tokenContinuation = $0 }
        }
        guard !tokenResults.isEmpty else { throw AuthFailure(kind: .network, stage: .token, attemptId: UUID(), message: "No test token response", diagnosticCode: "TEST") }
        return try tokenResults.removeFirst().get()
    }

    func resumeToken(_ result: Result<AuthSession, Error>) {
        guard let continuation = tokenContinuation else { return }
        tokenContinuation = nil
        do { continuation.resume(returning: try result.get()) }
        catch { continuation.resume(throwing: error) }
    }

    func invalidateCurrentAttempt() { invalidateCalls += 1 }
}
