import Foundation

struct WebviewSession: Codable, Equatable {
    let accessToken: String
    let carId: String
    let expiresAt: String

    init(_ session: AuthSession) {
        accessToken = session.accessToken
        carId = session.carId
        expiresAt = session.expiresAt
    }
}

struct BridgeAuthError: Codable, Equatable {
    let kind: String
    let message: String
    let httpStatus: Int?
    let code: String?

    init(_ failure: AuthFailure) {
        kind = failure.kind.rawValue
        message = failure.message
        httpStatus = failure.httpStatus
        code = failure.serverCode
    }

    init(kind: AuthErrorKind = .local, message: String, code: String? = nil) {
        self.kind = kind.rawValue
        self.message = message
        httpStatus = nil
        self.code = code
    }
}

enum SessionRecovery: Encodable, Equatable {
    case ready(WebviewSession)
    case unavailable(reason: String, error: BridgeAuthError?)
    case terminal(reason: String)

    private enum CodingKeys: String, CodingKey { case status, session, reason, error, screen }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready(let session):
            try container.encode("ready", forKey: .status)
            try container.encode(session, forKey: .session)
        case .unavailable(let reason, let error):
            try container.encode("unavailable", forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(error, forKey: .error)
        case .terminal(let reason):
            try container.encode("terminal", forKey: .status)
            try container.encode("session-error", forKey: .screen)
            try container.encode(reason, forKey: .reason)
        }
    }
}

struct BridgeHostState: Codable, Equatable {
    let appState: String
    let sequence: Int
}

enum WebReadyScreen: String, Codable { case content, error }

struct NativeBridgeRequest: Equatable {
    let documentId: String
    let method: String
    let params: AnyHashable?

    init?(documentId: String, method: String, params: Any?) {
        switch method {
        case "getSession", "recoverUnauthorized", "getHostState", "unlinkCar":
            guard params is NSNull else { return nil }
            self.params = nil
        case "reportReady":
            guard let params = params as? [String: Any],
                  params.count == 1,
                  let screen = params["screen"] as? String,
                  WebReadyScreen(rawValue: screen) != nil else { return nil }
            self.params = AnyHashable(screen)
        default:
            return nil
        }
        self.documentId = documentId
        self.method = method
    }
}

struct BridgeReply: Encodable {
    let ok: Bool
    let value: AnyEncodable?
    let error: BridgeAuthError?
    let cancelled: Bool?

    static func success<T: Encodable>(_ value: T) -> Self {
        Self(ok: true, value: AnyEncodable(value), error: nil, cancelled: nil)
    }
    static var cancelledReply: Self { Self(ok: false, value: nil, error: nil, cancelled: true) }
    static func failure(_ error: BridgeAuthError) -> Self {
        Self(ok: false, value: nil, error: error, cancelled: nil)
    }

    private enum CodingKeys: String, CodingKey { case ok, value, error, cancelled }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        if ok { try container.encode(value, forKey: .value) }
        else if let error { try container.encode(error, forKey: .error) }
        else { try container.encode(true, forKey: .cancelled) }
    }
}

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode(to:) }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
