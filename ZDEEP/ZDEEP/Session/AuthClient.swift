import CryptoKit
import Foundation

@MainActor
final class AuthClient: AuthClientProtocol {
    private struct PairRequest: Encodable {
        let publicCertificate: String
        let carToken: String
    }

    private struct TokenRequest: Encodable {
        let publicCertificate: String
        let carId: String
    }

    private let bindingStore: any BindingStoring
    private let transport: any AuthHTTPTransport
    private let clock: any SessionClock
    private let endpoints: EnvironmentEndpoints
    private var serverClockOffsetMs: Double = 0
    private var currentAttemptId: UUID?
    private var networkAttemptId: UUID?
    private var networkStage: AuthStage = .pair
    private var networkDeadline: Duration = .zero
    private var networkContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var networkTask: Task<Void, Never>?
    private var timeoutHandle: (any CancellationHandle)?

    init(
        bindingStore: any BindingStoring,
        transport: any AuthHTTPTransport,
        clock: any SessionClock,
        endpoints: EnvironmentEndpoints
    ) {
        self.bindingStore = bindingStore
        self.transport = transport
        self.clock = clock
        self.endpoints = endpoints
    }

    func pair(binding: PendingBinding, carToken: String) async throws -> AuthSession {
        let attemptId = beginAttempt()
        return try await withTaskCancellationHandler {
            try await performPair(binding: binding, carToken: carToken, attemptId: attemptId)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAttempt(attemptId) }
        }
    }

    func token(binding: RegisteredBinding) async throws -> AuthSession {
        let attemptId = beginAttempt()
        return try await withTaskCancellationHandler {
            try await performToken(binding: binding, attemptId: attemptId)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAttempt(attemptId) }
        }
    }

    func invalidateCurrentAttempt() {
        guard let attemptId = currentAttemptId else { return }
        cancelAttempt(attemptId)
    }

    private func beginAttempt() -> UUID {
        if let currentAttemptId { cancelAttempt(currentAttemptId) }
        let attemptId = UUID()
        currentAttemptId = attemptId
        return attemptId
    }

    private func performPair(binding: PendingBinding, carToken: String, attemptId: UUID) async throws -> AuthSession {
        defer { finishAttempt(attemptId) }
        try ensureActive(attemptId)
        guard let pairCarId = AuthResponseValidator.carId(fromJWT: carToken) else {
            throw invalidInput(stage: .pair, attemptId: attemptId)
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(PairRequest(publicCertificate: binding.publicCertificate, carToken: carToken))
        } catch {
            throw invalidInput(stage: .pair, attemptId: attemptId)
        }
        return try await execute(
            body: body,
            path: "auth/mobile/pair",
            stage: .pair,
            bindingId: binding.bindingId,
            expectedCarId: nil,
            expectedPairCarId: pairCarId,
            attemptId: attemptId
        )
    }

    private func performToken(binding: RegisteredBinding, attemptId: UUID) async throws -> AuthSession {
        defer { finishAttempt(attemptId) }
        try ensureActive(attemptId)
        let body: Data
        do {
            body = try JSONEncoder().encode(TokenRequest(publicCertificate: binding.publicCertificate, carId: binding.carId))
        } catch {
            throw invalidInput(stage: .token, attemptId: attemptId)
        }
        return try await execute(
            body: body,
            path: "auth/mobile/token",
            stage: .token,
            bindingId: binding.bindingId,
            expectedCarId: binding.carId,
            expectedPairCarId: nil,
            attemptId: attemptId
        )
    }

    private func execute(
        body: Data,
        path: String,
        stage: AuthStage,
        bindingId: UUID,
        expectedCarId: String?,
        expectedPairCarId: String?,
        attemptId: UUID
    ) async throws -> AuthSession {
        try ensureActive(attemptId)
        let timestampMs = clock.wallTimeMs + serverClockOffsetMs
        guard timestampMs.isFinite, timestampMs >= Double(Int64.min), timestampMs <= Double(Int64.max) else {
            throw invalidInput(stage: stage, attemptId: attemptId)
        }
        let timestamp = String(Int64(timestampMs.rounded(.down)))
        let signature: Data
        do {
            signature = try await bindingStore.sign(bindingId: bindingId, bytes: Data("\(timestamp)|".utf8) + body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BindingStoreError {
            throw mapBindingFailure(error, stage: stage, attemptId: attemptId)
        } catch {
            throw localFailure(stage: stage, attemptId: attemptId)
        }
        try ensureActive(attemptId)

        guard let url = endpoint(path: path) else { throw invalidInput(stage: stage, attemptId: attemptId) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Signature")

        let sentAt = clock.now
        let deadline = sentAt + .seconds(30)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request, stage: stage, attemptId: attemptId, deadline: deadline)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AuthFailure {
            throw failure
        } catch let error as URLError where error.code == .cancelled && currentAttemptId != attemptId {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw timeoutFailure(stage: stage, attemptId: attemptId)
        } catch {
            try ensureActive(attemptId)
            throw AuthFailure(
                kind: .network,
                stage: stage,
                attemptId: attemptId,
                message: "The authorization request could not be completed.",
                diagnosticCode: "NETWORK"
            )
        }
        try ensureActive(attemptId)
        guard clock.now < deadline else { throw timeoutFailure(stage: stage, attemptId: attemptId) }

        guard response.statusCode == 200 else {
            if let timestampFailure = AuthResponseValidator.timestampFailure(from: data) {
                serverClockOffsetMs = timestampFailure.serverTimeMs - clock.wallTimeMs
            }
            throw AuthFailure(
                kind: .server,
                stage: stage,
                attemptId: attemptId,
                message: "The authorization server rejected the request.",
                httpStatus: response.statusCode,
                serverCode: AuthResponseValidator.serverCode(from: data),
                diagnosticCode: "HTTP_\(response.statusCode)"
            )
        }
        let session = try AuthResponseValidator.validate(
            data,
            stage: stage,
            attemptId: attemptId,
            expectedCarId: expectedCarId,
            expectedPairCarId: expectedPairCarId,
            sentAt: sentAt,
            receivedAt: clock.now
        )
        try ensureActive(attemptId)
        serverClockOffsetMs = session.serverTimeMs - clock.wallTimeMs
        return session
    }

    private func send(
        _ request: URLRequest,
        stage: AuthStage,
        attemptId: UUID,
        deadline: Duration
    ) async throws -> (Data, HTTPURLResponse) {
        try ensureActive(attemptId)
        return try await withCheckedThrowingContinuation { continuation in
            networkAttemptId = attemptId
            networkStage = stage
            networkDeadline = deadline
            networkContinuation = continuation
            timeoutHandle = clock.schedule(at: deadline) { [weak self] in
                self?.timeoutAttempt(attemptId)
            }
            networkTask = Task { @MainActor [weak self, transport] in
                do {
                    let response = try await transport.send(request)
                    self?.completeNetwork(attemptId, result: .success(response))
                } catch {
                    self?.completeNetwork(attemptId, result: .failure(error))
                }
            }
        }
    }

    private func completeNetwork(
        _ attemptId: UUID,
        result: Result<(Data, HTTPURLResponse), Error>
    ) {
        guard networkAttemptId == attemptId,
              let continuation = networkContinuation,
              currentAttemptId == attemptId else { return }
        if clock.now >= networkDeadline {
            timeoutAttempt(attemptId)
            return
        }
        timeoutHandle?.cancel()
        timeoutHandle = nil
        networkTask = nil
        networkAttemptId = nil
        networkContinuation = nil
        continuation.resume(with: result)
    }

    private func timeoutAttempt(_ attemptId: UUID) {
        guard networkAttemptId == attemptId, let continuation = networkContinuation else { return }
        timeoutHandle?.cancel()
        timeoutHandle = nil
        networkTask?.cancel()
        networkTask = nil
        networkAttemptId = nil
        networkContinuation = nil
        transport.cancelCurrentRequest()
        continuation.resume(throwing: timeoutFailure(stage: networkStage, attemptId: attemptId))
    }

    private func cancelAttempt(_ attemptId: UUID) {
        guard currentAttemptId == attemptId else { return }
        currentAttemptId = nil
        timeoutHandle?.cancel()
        timeoutHandle = nil
        networkTask?.cancel()
        networkTask = nil
        networkAttemptId = nil
        let continuation = networkContinuation
        networkContinuation = nil
        transport.cancelCurrentRequest()
        continuation?.resume(throwing: CancellationError())
    }

    private func ensureActive(_ attemptId: UUID) throws {
        if Task.isCancelled {
            cancelAttempt(attemptId)
            throw CancellationError()
        }
        guard currentAttemptId == attemptId else { throw CancellationError() }
    }

    private func finishAttempt(_ attemptId: UUID) {
        guard currentAttemptId == attemptId else { return }
        timeoutHandle?.cancel()
        timeoutHandle = nil
        networkTask = nil
        networkAttemptId = nil
        networkContinuation = nil
        currentAttemptId = nil
    }

    private func endpoint(path: String) -> URL? {
        let base = endpoints.backend.absoluteString
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return URL(string: prefix + path)
    }

    private func mapBindingFailure(_ error: BindingStoreError, stage: AuthStage, attemptId: UUID) -> Error {
        switch error {
        case .staleBinding:
            return CancellationError()
        case .cryptography:
            return AuthFailure(kind: .local, stage: stage, attemptId: attemptId, message: "The request signature could not be created.", diagnosticCode: "SIGNATURE")
        case .keychain, .invalidRecord, .installMarker, .registrationNotAllowed:
            return localFailure(stage: stage, attemptId: attemptId)
        }
    }

    private func localFailure(stage: AuthStage, attemptId: UUID) -> AuthFailure {
        AuthFailure(kind: .local, stage: stage, attemptId: attemptId, message: "The binding key is unavailable.", diagnosticCode: "KEYCHAIN")
    }

    private func invalidInput(stage: AuthStage, attemptId: UUID) -> AuthFailure {
        AuthFailure(kind: .invalidResponse, stage: stage, attemptId: attemptId, message: "The authorization input was invalid.", diagnosticCode: "BAD_RESPONSE")
    }

    private func timeoutFailure(stage: AuthStage, attemptId: UUID) -> AuthFailure {
        AuthFailure(kind: .timeout, stage: stage, attemptId: attemptId, message: "The authorization request timed out.", diagnosticCode: "TIMEOUT")
    }
}
