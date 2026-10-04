import Foundation
import WebKit

struct WebDocumentIdentity: Equatable, Sendable {
    let containerId: UUID
    let attemptId: UUID
    let documentId: UUID
}

enum WebPreparationReason: Equatable, Sendable {
    case initial
    case explicitRetry
    case fullNavigation
    case processRecovery
}

enum WebSessionEvent {
    case documentPreparing(WebDocumentIdentity, URL, WebPreparationReason)
    case documentCommitted(WebDocumentIdentity)
    case documentFailed(WebDocumentIdentity, AuthFailure)
    case processTerminated
}

@MainActor
protocol WebDocumentBridgeHandling: AnyObject {
    func bootstrap(documentId: UUID) -> WKUserScript
    func documentDidCommit(_ identity: WebDocumentIdentity)
    func closeDocument(_ identity: WebDocumentIdentity)
    func close()
}

@MainActor
final class WebDocumentContext {
    enum Phase: Equatable { case preparing, committed, failed, closed }

    let containerId: UUID
    let trustedURL: URL
    private(set) var currentIdentity: WebDocumentIdentity?
    private(set) var currentURL: URL?
    private(set) var phase: Phase = .closed
    private var preparedURL: URL?
    private var preparedReason: WebPreparationReason?
    private var navigationIds: [ObjectIdentifier: WebDocumentIdentity] = [:]

    init(containerId: UUID, trustedURL: URL) {
        self.containerId = containerId
        self.trustedURL = trustedURL
    }

    @discardableResult
    func prepare(url: URL, reason: WebPreparationReason) -> WebDocumentIdentity {
        if phase == .preparing, preparedURL == url, preparedReason == reason, let currentIdentity {
            return currentIdentity
        }
        if let currentIdentity { closeDocument(currentIdentity) }
        let identity = WebDocumentIdentity(containerId: containerId, attemptId: UUID(), documentId: UUID())
        currentIdentity = identity
        currentURL = url
        preparedURL = url
        preparedReason = reason
        phase = .preparing
        navigationIds.removeAll()
        return identity
    }

    func bindNavigation(_ id: ObjectIdentifier, to identity: WebDocumentIdentity) {
        guard phase == .preparing, currentIdentity == identity else { return }
        navigationIds[id] = identity
    }

    @discardableResult
    func commit(_ identity: WebDocumentIdentity) -> Bool {
        guard phase == .preparing, currentIdentity == identity else { return false }
        phase = .committed
        return true
    }

    func fail(_ identity: WebDocumentIdentity) {
        guard currentIdentity == identity, phase != .closed else { return }
        phase = .failed
    }

    func recordRedirect(_ url: URL) {
        guard phase != .closed else { return }
        currentURL = url
    }

    func recordSameDocumentURLChange(_ url: URL) {
        guard phase == .committed else { return }
        currentURL = url
    }

    static func isSameDocumentURL(_ lhs: URL, as rhs: URL?) -> Bool {
        guard let rhs,
              var left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              var right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        left.fragment = nil
        right.fragment = nil
        return left == right
    }

    func identity(for navigationId: ObjectIdentifier) -> WebDocumentIdentity? {
        navigationIds[navigationId]
    }

    func isCurrentAndCommitted(_ identity: WebDocumentIdentity) -> Bool {
        phase == .committed && currentIdentity == identity
    }

    func close() {
        if let currentIdentity { closeDocument(currentIdentity) }
        phase = .closed
        currentIdentity = nil
        currentURL = nil
        navigationIds.removeAll()
    }

    private func closeDocument(_ identity: WebDocumentIdentity) {
        navigationIds = navigationIds.filter { $0.value != identity }
        if currentIdentity == identity {
            currentIdentity = nil
            currentURL = nil
        }
    }
}
