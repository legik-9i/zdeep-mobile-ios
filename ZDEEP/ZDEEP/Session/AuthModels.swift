import Foundation

nonisolated struct AuthSession: Equatable, Sendable {
    let accessToken: String
    let userId: String
    let carId: String
    let expiresAt: String
    let deadline: Duration
    let serverTimeMs: Double
    let attemptId: UUID
}

nonisolated enum AuthStage: String, Sendable {
    case pair
    case token
    case storage
    case publication
    case web
}

nonisolated enum AuthErrorKind: String, Codable, Sendable {
    case network
    case timeout
    case server
    case local
    case invalidResponse = "invalid-response"
}

nonisolated struct AuthFailure: Error, Equatable, Sendable {
    let kind: AuthErrorKind
    let stage: AuthStage
    let attemptId: UUID
    let message: String
    let httpStatus: Int?
    let serverCode: String?
    let diagnosticCode: String

    init(
        kind: AuthErrorKind,
        stage: AuthStage,
        attemptId: UUID,
        message: String,
        httpStatus: Int? = nil,
        serverCode: String? = nil,
        diagnosticCode: String
    ) {
        self.kind = kind
        self.stage = stage
        self.attemptId = attemptId
        self.message = message
        self.httpStatus = httpStatus
        self.serverCode = serverCode
        self.diagnosticCode = diagnosticCode
    }
}

@MainActor
protocol CancellationHandle: AnyObject {
    func cancel()
}

@MainActor
protocol AuthClientProtocol: AnyObject {
    func pair(binding: PendingBinding, carToken: String) async throws -> AuthSession
    func token(binding: RegisteredBinding) async throws -> AuthSession
    func invalidateCurrentAttempt()
}
