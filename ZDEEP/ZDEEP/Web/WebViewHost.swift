import SwiftUI
import WebKit
import UIKit

@MainActor
struct WebViewHost: UIViewRepresentable {
    @ObservedObject var session: WebSession
    var isVisible: Bool

    func makeUIView(context: Context) -> WKWebView {
        Self.configureBackground(for: session.webView)
        updateAccessibility(for: session.webView)
        return session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        updateAccessibility(for: uiView)
    }

    private func updateAccessibility(for webView: WKWebView) {
        webView.accessibilityElementsHidden = !isVisible
        webView.isUserInteractionEnabled = isVisible
    }

    static func configureBackground(for webView: WKWebView) {
        let background = UIColor(named: "NativeBackground")
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.underPageBackgroundColor = background
    }
}
