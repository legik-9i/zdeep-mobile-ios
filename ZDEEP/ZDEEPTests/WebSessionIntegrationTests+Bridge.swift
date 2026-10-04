import Foundation
import Network
import Testing
import WebKit
@testable import ZDEEP

@MainActor
extension WebSessionIntegrationTests {
    @Test func test_bridge_fixture_exposes_all_methods_at_document_start() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        let session = WebSession(trustedURL: url)
        var readyScreens: [WebReadyScreen] = []
        let bridge = NativeBridge(session: session, manager: manager) { _, screen in readyScreens.append(screen) }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        #expect(try await session.executeJavaScript("window.__bridgeAtDocumentStart", timeout: .seconds(5)) == .bool(true))
        let hostState = try await session.executeJavaScript("window.ZdeepNative.getHostState()", timeout: .seconds(5))
        #expect(hostState == .object(["appState": .string("foreground"), "sequence": .number(0)]))

        manager.currentSession = nil
        let rejectedReady = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'content'}).then(() => 'accepted').catch(error => error.code)",
            timeout: .seconds(5)
        )
        #expect(rejectedReady == .string("BRIDGE_NOT_READY"))
        manager.currentSession = BridgeTestSessionManager.fixtureSession

        let ready = try await session.executeJavaScript("window.ZdeepNative.reportReady({screen:'content'}).then(() => 'accepted')", timeout: .seconds(5))
        #expect(ready == .string("accepted"))
        #expect(readyScreens == [.content])
        _ = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'error'}).then(() => true)", timeout: .seconds(5)
        )
        #expect(readyScreens == [.content])

        #expect(try await session.executeJavaScript("typeof window.ZdeepNative.documentId", timeout: .seconds(5)) == .string("undefined"))
        let invalidSource = try await session.executeJavaScript(
            "window.webkit.messageHandlers.zdeepNative.postMessage({documentId:'00000000-0000-0000-0000-000000000001',method:'getSession',params:null}).then(reply => reply.ok === false && reply.error.code === 'BRIDGE_INVALID_REQUEST')",
            timeout: .seconds(5)
        )
        #expect(invalidSource == .bool(true))

        manager.currentSession = BridgeTestSessionManager.session(token: "event-token")
        manager.emit(.sessionChanged(BridgeTestSessionManager.session(token: "event-token")))
        _ = try await session.waitForJavaScript(
            "window.__bridgeSessionEvents.some(event => event.session?.accessToken === 'event-token')",
            equals: .bool(true), timeout: .seconds(5)
        )
        let sessionEvent = try await session.executeJavaScript(
            "window.__bridgeSessionEvents.find(event => event.session?.accessToken === 'event-token')", timeout: .seconds(5)
        )
        #expect(sessionEvent == .object(["type": .string("sessionChanged"), "session": .object([
            "accessToken": .string("event-token"), "carId": .string("fixture-car"),
            "expiresAt": .string("2030-01-01T00:00:00Z")
        ])]))

        bridge.setActive(false)
        _ = try await session.waitForJavaScript("window.__bridgeHostEvents.length", equals: .number(1), timeout: .seconds(5))
        let lifecycleEvent = try await session.executeJavaScript("window.__bridgeHostEvents[0]", timeout: .seconds(5))
        #expect(lifecycleEvent == .object(["type": .string("lifecycle"), "appState": .string("background"), "sequence": .number(1)]))
        let backgroundState = try await session.executeJavaScript("window.ZdeepNative.getHostState()", timeout: .seconds(5))
        #expect(backgroundState == .object(["appState": .string("background"), "sequence": .number(1)]))
        bridge.publishRefresh()
        _ = try await session.waitForJavaScript("window.__bridgeHostEvents.length", equals: .number(2), timeout: .seconds(5))
        let refreshEvent = try await session.executeJavaScript("window.__bridgeHostEvents[1]", timeout: .seconds(5))
        #expect(refreshEvent == .object(["type": .string("refresh"), "sequence": .number(2)]))
        let refreshedState = try await session.executeJavaScript("window.ZdeepNative.getHostState()", timeout: .seconds(5))
        #expect(refreshedState == .object(["appState": .string("background"), "sequence": .number(2)]))

        let recovery = try await session.executeJavaScript("window.ZdeepNative.recoverUnauthorized()", timeout: .seconds(5))
        guard case .object(let recoveryFields) = recovery else {
            Issue.record("Expected unavailable recovery result")
            return
        }
        #expect(recoveryFields["status"] == .string("unavailable"))
        #expect(recoveryFields["reason"] == .string("temporary"))
        #expect(recoveryFields["error"] != nil)
        #expect(manager.updateCalls == 1)

        manager.currentSession = BridgeTestSessionManager.fixtureSession
        let sessionValue = try await session.executeJavaScript("window.ZdeepNative.getSession()", timeout: .seconds(5))
        #expect(sessionValue == .object([
            "accessToken": .string("fixture-token"), "carId": .string("fixture-car"),
            "expiresAt": .string("2030-01-01T00:00:00Z")
        ]))

        manager.currentSession = nil
        manager.emit(.sessionExpired(nil))
        _ = try await session.waitForJavaScript(
            "window.__bridgeSessionEvents.some(event => event.type === 'sessionExpired')",
            equals: .bool(true), timeout: .seconds(5)
        )
        let expiredEvent = try await session.executeJavaScript(
            "window.__bridgeSessionEvents.find(event => event.type === 'sessionExpired')", timeout: .seconds(5)
        )
        #expect(expiredEvent == .object(["type": .string("sessionExpired")]))
        let repeatedReady = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'error'}).then(() => 'accepted')", timeout: .seconds(5)
        )
        #expect(repeatedReady == .string("accepted"))
        #expect(readyScreens == [.content])

        manager.currentSession = BridgeTestSessionManager.session(token: "current-token")
        manager.emit(.sessionChanged(BridgeTestSessionManager.session(token: "stale-token")))
        session.reload()
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        _ = try await session.waitForJavaScript(
            "window.__bridgeSessionEvents.some(event => event.session?.accessToken === 'current-token')",
            equals: .bool(true), timeout: .seconds(5)
        )
        let reloadedEvents = try await session.executeJavaScript("window.__bridgeSessionEvents", timeout: .seconds(5))
        #expect(reloadedEvents == .array([.object(["type": .string("sessionChanged"), "session": .object([
            "accessToken": .string("current-token"), "carId": .string("fixture-car"),
            "expiresAt": .string("2030-01-01T00:00:00Z")
        ])])]))
    }

    @Test func test_get_session_waiter_survives_activity_and_expired_session_rejects() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        manager.isAuthorizationInFlight = true
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        _ = try await session.executeJavaScript("window.ZdeepNative.getSession().then(() => { window.__waiter = 'resolved' }).catch(() => { window.__waiter = 'rejected' }); true", timeout: .seconds(5))
        manager.emit(.authorizationActivityChanged(true))
        manager.currentSession = BridgeTestSessionManager.fixtureSession
        manager.isAuthorizationInFlight = false
        manager.emit(.sessionChanged(BridgeTestSessionManager.fixtureSession))
        _ = try await session.waitForJavaScript("window.__waiter", equals: .string("resolved"), timeout: .seconds(5))

        manager.currentSession = nil
        manager.hasPublishedSession = true
        manager.emit(.sessionExpired(nil))
        let expired = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(() => 'resolved').catch(error => error.code)", timeout: .seconds(5)
        )
        #expect(expired == .string("SESSION_EXPIRED"))
    }

    @Test func test_recovery_after_expired_published_session_attempts_refresh_once() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        manager.hasPublishedSession = true
        manager.updateFailure = BridgeTestSessionManager.failure(code: "NETWORK")
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        let value = try await session.executeJavaScript("window.ZdeepNative.recoverUnauthorized()", timeout: .seconds(5))
        guard case .object(let fields) = value else { Issue.record("Expected recovery DTO"); return }
        #expect(fields["status"] == .string("unavailable"))
        #expect(fields["reason"] == .string("expired"))
        #expect(manager.updateCalls == 1)
    }

    @Test func test_recovery_classifies_only_car_identity_mismatch_as_terminal() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        manager.updateFailure = BridgeTestSessionManager.failure(code: "BAD_RESPONSE")
        let malformed = try await session.executeJavaScript("window.ZdeepNative.recoverUnauthorized()", timeout: .seconds(5))
        guard case .object(let malformedFields) = malformed else { Issue.record("Expected recovery DTO"); return }
        #expect(malformedFields["status"] == .string("unavailable"))
        #expect(malformedFields["reason"] == .string("temporary"))

        manager.updateFailure = BridgeTestSessionManager.failure(code: "CAR_IDENTITY_MISMATCH")
        let mismatch = try await session.executeJavaScript("window.ZdeepNative.recoverUnauthorized()", timeout: .seconds(5))
        guard case .object(let mismatchFields) = mismatch else { Issue.record("Expected recovery DTO"); return }
        #expect(mismatchFields["status"] == .string("terminal"))
        #expect(mismatchFields["reason"] == .string("authorization"))
        #expect(manager.updateCalls == 2)
    }

    @Test func test_document_replacement_cancels_session_waiter_and_frames_cannot_call_bridge() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let foreignServer = try BridgeFixtureServer(html: #"<!doctype html><script>window.webkit.messageHandlers.zdeepNative.postMessage({documentId:'00000000-0000-0000-0000-000000000001',method:'getSession',params:null}).then(reply => parent.postMessage({type:'bridge-reply',code:reply.error.code}, '*'))</script>"#)
        let foreignURL = try await foreignServer.start()
        var foreignComponents = try #require(URLComponents(url: foreignURL, resolvingAgainstBaseURL: false))
        foreignComponents.host = "127.0.0.1"
        let foreignOriginURL = try #require(foreignComponents.url)
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        manager.isAuthorizationInFlight = true
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        #expect(try await session.executeJavaScript(
            "typeof document.querySelector('#same-origin-frame').contentWindow.ZdeepNative", timeout: .seconds(5)
        ) == .string("undefined"))
        _ = try await session.executeJavaScript(
            "const frame=document.querySelector('#same-origin-frame').contentWindow; frame.webkit.messageHandlers.zdeepNative.postMessage({documentId:'00000000-0000-0000-0000-000000000001',method:'getSession',params:null}).then(reply => window.__frameReply=reply.error.code); true",
            timeout: .seconds(5)
        )
        _ = try await session.waitForJavaScript("window.__frameReply", equals: .string("BRIDGE_INVALID_REQUEST"), timeout: .seconds(5))
        _ = try await session.executeJavaScript("const frame=document.createElement('iframe'); frame.src='\(foreignOriginURL.absoluteString)'; document.body.appendChild(frame); true", timeout: .seconds(5))
        _ = try await session.waitForJavaScript("window.__foreignFrameReply", equals: .string("BRIDGE_INVALID_REQUEST"), timeout: .seconds(5))

        _ = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(() => { window.__oldWaiter = 'resolved' }).catch(() => { window.__oldWaiter = 'cancelled' }); true",
            timeout: .seconds(5)
        )
        #expect(manager.subscriberCount == 2)
        session.reload()
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        for _ in 0..<50 where manager.subscriberCount != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.subscriberCount == 1)
        #expect(try await session.executeJavaScript("typeof window.__oldWaiter", timeout: .seconds(5)) == .string("undefined"))
    }

    @Test func test_precommit_calls_start_in_order_but_finish_independently() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        manager.isAuthorizationInFlight = true
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        session.prepare(url: url, reason: .initial)
        session.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__earlySessionDone = false; window.ZdeepNative.getSession().then(() => { window.__earlySessionDone = true }); window.__earlyHostDone = false; window.ZdeepNative.getHostState().then(state => { window.__earlyHostDone = state.appState === 'foreground' });",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        defer { session.close() }

        #expect(manager.updateCalls == 0)
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        _ = try await session.waitForJavaScript("window.__earlyHostDone === true", equals: .bool(true), timeout: .seconds(5))
        #expect(try await session.executeJavaScript("window.__earlySessionDone", timeout: .seconds(5)) == .bool(false))
        #expect(manager.updateCalls == 0)

        manager.currentSession = BridgeTestSessionManager.fixtureSession
        manager.isAuthorizationInFlight = false
        manager.emit(.sessionChanged(BridgeTestSessionManager.fixtureSession))
        _ = try await session.waitForJavaScript("window.__earlySessionDone", equals: .bool(true), timeout: .seconds(5))
    }
}

