import SwiftUI
import WebKit

@MainActor
struct WebViewHost: UIViewRepresentable {
    @ObservedObject var session: WebSession

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
