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
