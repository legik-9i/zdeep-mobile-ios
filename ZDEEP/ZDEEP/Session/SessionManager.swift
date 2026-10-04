import Foundation

nonisolated enum SessionManagerEvent {
    case sessionChanged(AuthSession)
    case sessionExpired(AuthFailure?)
    case entryFailed(AuthFailure)
    case authorizationActivityChanged(Bool)
}

nonisolated struct RegistrationFailure: Error {
    let failure: AuthFailure
    let registeredBinding: RegisteredBinding?
}

@MainActor
protocol SessionManaging: AnyObject {
    var currentSession: AuthSession? { get }
    var lastError: AuthFailure? { get }
    var registeredBinding: RegisteredBinding? { get }
    var isAuthorizationInFlight: Bool { get }
    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle
    func webViewDidBecomeVisible()
    func setActive(_ active: Bool)
    func stop()
}

@MainActor
final class SessionManager: SessionManaging {
    private enum Mode {
        case entry
        case working
    }

    private enum Request {
        case register(PendingBinding, String)
        case update(RegisteredBinding)

        var bindingId: UUID {
            switch self {
            case .register(let binding, _): binding.bindingId
            case .update(let binding): binding.bindingId
            }
        }
    }

    private enum AuthPlanKind {
        case refresh
        case retry
    }

    private struct AuthPlan {
        let id: UUID
        let kind: AuthPlanKind
        let deadline: Duration
    }

    private final class Operation {
        let id: UUID
        let request: Request
        var waiters: [UUID: CheckedContinuation<AuthSession, Error>] = [:]
        var task: Task<Void, Never>?
        var didEmitActivityFinished = false

        init(id: UUID, request: Request) {
            self.id = id
            self.request = request
        }
    }

    private struct Subscriber {
        let id: UUID
        let callback: @MainActor (SessionManagerEvent) -> Void
    }

    private let bindingStore: any BindingStoring
    private let authClient: any AuthClientProtocol
    private let clock: any SessionClock
    private var operation: Operation?
    private var subscribers: [Subscriber] = []
    private var eventToken = UUID()
    private var mode: Mode = .entry
    private var active = true
    private var storedRegisteredBinding: RegisteredBinding?
    private var publishedSession: AuthSession?
    private var lastExpiredAttemptId: UUID?
    private var storedLastError: AuthFailure?
    private var authPlan: AuthPlan?
    private var authPlanHandle: (any CancellationHandle)?
    private var expiryHandle: (any CancellationHandle)?
    private var expiryPlanId: UUID?
    private var retryFailureCount = 0
    private var entryAutoRefreshBlocked = false

    init(bindingStore: any BindingStoring, authClient: any AuthClientProtocol, clock: any SessionClock) {
        self.bindingStore = bindingStore
        self.authClient = authClient
        self.clock = clock
    }

    var currentSession: AuthSession? {
        guard let session = publishedSession else { return nil }
        guard session.deadline > clock.now else {
            if lastExpiredAttemptId != session.attemptId {
                lastExpiredAttemptId = session.attemptId
                let token = eventToken
                emit(.sessionExpired(storedLastError), whileTokenIs: token)
            }
            return nil
        }
        return session
    }

    var lastError: AuthFailure? { storedLastError }
    var registeredBinding: RegisteredBinding? { storedRegisteredBinding }
    var isAuthorizationInFlight: Bool { operation != nil }

    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession {
        if let storedRegisteredBinding, storedRegisteredBinding.bindingId != binding.bindingId {
            let failure = contextFailure(stage: .pair, attemptId: UUID())
            throw RegistrationFailure(failure: failure, registeredBinding: storedRegisteredBinding)
        }
        guard active || operation != nil else {
            throw RegistrationFailure(failure: inactiveFailure(stage: .pair), registeredBinding: storedRegisteredBinding)
        }
        prepareUserInitiatedAttempt()
        return try await request(.register(binding, carToken))
    }

    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        if let operation {
            let requestedBindingId = binding?.bindingId ?? operation.request.bindingId
            guard operation.request.bindingId == requestedBindingId,
                  binding == nil || binding?.bindingId == operation.request.bindingId else {
                throw contextFailure(stage: .token, attemptId: UUID())
            }
            let result = try await waitForExistingOperation(operation.id)
            try Task.checkCancellation()
            guard result.deadline > clock.now else {
                throw expiredReturnFailure(result, isRegistration: false)
            }
            return result
        }