@MainActor
final class BridgeTestSessionManager: SessionManaging {
    static let fixtureSession = AuthSession(
        accessToken: "fixture-token", userId: "fixture-user", carId: "fixture-car",
        expiresAt: "2030-01-01T00:00:00Z", deadline: .seconds(600), serverTimeMs: 1,
        attemptId: UUID()
    )
    static func session(token: String) -> AuthSession {
        AuthSession(accessToken: token, userId: "fixture-user", carId: "fixture-car",
            expiresAt: "2030-01-01T00:00:00Z", deadline: .seconds(600), serverTimeMs: 1,
            attemptId: UUID())
    }
    var currentSession: AuthSession? = fixtureSession
    var hasPublishedSession = false
    var updateFailure: AuthFailure?
    private(set) var updateCalls = 0
    var lastError: AuthFailure?
    var registeredBinding: RegisteredBinding?
    var isAuthorizationInFlight = false
    private var callbacks: [UUID: @MainActor (SessionManagerEvent) -> Void] = [:]
    var subscriberCount: Int { callbacks.count }

    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession { throw TestError.unused }
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession {
        updateCalls += 1
        if let updateFailure { throw updateFailure }
        throw TestError.unused
    }
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void) -> any CancellationHandle {
        let id = UUID()
        callbacks[id] = observer
        return BridgeTestCancellation { [weak self] in self?.callbacks[id] = nil }
    }
    func webViewDidBecomeVisible() {}
    func setActive(_ active: Bool) {}
    func stop() {}
    func emit(_ event: SessionManagerEvent) { for callback in callbacks.values { callback(event) } }

    static func failure(code: String) -> AuthFailure {
        AuthFailure(kind: .network, stage: .token, attemptId: UUID(), message: "Temporary fixture failure", diagnosticCode: code)
    }

    private enum TestError: Error { case unused }
}

@MainActor
private final class BridgeTestCancellation: CancellationHandle {
    private var operation: (() -> Void)?
    init(_ operation: @escaping () -> Void) { self.operation = operation }
    func cancel() { operation?(); operation = nil }
}

private final class BridgeFixtureServer {
    private let listener = try! NWListener(using: .tcp, on: .any)
    private let queue = DispatchQueue(label: "zdeep.tests.bridge-fixture")
    private let body: Data

    init() throws {
        guard let fixture = Bundle(for: HostedBridgeFixtureBundleMarker.self).url(
            forResource: "bridge-contract", withExtension: "html"
        ) else { throw FixtureError.missing }
        body = try Data(contentsOf: fixture)
    }

    init(html: String) throws { body = Data(html.utf8) }

    func start() async throws -> URL {
        let body = body
        return try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                    let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = self.listener.port else { continuation.resume(throwing: FixtureError.missingPort); return }
                    continuation.resume(returning: URL(string: "http://localhost:\(port.rawValue)/bridge-contract")!)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
    private enum FixtureError: Error { case missing, missingPort }
}

private final class HostedBridgeFixtureBundleMarker: NSObject {}
