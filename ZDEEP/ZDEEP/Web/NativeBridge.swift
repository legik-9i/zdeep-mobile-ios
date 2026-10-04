import Foundation
import WebKit

@MainActor
final class NativeBridge: NSObject, WebDocumentBridgeHandling, WKScriptMessageHandlerWithReply {
    private struct HeldCall {
        let request: NativeBridgeRequest
        let reply: ReplyOnce
    }
    private struct SessionWaiter {
        let continuation: CheckedContinuation<AuthSession, Error>
        let subscription: any CancellationHandle
    }

    private weak var session: WebSession?
    private let manager: any SessionManaging
    private let onReady: (WebDocumentIdentity, WebReadyScreen) throws -> Void
    private var subscription: (any CancellationHandle)?
    private var currentIdentity: WebDocumentIdentity?
    private var heldCalls: [HeldCall] = []
    private var tasks: [UUID: (documentId: UUID, task: Task<Void, Never>)] = [:]
    private var waiters: [UUID: SessionWaiter] = [:]
    private var sequence = 0
    private var appState = "foreground"
    private var acceptedReadyDocuments: Set<UUID> = []
    private var isClosed = false

    static let handlerName = "zdeepNative"
    static let bootstrapSource: String? = {
        guard let url = Bundle(for: NativeBridge.self).url(forResource: "BridgeBootstrap", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return source
    }()

    init(
        session: WebSession,
        manager: any SessionManaging,
        onReady: @escaping (WebDocumentIdentity, WebReadyScreen) throws -> Void
    ) {
        self.session = session
        self.manager = manager
        self.onReady = onReady
        super.init()
        session.webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        subscription = manager.subscribe { [weak self] event in self?.managerDidEmit(event) }
        session.attachBridge(self)
    }

    func bootstrap(documentId: UUID) -> WKUserScript {
        let source = (Self.bootstrapSource ?? "window.ZdeepNative = {};")
            .replacingOccurrences(of: "__ZDEEP_DOCUMENT_ID__", with: documentId.uuidString)
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    func setActive(_ active: Bool) {
        let newState = active ? "foreground" : "background"
        guard appState != newState else { return }
        appState = newState
        sequence += 1
        manager.setActive(active)
        deliverEvent(name: "zdeep:host-event", detail: ["type": "lifecycle", "appState": appState, "sequence": sequence])
    }

    func publishRefresh() {
        sequence += 1
        deliverEvent(name: "zdeep:host-event", detail: ["type": "refresh", "sequence": sequence])
    }

    func documentDidCommit(_ identity: WebDocumentIdentity) {
        guard !isClosed, session?.currentDocument == identity,
              identity.containerId == session?.id else { return }
        currentIdentity = identity
        let calls = heldCalls.filter { $0.request.documentId == identity.documentId.uuidString }
        heldCalls.removeAll { $0.request.documentId == identity.documentId.uuidString }
        for call in calls { start(call, identity: identity) }
        if let session = manager.currentSession { emitSessionChanged(session, to: identity) }
    }

    func closeDocument(_ identity: WebDocumentIdentity) {
        guard currentIdentity == identity || heldCalls.contains(where: { $0.request.documentId == identity.documentId.uuidString }) else { return }
        heldCalls.filter { $0.request.documentId == identity.documentId.uuidString }.forEach { $0.reply.finish(.cancelledReply) }
        heldCalls.removeAll { $0.request.documentId == identity.documentId.uuidString }
        let documentTasks = tasks.filter { $0.value.documentId == identity.documentId }
        for (id, entry) in documentTasks {
            entry.task.cancel()
            tasks.removeValue(forKey: id)
        }
        if currentIdentity == identity { currentIdentity = nil }
        acceptedReadyDocuments.remove(identity.documentId)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        heldCalls.forEach { $0.reply.finish(.cancelledReply) }
        heldCalls.removeAll()
        for (_, entry) in tasks { entry.task.cancel() }
        tasks.removeAll()
        subscription?.cancel()
        subscription = nil
        session?.webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        currentIdentity = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let reply = ReplyOnce(replyHandler)
        guard !isClosed, message.name == Self.handlerName,
              message.frameInfo.isMainFrame, let session, session.trusts(message.frameInfo.securityOrigin),
              let body = message.body as? [String: Any],
              Set(body.keys) == Set(["documentId", "method", "params"]),
              let documentId = body["documentId"] as? String,
              let method = body["method"] as? String,
              let request = NativeBridgeRequest(documentId: documentId, method: method, params: body["params"]),
              let identity = session.currentDocument,
              identity.containerId == session.id,
              identity.documentId.uuidString == request.documentId else {
            reply.finish(.failure(BridgeAuthError(message: "Invalid native bridge request", code: "BRIDGE_INVALID_REQUEST")))
            return
        }
        let call = HeldCall(request: request, reply: reply)
        guard session.documentContextPhase == .preparing || session.isCurrentDocumentCommitted else {
            reply.finish(.cancelledReply)
            return
        }
        if session.documentContextPhase == .preparing {
            heldCalls.append(call)
        } else {
            start(call, identity: identity)
        }
    }

    private func start(_ call: HeldCall, identity: WebDocumentIdentity) {
        guard !isClosed, session?.currentDocument == identity,
              session?.isCurrentDocumentCommitted == true else {
            call.reply.finish(.cancelledReply)
            return
        }
        let taskId = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { call.reply.finish(.cancelledReply); return }
            defer { self.tasks[taskId] = nil }
            do {
                let value: BridgeReply
                switch call.request.method {
                case "getSession": value = .success(WebviewSession(try await self.getSession()))
                case "recoverUnauthorized": value = .success(try await self.recoverUnauthorized())
                case "getHostState": value = .success(BridgeHostState(appState: self.appState, sequence: self.sequence))
                case "reportReady":
                    guard let screen = call.request.params?.base as? String,
                          let screen = WebReadyScreen(rawValue: screen) else {
                        throw BridgeOperationError(message: "Session is not ready", code: "BRIDGE_NOT_READY")
                    }
                    if !self.acceptedReadyDocuments.contains(identity.documentId) {
                        guard self.manager.currentSession != nil else {
                            throw BridgeOperationError(message: "Session is not ready", code: "BRIDGE_NOT_READY")
                        }
                        try self.onReady(identity, screen)
                        self.acceptedReadyDocuments.insert(identity.documentId)
                    }
                    value = .success(BridgeNull.value)
                default: throw BridgeOperationError(message: "Invalid bridge method", code: "BRIDGE_INVALID_METHOD")
                }
                guard !Task.isCancelled, self.currentIdentity == identity,
                      self.session?.currentDocument == identity else { call.reply.finish(.cancelledReply); return }
                call.reply.finish(value)
            } catch is CancellationError {
                call.reply.finish(.cancelledReply)
            } catch let failure as AuthFailure {
                call.reply.finish(.failure(BridgeAuthError(failure)))
            } catch let failure as RegistrationFailure {
                call.reply.finish(.failure(BridgeAuthError(failure.failure)))
            } catch let error as BridgeOperationError {
                call.reply.finish(.failure(BridgeAuthError(message: error.message, code: error.code)))
            } catch {
                call.reply.finish(.failure(BridgeAuthError(message: "Session is temporarily unavailable", code: "SESSION_UNAVAILABLE")))
            }
        }
        tasks[taskId] = (identity.documentId, task)
    }

    private func getSession() async throws -> AuthSession {
        if let current = manager.currentSession { return current }
        if let failure = manager.lastError, !manager.isAuthorizationInFlight { throw failure }
        if manager.hasPublishedSession {
            throw BridgeOperationError(message: "Session expired", code: "SESSION_EXPIRED")
        }
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let token = manager.subscribe { [weak self] event in
                    guard let self, let waiter = self.waiters[waiterId] else { return }
                    switch event {
                    case .sessionChanged(let session):
                        self.waiters.removeValue(forKey: waiterId)?.subscription.cancel()
                        waiter.continuation.resume(returning: session)
                    case .entryFailed(let failure):
                        self.waiters.removeValue(forKey: waiterId)?.subscription.cancel()
                        waiter.continuation.resume(throwing: failure)
                    case .sessionExpired(let failure):
                        self.waiters.removeValue(forKey: waiterId)?.subscription.cancel()
                        waiter.continuation.resume(throwing: failure ?? BridgeOperationError(message: "Session expired", code: "SESSION_EXPIRED"))
                    case .authorizationActivityChanged: break
                    }
                }
                waiters[waiterId] = SessionWaiter(continuation: continuation, subscription: token)
                if let failure = manager.lastError, manager.currentSession == nil,
                   !manager.isAuthorizationInFlight {
                    waiters.removeValue(forKey: waiterId)?.subscription.cancel()
                    continuation.resume(throwing: failure)
                } else if manager.hasPublishedSession, manager.currentSession == nil {
                    waiters.removeValue(forKey: waiterId)?.subscription.cancel()
                    continuation.resume(throwing: BridgeOperationError(message: "Session expired", code: "SESSION_EXPIRED"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let waiter = self?.waiters.removeValue(forKey: waiterId) else { return }
                waiter.subscription.cancel()
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func recoverUnauthorized() async throws -> SessionRecovery {
        guard manager.currentSession != nil || manager.hasPublishedSession else {
            return .unavailable(reason: "temporary", error: nil)
        }
        do {
            let previous = manager.currentSession?.accessToken
            let updated = try await manager.updateSession(binding: nil)
            guard updated.accessToken != previous else {
                return .unavailable(reason: "temporary", error: BridgeAuthError(message: "Refresh did not publish a new session", code: "SESSION_UNCHANGED"))
            }
            return .ready(WebviewSession(updated))
        } catch let failure as RegistrationFailure {
            if isTerminal(failure.failure) {
                return .terminal(reason: "authorization")
            }
            return .unavailable(reason: manager.currentSession == nil ? "expired" : "temporary", error: BridgeAuthError(failure.failure))
        } catch let failure as AuthFailure {
            if isTerminal(failure) { return .terminal(reason: "authorization") }
            return .unavailable(reason: manager.currentSession == nil ? "expired" : "temporary", error: BridgeAuthError(failure))
        } catch {
            return .unavailable(reason: manager.currentSession == nil ? "expired" : "temporary", error: BridgeAuthError(message: "Session refresh failed", code: "SESSION_REFRESH_FAILED"))
        }
    }

    private func isTerminal(_ failure: AuthFailure) -> Bool {
        failure.diagnosticCode.contains("CONTEXT") || failure.diagnosticCode == "NO_BINDING"
            || failure.diagnosticCode == "CAR_IDENTITY_MISMATCH"
    }

    private func managerDidEmit(_ event: SessionManagerEvent) {
        switch event {
        case .sessionChanged(let session):
            guard let identity = currentIdentity, self.session?.currentDocument == identity else { return }
            emitSessionChanged(session, to: identity)
        case .sessionExpired(let failure):
            guard let identity = currentIdentity else { return }
            var detail: [String: Any] = ["type": "sessionExpired"]
            if let failure { detail["error"] = dictionary(BridgeAuthError(failure)) }
            deliverEvent(name: "zdeep:session-event", detail: detail, identity: identity)
        case .entryFailed, .authorizationActivityChanged: break
        }
    }

    private func emitSessionChanged(_ session: AuthSession, to identity: WebDocumentIdentity) {
        guard session.deadline > .zero else { return }
        deliverEvent(name: "zdeep:session-event", detail: ["type": "sessionChanged", "session": dictionary(WebviewSession(session))], identity: identity)
    }

    private func deliverEvent(name: String, detail: [String: Any], identity: WebDocumentIdentity? = nil) {
        guard let session, let identity = identity ?? currentIdentity,
              !isClosed, currentIdentity == identity, session.currentDocument == identity,
              session.isCurrentDocumentCommitted else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, !self.isClosed,
                  self.currentIdentity == identity, session.currentDocument == identity else { return }
            if name == "zdeep:session-event" {
                if detail["type"] as? String == "sessionChanged" {
                    let token = (detail["session"] as? [String: Any])?["accessToken"] as? String
                    guard token == self.manager.currentSession?.accessToken else { return }
                } else if detail["type"] as? String == "sessionExpired", self.manager.currentSession != nil {
                    return
                }
            }
            _ = try? await session.webView.callAsyncJavaScript(
                "window.__zdeepReceiveNativeEvent(documentId, name, detail)",
                arguments: ["documentId": identity.documentId.uuidString, "name": name, "detail": detail],
                in: nil,
                contentWorld: .page
            )
        }
    }

    private func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
}

@MainActor
private final class ReplyOnce {
    private var replyHandler: ((Any?, String?) -> Void)?
    init(_ handler: @escaping (Any?, String?) -> Void) { replyHandler = handler }
    func finish(_ reply: BridgeReply) {
        guard let handler = replyHandler else { return }
        replyHandler = nil
        let data = try? JSONEncoder().encode(reply)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        handler(object, nil)
    }
}

private struct BridgeOperationError: Error {
    let message: String
    let code: String
}

private enum BridgeNull: Encodable {
    case value
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}
