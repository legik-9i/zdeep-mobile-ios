import Foundation
import WebKit
import Testing
@testable import ZDEEP

@MainActor
@Suite
struct WebNavigationPolicyTests {
    private let origin = URL(string: "https://app.example:443/home")!

    @Test func test_same_origin_uses_scheme_host_and_effective_port() {
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://APP.example/path")!, trustedURL: origin,
            navigationType: .other, isMainFrame: true, hasTargetFrame: true, userInitiated: false
        ) == .allow)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "http://app.example/path")!, trustedURL: origin,
            navigationType: .other, isMainFrame: true, hasTargetFrame: true, userInitiated: false
        ) == .cancel)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://app.example:444/path")!, trustedURL: origin,
            navigationType: .other, isMainFrame: true, hasTargetFrame: true, userInitiated: false
        ) == .cancel)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://cdn.example/app.js")!, trustedURL: origin,
            navigationType: .other, isMainFrame: false, hasTargetFrame: true, userInitiated: false
        ) == .allow)
    }

    @Test func test_history_full_navigation_is_blocked() {
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://app.example/previous")!, trustedURL: origin,
            navigationType: .backForward, isMainFrame: true, hasTargetFrame: true, userInitiated: true
        ) == .cancel)
    }

    @Test func test_external_user_link_opens_system_browser() {
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://outside.example/page")!, trustedURL: origin,
            navigationType: .linkActivated, isMainFrame: true, hasTargetFrame: true, userInitiated: true
        ) == .openExternal)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://outside.example/page")!, trustedURL: origin,
            navigationType: .linkActivated, isMainFrame: false, hasTargetFrame: false, userInitiated: true
        ) == .openExternal)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://outside.example/page")!, trustedURL: origin,
            navigationType: .linkActivated, isMainFrame: false, hasTargetFrame: true, userInitiated: true
        ) == .openExternal)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "mailto:help@example.com")!, trustedURL: origin,
            navigationType: .linkActivated, isMainFrame: true, hasTargetFrame: true, userInitiated: true
        ) == .cancel)
    }

    @Test func test_foreign_automatic_redirect_and_untrusted_new_window_are_blocked() {
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://outside.example/page")!, trustedURL: origin,
            navigationType: .other, isMainFrame: true, hasTargetFrame: true, userInitiated: false
        ) == .cancel)
        #expect(WebNavigationPolicy.decide(
            url: URL(string: "https://outside.example/page")!, trustedURL: origin,
            navigationType: .other, isMainFrame: false, hasTargetFrame: false, userInitiated: false
        ) == .cancel)
    }

    @Test func test_foreign_main_frame_response_is_rejected_even_when_successful() {
        #expect(WebNavigationPolicy.decideMainFrameResponse(
            url: URL(string: "https://outside.example/final")!, trustedURL: origin, statusCode: 200
        ) == .cancel)
        #expect(WebNavigationPolicy.decideMainFrameResponse(
            url: URL(string: "https://app.example/final")!, trustedURL: origin, statusCode: 200
        ) == .allow)
        #expect(WebNavigationPolicy.decideMainFrameResponse(
            url: URL(string: "https://app.example/final")!, trustedURL: origin, statusCode: 503
        ) == .cancel)
        let fixture = URL(fileURLWithPath: "/tmp/document-start.html")
        #expect(WebNavigationPolicy.decideMainFrameResponse(
            url: fixture,
            trustedURL: origin,
            statusCode: nil,
            requestedURL: fixture,
            isPreparing: true
        ) == .allow)
        #expect(WebNavigationPolicy.decideMainFrameResponse(
            url: fixture,
            trustedURL: origin,
            statusCode: nil,
            requestedURL: URL(fileURLWithPath: "/tmp/other.html"),
            isPreparing: true
        ) == .cancel)
        #expect(WebNavigationPolicy.decideMainFrameResponse(
            url: fixture,
            trustedURL: origin,
            statusCode: nil,
            requestedURL: fixture,
            isPreparing: false
        ) == .cancel)
    }

    @Test func test_rejected_user_link_does_not_fail_current_document() {
        #expect(!WebNavigationPolicy.shouldFailDocumentNavigation(
            url: URL(string: "mailto:help@example.com")!, trustedURL: origin,
            isMainFrame: true, navigationType: .linkActivated
        ))
        #expect(WebNavigationPolicy.shouldFailDocumentNavigation(
            url: URL(string: "https://outside.example/redirect")!, trustedURL: origin,
            isMainFrame: true, navigationType: .other
        ))
    }

    @Test func test_fragment_and_history_api_remain_same_document() {
        let base = URL(string: "https://app.example/path")!
        #expect(WebDocumentContext.isSameDocumentURL(URL(string: "https://app.example/path#section")!, as: base))
        let context = WebDocumentContext(containerId: UUID(), trustedURL: origin)
        let identity = context.prepare(url: base, reason: .initial)
        context.commit(identity)
        context.recordSameDocumentURLChange(URL(string: "https://app.example/path#section")!)
        context.recordSameDocumentURLChange(URL(string: "https://app.example/route")!)
        #expect(context.currentIdentity == identity)
        #expect(context.currentURL == URL(string: "https://app.example/route")!)
    }
}