        guard active else { throw inactiveFailure(stage: .token) }

        if let binding, let current = storedRegisteredBinding, current.bindingId != binding.bindingId {
            throw contextFailure(stage: .token, attemptId: UUID())
        }
        guard let effectiveBinding = storedRegisteredBinding ?? binding else {
            throw unavailableFailure(attemptId: UUID())
        }
        prepareUserInitiatedAttempt()
        storedRegisteredBinding = effectiveBinding
        return try await request(.update(effectiveBinding))
    }

    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        let id = UUID()
        subscribers.append(Subscriber(id: id, callback: observer))
        return SessionSubscription { [weak self] in
            self?.subscribers.removeAll { $0.id == id }
        }
    }

    func webViewDidBecomeVisible() {
        let changedToWorking = mode != .working
        mode = .working
        entryAutoRefreshBlocked = false
        if changedToWorking, operation == nil, authPlan == nil, retryFailureCount > 0,
           storedRegisteredBinding != nil {
            scheduleAuthPlan(
                kind: .retry,
                deadline: clock.now + SessionRefreshPolicy.retryDelay(failureCount: retryFailureCount)
            )
        }
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active {
            handleForeground()
        } else {
            authPlanHandle?.cancel()
            authPlanHandle = nil
            cancelExpiryTimer()
        }
    }

    func stop() {
        cancelAuthPlan()
        cancelExpiryTimer()
        let previousOperation = operation
        let shouldEmitActivityFinished = previousOperation.map { !$0.didEmitActivityFinished } ?? false
        previousOperation?.didEmitActivityFinished = true
        eventToken = UUID()
        operation = nil
        storedRegisteredBinding = nil
        publishedSession = nil
        lastExpiredAttemptId = nil
        storedLastError = nil
        retryFailureCount = 0
        entryAutoRefreshBlocked = false
        mode = .entry
        active = true

        if let previousOperation {
            authClient.invalidateCurrentAttempt()
            previousOperation.task?.cancel()
            let waiters = Array(previousOperation.waiters.values)
            previousOperation.waiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }
        if shouldEmitActivityFinished {
            emit(.authorizationActivityChanged(false), whileTokenIs: eventToken)
        }
    }

    private func request(_ request: Request) async throws -> AuthSession {
        let waiterId = UUID()
        let result: AuthSession = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                joinOrStart(request, waiterId: waiterId, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeWaiter(waiterId) }
        }
        try Task.checkCancellation()
        guard result.deadline > clock.now else {
            throw expiredReturnFailure(result, isRegistration: isRegistration(request))
        }
        return result
    }

    private func waitForExistingOperation(_ operationId: UUID) async throws -> AuthSession {
        let waiterId = UUID()
        let result: AuthSession = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard let operation, operation.id == operationId else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operation.waiters[waiterId] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeWaiter(waiterId) }
        }
        try Task.checkCancellation()
        guard result.deadline > clock.now else {
            throw expiredReturnFailure(result, isRegistration: false)
        }
        return result
    }

    private func joinOrStart(
        _ request: Request,
        waiterId: UUID,
        continuation: CheckedContinuation<AuthSession, Error>
    ) {
        if let operation {
            guard canJoin(request, operation: operation) else {
                continuation.resume(throwing: requestFailure(for: request, underlying: contextFailure(stage: requestStage(request), attemptId: operation.id)))
                return
            }
            operation.waiters[waiterId] = continuation
            return
        }

        let newOperation = Operation(id: UUID(), request: request)
        newOperation.waiters[waiterId] = continuation
        operation = newOperation
        eventToken = newOperation.id
        emit(.authorizationActivityChanged(true), whileTokenIs: newOperation.id)
        guard operation?.id == newOperation.id else { return }
        newOperation.task = Task { @MainActor [weak self] in
            await self?.runOperation(newOperation.id)
        }
    }

    private func canJoin(_ request: Request, operation: Operation) -> Bool {
        guard request.bindingId == operation.request.bindingId else { return false }
        switch (request, operation.request) {
        case (.register(let pending, let carToken), .register(let existing, let existingToken)):
            return pending == existing && carToken == existingToken
        case (.update, .register): return true
        case (.update, .update): return true
        case (.register, .update): return false
        }
    }

    private func runOperation(_ operationId: UUID) async {
        guard let current = currentOperation(operationId) else { return }
        do {
            let session: AuthSession
            switch current.request {
            case .register(let binding, let carToken):
                session = try await authClient.pair(binding: binding, carToken: carToken)
                guard isCurrent(operationId) else { return }
                let registered: RegisteredBinding
                do {
                    registered = try await bindingStore.completeRegistration(bindingId: binding.bindingId, carId: session.carId)
                } catch {
                    guard isCurrent(operationId) else { return }
                    let failure = storageFailure(error, attemptId: session.attemptId)
                    storedLastError = failure
                    await deliverFailure(failure, operationId: operationId)
                    guard isCurrent(operationId) else { return }
                    await finish(operationId, result: .failure(RegistrationFailure(failure: failure, registeredBinding: nil)), authFailure: failure)
                    return
                }
                guard isCurrent(operationId) else { return }
                storedRegisteredBinding = registered
                guard session.deadline > clock.now else {
                    let failure = publicationFailure(attemptId: session.attemptId, message: "The session expired before it could be published.")
                    storedLastError = failure
                    await deliverFailure(failure, operationId: operationId)
                    await finish(operationId, result: .failure(RegistrationFailure(failure: failure, registeredBinding: registered)))
                    return
                }
            case .update(let binding):
                session = try await authClient.token(binding: binding)
                guard isCurrent(operationId) else { return }
                guard session.deadline > clock.now else {
                    let failure = publicationFailure(attemptId: session.attemptId, message: "The session expired before it could be published.")
                    storedLastError = failure
                    await deliverFailure(failure, operationId: operationId)
                    await finish(operationId, result: .failure(failure))
                    return
                }
                if let previous = publishedSession, previous.accessToken == session.accessToken {
                    let failure = publicationFailure(attemptId: session.attemptId, message: "The authorization server did not issue a new session token.")
                    storedLastError = failure
                    await deliverFailure(failure, operationId: operationId)
                    await finish(operationId, result: .failure(failure))
                    return
                }
            }

            guard isCurrent(operationId), session.deadline > clock.now else {
                if isCurrent(operationId) {
                    let failure = publicationFailure(attemptId: session.attemptId, message: "The session expired before it could be published.")
                    storedLastError = failure
                    await deliverFailure(failure, operationId: operationId)
                    await finish(operationId, result: .failure(failure))
                }
                return
            }
            publishedSession = session
            lastExpiredAttemptId = nil
            storedLastError = nil
            guard emit(.sessionChanged(session), whileTokenIs: operationId), isCurrent(operationId) else { return }
            await finish(operationId, result: .success(session))
        } catch is CancellationError {
            guard isCurrent(operationId) else { return }
            await finish(operationId, result: .failure(CancellationError()))
        } catch let failure as RegistrationFailure {
            guard isCurrent(operationId) else { return }
            storedLastError = failure.failure
            await deliverFailure(failure.failure, operationId: operationId)
            await finish(operationId, result: .failure(failure))
        } catch let failure as AuthFailure {
            guard isCurrent(operationId) else { return }
            storedLastError = failure
            let result: Error
            if case .register = current.request {
                result = RegistrationFailure(failure: failure, registeredBinding: storedRegisteredBinding)
            } else {
                result = failure
            }
            await deliverFailure(failure, operationId: operationId)
            await finish(operationId, result: .failure(result))
        } catch {
            guard isCurrent(operationId) else { return }
            let failure = AuthFailure(
                kind: .local,
                stage: requestStage(current.request),
                attemptId: operationId,
                message: "The authorization operation could not be completed.",
                diagnosticCode: "LOCAL"
            )
            storedLastError = failure
            let result: Error = isRegistration(current.request)
                ? RegistrationFailure(failure: failure, registeredBinding: storedRegisteredBinding)
                : failure
            await deliverFailure(failure, operationId: operationId)
            await finish(operationId, result: .failure(result))
        }
    }

    private func deliverFailure(_ failure: AuthFailure, operationId: UUID) async {
        guard isCurrent(operationId), mode == .entry else { return }
        _ = emit(.entryFailed(failure), whileTokenIs: operationId)
    }

    private func finish(_ operationId: UUID, result: Result<AuthSession, Error>, authFailure: AuthFailure? = nil) async {
        guard let completed = currentOperation(operationId) else { return }
        if let authFailure { storedLastError = authFailure }
        if !completed.didEmitActivityFinished {
            completed.didEmitActivityFinished = true
            _ = emit(.authorizationActivityChanged(false), whileTokenIs: operationId)
        }
        guard isCurrent(operationId) else { return }

        var finalResult = result
        if case .success(let session) = result, session.deadline <= clock.now {
            let failure = publicationFailure(
                attemptId: session.attemptId,
                message: "The session expired before it could be returned."
            )
            storedLastError = failure
            if publishedSession?.attemptId == session.attemptId, lastExpiredAttemptId != session.attemptId {
                lastExpiredAttemptId = session.attemptId
                _ = emit(.sessionExpired(failure), whileTokenIs: operationId)
                guard isCurrent(operationId) else { return }
            }
            await deliverFailure(failure, operationId: operationId)
            guard isCurrent(operationId) else { return }
            if isRegistration(completed.request) {
                finalResult = .failure(RegistrationFailure(failure: failure, registeredBinding: storedRegisteredBinding))
            } else {
                finalResult = .failure(failure)
            }
        }

        let waiters = Array(completed.waiters.values)
        completed.waiters.removeAll()
        operation = nil
        for waiter in waiters { waiter.resume(with: finalResult) }
        switch finalResult {
        case .success(let session):
            retryFailureCount = 0
            entryAutoRefreshBlocked = false
            storedLastError = nil
            scheduleExpiry(for: session)
            scheduleAuthPlan(kind: .refresh, deadline: SessionRefreshPolicy.refreshDeadline(for: session))
        case .failure(let error):
            recordOperationFailure(error)
        }
    }

    private func prepareUserInitiatedAttempt() {
        cancelAuthPlan()
        entryAutoRefreshBlocked = false
    }

    private func recordOperationFailure(_ error: Error) {
        guard !(error is CancellationError) else { return }
        guard let failure = error as? AuthFailure
                ?? (error as? RegistrationFailure)?.failure else { return }
        storedLastError = failure
        retryFailureCount += 1
        if mode == .working {
            entryAutoRefreshBlocked = false
            scheduleAuthPlan(
                kind: .retry,
                deadline: clock.now + SessionRefreshPolicy.retryDelay(failureCount: retryFailureCount)
            )
        } else {
            entryAutoRefreshBlocked = true
            cancelAuthPlan()
        }
    }

    private func scheduleAuthPlan(kind: AuthPlanKind, deadline: Duration) {
        cancelAuthPlan()
        let plan = AuthPlan(id: UUID(), kind: kind, deadline: deadline)
        authPlan = plan
        activateAuthPlanIfPossible()
    }

    private func activateAuthPlanIfPossible() {
        guard active, let plan = authPlan, authPlanHandle == nil else { return }
        guard plan.deadline > clock.now else {
            authPlan = nil
            beginScheduledUpdate()
            return
        }

        let handle = clock.schedule(at: plan.deadline) { [weak self] in
            guard let self, self.authPlan?.id == plan.id else { return }
            self.authPlanHandle = nil
            guard self.active else { return }
            self.authPlan = nil
            self.beginScheduledUpdate()
        }
        if authPlan?.id == plan.id, active {
            authPlanHandle = handle
        } else {
            handle.cancel()
        }
    }

    private func cancelAuthPlan() {
        authPlanHandle?.cancel()
        authPlanHandle = nil
        authPlan = nil
    }

    private func scheduleExpiry(for session: AuthSession) {
        cancelExpiryTimer()
        guard active else { return }
        let planId = UUID()
        expiryPlanId = planId
        let handle = clock.schedule(at: session.deadline) { [weak self] in
            guard let self, self.expiryPlanId == planId else { return }
            self.expiryHandle = nil
            guard self.publishedSession?.attemptId == session.attemptId else { return }
            _ = self.currentSession
        }
        if expiryPlanId == planId, active, publishedSession?.attemptId == session.attemptId {
            expiryHandle = handle
        } else {
            handle.cancel()
        }
    }

    private func cancelExpiryTimer() {
        expiryPlanId = nil
        expiryHandle?.cancel()
        expiryHandle = nil
    }

    private func beginScheduledUpdate() {
        guard active, operation == nil, let binding = storedRegisteredBinding else { return }
        guard mode == .working || !entryAutoRefreshBlocked else { return }
        let newOperation = Operation(id: UUID(), request: .update(binding))
        operation = newOperation
        eventToken = newOperation.id
        emit(.authorizationActivityChanged(true), whileTokenIs: newOperation.id)
        guard operation?.id == newOperation.id else { return }
        newOperation.task = Task { @MainActor [weak self] in
            await self?.runOperation(newOperation.id)
        }
    }

    private func handleForeground() {
        let session = currentSession
        guard active else { return }
        if let session {
            scheduleExpiry(for: session)
        }
        guard !(mode == .entry && entryAutoRefreshBlocked), operation == nil else { return }
        if authPlan != nil {
            activateAuthPlanIfPossible()
            return
        }
        guard storedRegisteredBinding != nil else { return }
        let refreshDeadline = session.map(SessionRefreshPolicy.refreshDeadline(for:)) ?? clock.now
        if refreshDeadline <= clock.now {
            beginScheduledUpdate()
        } else {
            scheduleAuthPlan(kind: .refresh, deadline: refreshDeadline)
        }
    }

    private func inactiveFailure(stage: AuthStage) -> AuthFailure {
        AuthFailure(
            kind: .local,
            stage: stage,
            attemptId: UUID(),
            message: "A new authorization attempt cannot start while the app is inactive.",
            diagnosticCode: "INACTIVE"
        )
    }

    private func removeWaiter(_ waiterId: UUID) {
        guard let operation, let continuation = operation.waiters.removeValue(forKey: waiterId) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func emit(_ event: SessionManagerEvent, whileTokenIs token: UUID? = nil) -> Bool {
        let currentSubscribers = subscribers
        for subscriber in currentSubscribers {
            if let token, eventToken != token { return false }
            guard subscribers.contains(where: { $0.id == subscriber.id }) else { continue }
            subscriber.callback(event)
        }
        return token == nil || eventToken == token
    }

    private func currentOperation(_ id: UUID) -> Operation? {
        guard let operation, operation.id == id else { return nil }
        return operation
    }

    private func isCurrent(_ id: UUID) -> Bool { operation?.id == id }

    private func requestFailure(for request: Request, underlying: AuthFailure) -> Error {
        if isRegistration(request) {
            return RegistrationFailure(failure: underlying, registeredBinding: storedRegisteredBinding)
        }
        return underlying
    }

    private func requestStage(_ request: Request) -> AuthStage {
        switch request {
        case .register: .pair
        case .update: .token
        }
    }

    private func isRegistration(_ request: Request) -> Bool {
        if case .register = request { return true }
        return false
    }

    private func contextFailure(stage: AuthStage, attemptId: UUID) -> AuthFailure {
        AuthFailure(
            kind: .local,
            stage: stage,
            attemptId: attemptId,
            message: "The requested binding is not the active session binding.",
            diagnosticCode: "BINDING_CONTEXT"
        )
    }

    private func unavailableFailure(attemptId: UUID) -> AuthFailure {
        AuthFailure(
            kind: .local,
            stage: .token,
            attemptId: attemptId,
            message: "No registered binding is available for session update.",
            diagnosticCode: "NO_BINDING"
        )
    }

    private func publicationFailure(attemptId: UUID, message: String) -> AuthFailure {
        AuthFailure(
            kind: .invalidResponse,
            stage: .publication,
            attemptId: attemptId,
            message: message,
            diagnosticCode: "BAD_RESPONSE"
        )
    }

    private func expiredReturnFailure(_ session: AuthSession, isRegistration: Bool) -> Error {
        let token = eventToken
        guard publishedSession?.attemptId == session.attemptId else { return CancellationError() }
        let failure = publicationFailure(
            attemptId: session.attemptId,
            message: "The session expired before it could be returned."
        )
        storedLastError = failure
        if lastExpiredAttemptId != session.attemptId {
            lastExpiredAttemptId = session.attemptId
            guard emit(.sessionExpired(failure), whileTokenIs: token),
                  publishedSession?.attemptId == session.attemptId else {
                return CancellationError()
            }
        }
        guard eventToken == token, publishedSession?.attemptId == session.attemptId else {
            return CancellationError()
        }
        if isRegistration {
            return RegistrationFailure(failure: failure, registeredBinding: storedRegisteredBinding)
        }
        return failure
    }

    private func storageFailure(_ error: Error, attemptId: UUID) -> AuthFailure {
        AuthFailure(
            kind: .local,
            stage: .storage,
            attemptId: attemptId,
            message: "The registered binding could not be saved.",
            diagnosticCode: "KEYCHAIN"
        )
    }
}

@MainActor
private final class SessionSubscription: CancellationHandle {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}
