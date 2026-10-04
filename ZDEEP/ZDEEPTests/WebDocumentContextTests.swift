import Foundation
import WebKit
import Testing
@testable import ZDEEP

@MainActor
@Suite
struct WebDocumentContextTests {
    @Test func test_own_load_policy_reuses_prepared_context() {
        let context = WebDocumentContext(containerId: UUID(), trustedURL: URL(string: "https://app.example")!)
        let prepared = context.prepare(url: URL(string: "https://app.example/start")!, reason: .initial)
        #expect(context.prepare(url: URL(string: "https://app.example/start")!, reason: .initial) == prepared)
        #expect(context.phase == .preparing)

        context.bindNavigation(ObjectIdentifier(NavigationToken()), to: prepared)
        #expect(context.commit(prepared))
        #expect(context.phase == .committed)
        #expect(context.currentIdentity == prepared)
    }

    @Test func test_redirect_keeps_document_identity() {
        let context = WebDocumentContext(containerId: UUID(), trustedURL: URL(string: "https://app.example")!)
        let identity = context.prepare(url: URL(string: "https://app.example/start")!, reason: .initial)
        context.recordRedirect(URL(string: "https://app.example/redirected")!)
        #expect(context.currentIdentity == identity)
        #expect(context.currentURL == URL(string: "https://app.example/redirected")!)
    }

    @Test func test_late_navigation_callback_cannot_revive_closed_document() {
        let context = WebDocumentContext(containerId: UUID(), trustedURL: URL(string: "https://app.example")!)
        let identity = context.prepare(url: URL(string: "https://app.example/start")!, reason: .initial)
        let navigationId = ObjectIdentifier(NavigationToken())
        context.bindNavigation(navigationId, to: identity)
        context.close()
        #expect(!context.commit(identity))
        #expect(context.phase == .closed)
        #expect(context.currentIdentity == nil)
    }

    @Test func test_late_commit_after_failed_or_closed_preparation_cannot_open_document() {
        let context = WebDocumentContext(containerId: UUID(), trustedURL: URL(string: "https://app.example")!)
        let identity = context.prepare(url: URL(string: "https://app.example/start")!, reason: .initial)
        let navigationId = ObjectIdentifier(NavigationToken())
        context.bindNavigation(navigationId, to: identity)
        context.fail(identity)
        #expect(!context.commit(identity))
        #expect(!context.isCurrentAndCommitted(identity))
        context.close()
        #expect(context.identity(for: navigationId) == nil)
        #expect(!context.commit(identity))
        #expect(context.phase == .closed)
    }

    @Test func test_new_document_has_new_identity_and_preparing_revokes_committed_document() {
        let context = WebDocumentContext(containerId: UUID(), trustedURL: URL(string: "https://app.example")!)
        let first = context.prepare(url: URL(string: "https://app.example/start")!, reason: .initial)
        #expect(context.commit(first))
        let second = context.prepare(url: URL(string: "https://app.example/next")!, reason: .fullNavigation)
        #expect(second != first)
        #expect(context.phase == .preparing)
        #expect(!context.isCurrentAndCommitted(first))
    }

    @Test func test_session_uses_replaceable_bridge_bootstrap_and_closes_it() {
        let url = URL(string: "https://app.example/start")!
        let session = WebSession(trustedURL: url)
        let bridge = FakeDocumentBridge()
        session.attachBridge(bridge)
        session.prepare(url: url, reason: .initial)
        #expect(bridge.bootstrapCount == 1)
        let identity = session.currentDocument
        session.close()
        #expect(bridge.closedDocument == identity)
        #expect(bridge.closeCount == 1)
    }
}

private final class NavigationToken {}

@MainActor
private final class FakeDocumentBridge: WebDocumentBridgeHandling {
    private(set) var bootstrapCount = 0
    private(set) var closedDocument: WebDocumentIdentity?
    private(set) var closeCount = 0

    func bootstrap(documentId: UUID) -> WKUserScript {
        bootstrapCount += 1
        return WKUserScript(source: "window.__document = '\(documentId.uuidString)';", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func documentDidCommit(_ identity: WebDocumentIdentity) {}
    func closeDocument(_ identity: WebDocumentIdentity) { closedDocument = identity }
    func close() { closeCount += 1 }
}
