import Foundation
import Testing
@testable import ZDEEP

@MainActor
struct SessionManagerTests {
    @Test func test_pair_publishes_only_after_registered_save() async throws {
        let (store, pending, storage) = try await makePendingStore()
        storage.pauseNextWrite()
        let clock = TestSessionClock()
        let client = ControlledManagerAuthClient()
        let expected = session()
        client.enqueuePair(.success(expected))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        var published: [AuthSession] = []
        let subscription = manager.subscribe { event in
            if case .sessionChanged(let value) = event { published.append(value) }
        }
        defer { subscription.cancel() }

        let registration = Task { try await manager.register(binding: pending, carToken: "car-token") }
        #expect(await storage.waitUntilWriteIsBlocked())
        #expect(manager.currentSession == nil)
        #expect(published.isEmpty)

        storage.resumeBlockedWrite()
        let result = try await registration.value
        #expect(result == expected)
        #expect(manager.registeredBinding?.bindingId == pending.bindingId)
        #expect(manager.currentSession == expected)
        #expect(published == [expected])
    }

    @Test func test_save_failure_has_no_published_jwt() async throws {
        let (store, pending, storage) = try await makePendingStore()
        storage.failNext("keychain.write")
        let client = ControlledManagerAuthClient()
        client.enqueuePair(.success(session()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        var published = 0
        let subscription = manager.subscribe { event in
            if case .sessionChanged = event { published += 1 }
        }
        defer { subscription.cancel() }

        do {
            _ = try await manager.register(binding: pending, carToken: "car-token")
            Issue.record("A failed registered save must fail registration")
        } catch let failure as RegistrationFailure {
            #expect(failure.failure.stage == .storage)
            #expect(failure.registeredBinding == nil)
        }
        #expect(manager.currentSession == nil)
        #expect(published == 0)
    }

    @Test func test_expiry_during_save_preserves_registered_context() async throws {
        let (store, pending, storage) = try await makePendingStore()
        storage.pauseNextWrite()
        let clock = TestSessionClock()
        let client = ControlledManagerAuthClient()
        client.enqueuePair(.success(session(deadline: .seconds(900))))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
        let registration = Task { try await manager.register(binding: pending, carToken: "car-token") }
        #expect(await storage.waitUntilWriteIsBlocked())
        clock.advance(by: .seconds(900))
        storage.resumeBlockedWrite()

        do {
            _ = try await registration.value
            Issue.record("An expired pair result must not be published")
        } catch let failure as RegistrationFailure {
            #expect(failure.failure.stage == .publication)
            #expect(failure.registeredBinding?.bindingId == pending.bindingId)
        }
        #expect(manager.registeredBinding?.bindingId == pending.bindingId)
        #expect(manager.currentSession == nil)
    }

    @Test func test_concurrent_consumers_share_one_attempt() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient(suspendNextPair: true)
        let expected = session()
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        let first = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await waitForPair(client)
        let second = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await Task.yield()
        client.resumePair(.success(expected))

        #expect(try await first.value == expected)
        #expect(try await second.value == expected)
        #expect(client.pairCalls == 1)
        #expect(!manager.isAuthorizationInFlight)
    }

    @Test func test_update_joins_pair() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient(suspendNextPair: true)
        let expected = session()
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        let registration = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await waitForPair(client)
        let update = Task { try await manager.updateSession(binding: nil) }
        await Task.yield()
        client.resumePair(.success(expected))

        #expect(try await registration.value == expected)
        #expect(try await update.value == expected)
        #expect(client.pairCalls == 1)
        #expect(client.tokenCalls == 0)
    }

