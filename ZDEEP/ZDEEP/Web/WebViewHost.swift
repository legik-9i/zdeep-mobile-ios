import SwiftUI
import WebKit

@MainActor
struct WebViewHost: UIViewRepresentable {
    @ObservedObject var session: WebSession
    var isVisible: Bool

    func makeUIView(context: Context) -> WKWebView {
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
}
