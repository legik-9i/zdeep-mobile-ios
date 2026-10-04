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

        let oldDocumentId = try #require(session.currentDocument?.documentId)
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
        let eventCountAfterStaleDelivery = try await session.webView.callAsyncJavaScript(
            "window.__zdeepReceiveNativeEvent(documentId, 'zdeep:session-event', detail); return window.__bridgeSessionEvents.length",
            arguments: ["documentId": oldDocumentId.uuidString, "detail": ["type": "sessionExpired"]],
            in: nil, contentWorld: .page
        )
        #expect((eventCountAfterStaleDelivery as? NSNumber)?.intValue == 1)
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

    @Test func test_get_session_returns_valid_cache_during_failed_refresh() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.lastError = BridgeTestSessionManager.failure(code: "NETWORK")
        manager.isAuthorizationInFlight = true
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        let duringRefresh = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(session => session.accessToken)", timeout: .seconds(5)
        )
        #expect(duringRefresh == .string("fixture-token"))
        manager.isAuthorizationInFlight = false
        manager.emit(.authorizationActivityChanged(false))
        let afterFailure = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(session => session.accessToken)", timeout: .seconds(5)
        )
        #expect(afterFailure == .string("fixture-token"))
        #expect(manager.updateCalls == 0)
        #expect(manager.subscriberCount == 1)
    }

    @Test func test_initial_entry_failure_before_get_session_returns_last_error() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        manager.lastError = AuthFailure(
            kind: .server, stage: .pair, attemptId: UUID(), message: "Authorization was refused.",
            httpStatus: 403, serverCode: "CAR_ACCESS_DENIED", diagnosticCode: "HTTP_403"
        )
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        let error = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(() => null).catch(error => ({kind:error.kind,message:error.message,httpStatus:error.httpStatus,code:error.code}))",
            timeout: .seconds(5)
        )
        #expect(error == .object([
            "kind": .string("server"), "message": .string("Authorization was refused."),
            "httpStatus": .number(403), "code": .string("CAR_ACCESS_DENIED")
        ]))
        #expect(manager.updateCalls == 0)
        #expect(manager.subscriberCount == 1)
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

    @Test func test_expired_published_session_rejects_while_refresh_is_in_flight() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        manager.hasPublishedSession = true
        manager.isAuthorizationInFlight = true
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        let result = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(() => 'resolved').catch(error => error.code)",
            timeout: .seconds(5)
        )
        #expect(result == .string("SESSION_EXPIRED"))
        #expect(manager.subscriberCount == 1)
        #expect(manager.updateCalls == 0)
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

    @Test func test_recover_requires_actual_new_attempt() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        let session = WebSession(trustedURL: url)
        _ = NativeBridge(session: session, manager: manager) { _, _ in }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        manager.updateResult = BridgeTestSessionManager.fixtureSession
        let repeated = try await session.executeJavaScript("window.ZdeepNative.recoverUnauthorized()", timeout: .seconds(5))
        guard case .object(let repeatedFields) = repeated else { Issue.record("Expected recovery DTO"); return }
        #expect(repeatedFields["status"] == .string("unavailable"))
        #expect(repeatedFields["reason"] == .string("temporary"))
        #expect(manager.updateCalls == 1)

        manager.updateResult = BridgeTestSessionManager.session(token: "new-token")
        let refreshed = try await session.executeJavaScript("window.ZdeepNative.recoverUnauthorized()", timeout: .seconds(5))
        guard case .object(let refreshedFields) = refreshed else { Issue.record("Expected recovery DTO"); return }
        #expect(refreshedFields["status"] == .string("ready"))
        #expect(refreshedFields["session"] == .object([
            "accessToken": .string("new-token"), "carId": .string("fixture-car"),
            "expiresAt": .string("2030-01-01T00:00:00Z")
        ]))
        #expect(manager.updateCalls == 2)
    }

    @Test func test_report_ready_rejects_invalid_state() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        manager.currentSession = nil
        let session = WebSession(trustedURL: url)
        var callbackCalls = 0
        var canAccept = false
        _ = NativeBridge(session: session, manager: manager) { _, _ in
            callbackCalls += 1
            if !canAccept { throw BridgeTestReadyRejection.rejected }
        }
        defer { session.close() }
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))

        let noSession = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'content'}).then(() => 'accepted').catch(error => error.code)",
            timeout: .seconds(5)
        )
        #expect(noSession == .string("BRIDGE_NOT_READY"))
        #expect(callbackCalls == 0)

        manager.currentSession = BridgeTestSessionManager.fixtureSession
        let noExpectation = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'content'}).then(() => 'accepted').catch(error => error.code)",
            timeout: .seconds(5)
        )
        #expect(noExpectation == .string("SESSION_UNAVAILABLE"))
        #expect(callbackCalls == 1)

        canAccept = true
        let accepted = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'error'}).then(() => 'accepted')", timeout: .seconds(5)
        )
        #expect(accepted == .string("accepted"))
        let repeated = try await session.executeJavaScript(
            "window.ZdeepNative.reportReady({screen:'content'}).then(() => 'accepted')", timeout: .seconds(5)
        )
        #expect(repeated == .string("accepted"))
        #expect(callbackCalls == 2)
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
        let bridge = NativeBridge(session: session, manager: manager) { _, _ in }
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
            "window.__oldWaiter = 'pending'; window.ZdeepNative.getSession().then(() => { window.__oldWaiter = 'resolved' }).catch(error => { window.__oldWaiter = error.name }); true",
            timeout: .seconds(5)
        )
        #expect(manager.subscriberCount == 2)
        let oldIdentity = try #require(session.currentDocument)
        session.prepare(url: url, reason: .explicitRetry)
        bridge.documentDidCommit(oldIdentity)
        var oldWaiter: String?
        for _ in 0..<50 {
            let value = try await session.webView.callAsyncJavaScript(
                "return window.__oldWaiter", arguments: [:], in: nil, contentWorld: .page
            )
            oldWaiter = value as? String
            if oldWaiter == "AbortError" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(oldWaiter == "AbortError")
        session.load(url: url)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        for _ in 0..<50 where manager.subscriberCount != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.subscriberCount == 1)
        #expect(try await session.executeJavaScript("typeof window.__oldWaiter", timeout: .seconds(5)) == .string("undefined"))
    }

    @Test func test_closed_container_cannot_get_session_after_replacement() async throws {
        let fixtureServer = try BridgeFixtureServer()
        let url = try await fixtureServer.start()
        let manager = BridgeTestSessionManager()
        let oldSession = WebSession(trustedURL: url)
        let oldWebView = oldSession.webView
        _ = NativeBridge(session: oldSession, manager: manager) { _, _ in }
        oldSession.load(url: url)
        _ = try await oldSession.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        #expect(try await oldSession.executeJavaScript("window.ZdeepNative.getSession().then(session => session.accessToken)", timeout: .seconds(5)) == .string("fixture-token"))
        oldSession.close()
        #expect(manager.subscriberCount == 0)

        let newSession = WebSession(trustedURL: url)
        _ = NativeBridge(session: newSession, manager: manager) { _, _ in }
        defer { newSession.close() }
        newSession.load(url: url)
        _ = try await newSession.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(5))
        #expect(try await newSession.executeJavaScript("window.ZdeepNative.getSession().then(session => session.accessToken)", timeout: .seconds(5)) == .string("fixture-token"))

        let oldResult = try? await oldWebView.callAsyncJavaScript(
            "try { await window.ZdeepNative.getSession(); return 'received'; } catch { return 'rejected'; }",
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect((oldResult as? String) != "received")
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
    var updateResult: AuthSession?
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
        if let updateResult { return updateResult }
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

private enum BridgeTestReadyRejection: Error { case rejected }

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