    @Test func test_cancelled_consumer_does_not_cancel_shared_auth() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient(suspendNextPair: true)
        let expected = session()
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        let cancelled = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await waitForPair(client)
        let remaining = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled consumer must finish with CancellationError")
        } catch is CancellationError {}
        #expect(manager.isAuthorizationInFlight)

        client.resumePair(.success(expected))
        #expect(try await remaining.value == expected)
        #expect(client.pairCalls == 1)
        #expect(client.invalidateCalls == 0)
    }

    @Test func test_cancel_before_waiter_registration_does_not_start_auth() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient()
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        let caller = Task { try await manager.register(binding: pending, carToken: "car-token") }
        caller.cancel()

        do {
            _ = try await caller.value
            Issue.record("Cancellation before waiter registration must not start an operation")
        } catch is CancellationError {}
        #expect(!manager.isAuthorizationInFlight)
        #expect(client.pairCalls == 0)
    }

    @Test func test_auth_activity_covers_joiners_and_stop() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient(suspendNextPair: true)
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        var activity: [Bool] = []
        let subscription = manager.subscribe { event in
            if case .authorizationActivityChanged(let value) = event { activity.append(value) }
        }
        defer { subscription.cancel() }
        let first = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await waitForPair(client)
        let second = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await Task.yield()
        #expect(manager.isAuthorizationInFlight)
        #expect(activity == [true])

        manager.stop()
        do { _ = try await first.value; Issue.record("stop cancels first waiter") } catch is CancellationError {}
        do { _ = try await second.value; Issue.record("stop cancels joined waiter") } catch is CancellationError {}
        #expect(!manager.isAuthorizationInFlight)
        #expect(activity == [true, false])
    }

    @Test func test_stop_during_registered_save_prevents_late_publication() async throws {
        let (store, pending, storage) = try await makePendingStore()
        storage.pauseNextWrite()
        let client = ControlledManagerAuthClient()
        client.enqueuePair(.success(session()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        var published: [AuthSession] = []
        let subscription = manager.subscribe { event in
            if case .sessionChanged(let value) = event { published.append(value) }
        }
        defer { subscription.cancel() }
        let registration = Task { try await manager.register(binding: pending, carToken: "car-token") }
        #expect(await storage.waitUntilWriteIsBlocked())

        manager.stop()
        storage.resumeBlockedWrite()
        do { _ = try await registration.value; Issue.record("stop cancels registration") } catch is CancellationError {}
        #expect(manager.currentSession == nil)
        #expect(published.isEmpty)
        #expect(client.pairCalls == 1)
    }

    @Test func test_stop_invalidates_client_before_network_cancellation() async throws {
        let (store, pending, _) = try await makePendingStore()
        let log = ManagerClientEventLog()
        let client = ControlledManagerAuthClient(suspendNextPair: true, log: log)
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        let registration = Task { try await manager.register(binding: pending, carToken: "car-token") }
        await waitForPair(client)

        manager.stop()
        do { _ = try await registration.value; Issue.record("stop cancels registration") } catch is CancellationError {}
        let events = log.snapshot()
        #expect(events.firstIndex(of: "invalidate") != nil)
        #expect(events.firstIndex(of: "cancel") != nil)
        #expect(try #require(events.firstIndex(of: "invalidate")) < #require(events.firstIndex(of: "cancel")))
    }

    @Test func test_reentrant_subscriber_stop_blocks_later_delivery() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient()
        let expected = session()
        client.enqueuePair(.success(expected))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        var laterSubscriberSessions: [AuthSession] = []
        let stopping = manager.subscribe { event in
            if case .sessionChanged = event { manager.stop() }
        }
        let later = manager.subscribe { event in
            if case .sessionChanged(let value) = event { laterSubscriberSessions.append(value) }
        }
        defer { stopping.cancel(); later.cancel() }

        do {
            _ = try await manager.register(binding: pending, carToken: "car-token")
            Issue.record("Reentrant stop cancels the current waiter")
        } catch is CancellationError {}
        #expect(laterSubscriberSessions.isEmpty)
        #expect(manager.currentSession == nil)
    }

    @Test func test_identical_jwt_keeps_original_deadline_and_reports_bad_response() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient()
        let first = session(token: "same-jwt", deadline: .seconds(900))
        let later = session(token: "same-jwt", deadline: .seconds(1_800))
        client.enqueuePair(.success(first))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        _ = try await manager.register(binding: pending, carToken: "car-token")
        client.enqueueToken(.success(later))

        do {
            _ = try await manager.updateSession(binding: nil)
            Issue.record("A repeated access token is not a refresh")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .invalidResponse)
            #expect(failure.diagnosticCode == "BAD_RESPONSE")
        }
        #expect(manager.currentSession == first)
        #expect(client.tokenCalls == 1)
    }

    @Test func test_update_rejects_different_registered_binding() async throws {
        let (store, pending, _) = try await makePendingStore()
        let client = ControlledManagerAuthClient()
        client.enqueuePair(.success(session()))
        let manager = SessionManager(bindingStore: store, authClient: client, clock: TestSessionClock())
        _ = try await manager.register(binding: pending, carToken: "car-token")
        let other = RegisteredBinding(bindingId: UUID(), publicCertificate: "other", carId: "car-1")

        do {
            _ = try await manager.updateSession(binding: other)
            Issue.record("A different binding requires stop before replacement")
        } catch let failure as AuthFailure {
            #expect(failure.kind == .local)
        }
        #expect(client.tokenCalls == 0)
    }

    private func makePendingStore() async throws -> (BindingStore, PendingBinding, MemoryKeychainRecordStorage) {
        let storage = MemoryKeychainRecordStorage()
        let store = BindingStore(recordStorage: storage, markerStorage: MemoryInstallMarkerStorage(exists: true))
        #expect(try await store.restore() == nil)
        return (store, try await store.beginRegistration(), storage)
    }

    private func waitForPair(_ client: ControlledManagerAuthClient) async {
        for _ in 0..<100 {
            if client.pairCalls > 0 { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for pair attempt")
    }

    private func session(token: String = "jwt-1", deadline: Duration = .seconds(900)) -> AuthSession {
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
}

@MainActor
private final class ControlledManagerAuthClient: AuthClientProtocol {
    private var pairResults: [Result<AuthSession, Error>] = []
    private var tokenResults: [Result<AuthSession, Error>] = []
    private var pairContinuation: CheckedContinuation<AuthSession, Error>?
    private var shouldSuspendPair: Bool
    private let log: ManagerClientEventLog
    private(set) var pairCalls = 0
    private(set) var tokenCalls = 0
    private(set) var invalidateCalls = 0

    init(suspendNextPair: Bool = false, log: ManagerClientEventLog = ManagerClientEventLog()) {
        shouldSuspendPair = suspendNextPair
        self.log = log
    }

    func enqueuePair(_ result: Result<AuthSession, Error>) { pairResults.append(result) }
    func enqueueToken(_ result: Result<AuthSession, Error>) { tokenResults.append(result) }

    func pair(binding: PendingBinding, carToken: String) async throws -> AuthSession {
        pairCalls += 1
        if shouldSuspendPair {
            shouldSuspendPair = false
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    pairContinuation = continuation
                    if Task.isCancelled {
                        pairContinuation = nil
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                log.append("cancel")
                Task { @MainActor [weak self] in self?.resumePair(.failure(CancellationError())) }
            }
        }
        guard !pairResults.isEmpty else { throw AuthFailure(kind: .network, stage: .pair, attemptId: UUID(), message: "missing fake result", diagnosticCode: "TEST") }
        return try pairResults.removeFirst().get()
    }

    func token(binding: RegisteredBinding) async throws -> AuthSession {
        tokenCalls += 1
        guard !tokenResults.isEmpty else { throw AuthFailure(kind: .network, stage: .token, attemptId: UUID(), message: "missing fake result", diagnosticCode: "TEST") }
        return try tokenResults.removeFirst().get()
    }

    func invalidateCurrentAttempt() {
        invalidateCalls += 1
        log.append("invalidate")
    }

    func resumePair(_ result: Result<AuthSession, Error>) {
        guard let continuation = pairContinuation else { return }
        pairContinuation = nil
        do { continuation.resume(returning: try result.get()) }
        catch { continuation.resume(throwing: error) }
    }
}

nonisolated private final class ManagerClientEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}
