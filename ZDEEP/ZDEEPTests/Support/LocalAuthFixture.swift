import CryptoKit
import Foundation
import Testing
@testable import ZDEEP

@MainActor
final class TestSessionClock: SessionClock {
    private struct Entry {
        let id: UUID
        let deadline: Duration
        let action: @MainActor () -> Void
    }

    private(set) var now: Duration = .zero
    var wallTimeMs: Double
    var onSchedule: (@MainActor () -> Void)?
    private var entries: [Entry] = []
    private var cancelled: Set<UUID> = []
    var activeScheduleCount: Int { entries.filter { !cancelled.contains($0.id) }.count }

    init(wallTimeMs: Double = 1_000_000) {
        self.wallTimeMs = wallTimeMs
    }

    func schedule(at deadline: Duration, action: @escaping @MainActor () -> Void) -> any CancellationHandle {
        let id = UUID()
        entries.append(Entry(id: id, deadline: deadline, action: action))
        let scheduled = onSchedule
        onSchedule = nil
        scheduled?()
        return TestCancellationHandle { [weak self] in self?.cancelled.insert(id) }
    }

    func advance(by duration: Duration) {
        now += duration
        wallTimeMs += Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        let due = entries.filter { $0.deadline <= now && !cancelled.contains($0.id) }
        entries.removeAll { $0.deadline <= now || cancelled.contains($0.id) }
        for entry in due { entry.action() }
    }

    func shiftWall(by milliseconds: Double) {
        wallTimeMs += milliseconds
    }
}

@MainActor
private final class TestCancellationHandle: CancellationHandle {
    private var operation: (() -> Void)?

    init(_ operation: @escaping () -> Void) { self.operation = operation }

    func cancel() {
        operation?()
        operation = nil
    }
}

@MainActor
final class TestAuthHTTPTransport: AuthHTTPTransport {
    typealias Response = (Data, HTTPURLResponse)
    private(set) var requests: [URLRequest] = []
    private var responses: [Response] = []
    private var pending: CheckedContinuation<Response, Error>?
    private(set) var cancelCount = 0
    var clock: TestSessionClock?
    var latency: Duration = .zero
    var suspendNext = false

    func enqueue(_ response: Response) { responses.append(response) }

    func send(_ request: URLRequest) async throws -> Response {
        requests.append(request)
        if suspendNext {
            suspendNext = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        if latency > .zero { clock?.advance(by: latency) }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    func cancelCurrentRequest() { cancelCount += 1 }

    func completePending(with response: Response) {
        pending?.resume(returning: response)
        pending = nil
    }
}

@MainActor
final class RecordingURLSessionAuthTransport: AuthHTTPTransport {
    private let underlying = URLSessionAuthHTTPTransport()
    private(set) var requestTimestamps: [Int64] = []
    private(set) var responseStatuses: [Int] = []
    private(set) var rejectedServerTimeMs: Double?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let header = request.value(forHTTPHeaderField: "X-Timestamp"), let timestamp = Int64(header) {
            requestTimestamps.append(timestamp)
        }
        let (data, response) = try await underlying.send(request)
        responseStatuses.append(response.statusCode)
        if response.statusCode == 401,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["code"] as? String == "TIMESTAMP_OUT_OF_RANGE",
           let number = object["serverTime"] as? NSNumber,
           number.doubleValue.isFinite {
            rejectedServerTimeMs = number.doubleValue
        }
        return (data, response)
    }

    func cancelCurrentRequest() { underlying.cancelCurrentRequest() }
}

nonisolated enum LocalAuthFixture {
    static func makeStore() -> BindingStore {
        BindingStore(
            recordStorage: MemoryKeychainRecordStorage(),
            markerStorage: MemoryInstallMarkerStorage(exists: true)
        )
    }

    static func makePendingBinding() async throws -> (BindingStore, PendingBinding) {
        let store = makeStore()
        _ = try await store.restore()
        return (store, try await store.beginRegistration())
    }

    static func makeJWT(claims: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLEncodedString()
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncodedString()
        return "\(header).\(payload).signature"
    }

    static func successBody(
        userId: String = "user-1",
        carId: String = "car-1",
        serverTime: Double = 1_000_000,
        expiresIn: Any = 900,
        exp: Any = 1_900,
        tokenType: String = "Bearer",
        audience: Any = "zdeep-webview"
    ) throws -> Data {
        let jwt = try makeJWT(claims: ["userId": userId, "carId": carId, "iat": 1_000, "exp": exp, "aud": audience])
        return try JSONSerialization.data(withJSONObject: [
            "accessToken": jwt,
            "tokenType": tokenType,
            "expiresIn": expiresIn,
            "serverTime": serverTime,
            "userId": userId,
            "carId": carId
        ])
    }

    static func httpResponse(status: Int, url: URL = URL(string: "http://localhost:4002/auth/mobile/pair")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    static func carToken(carId: String = "car-1") throws -> String {
        try makeJWT(claims: ["carId": carId, "aud": "zdeep-car", "exp": 1_900])
    }

    static func fetchFreshCarToken() async throws -> String {
        let url = URL(string: "http://localhost:4002/get-tmp-test-car-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["carId": "e0f1c2b3-ce9d-4e0a-95e3-fe4bf1f519f6"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["carId"] as? String == "e0f1c2b3-ce9d-4e0a-95e3-fe4bf1f519f6",
              object["expiresIn"] as? Int == 600,
              let token = object["carToken"] as? String, !token.isEmpty else {
            throw LocalAuthFixtureError.unavailable
        }
        return token
    }
}

enum LocalAuthFixtureError: Error {
    case unavailable
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
