import SwiftUI
import UIKit
import WebKit

@MainActor
struct WelcomeAboutSheet: View {
    let url: URL
    @State private var didFailLoading = false

    var body: some View {
        ZStack {
            WelcomeAboutWebView(url: url) {
                didFailLoading = $0
            }

            if didFailLoading {
                Text("Не удалось загрузить страницу")
                    .font(WelcomeStyle.font(.regular, size: 16, relativeTo: .body))
                    .foregroundStyle(WelcomeStyle.mutedText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WelcomeStyle.background)
            }
        }
        .background(WelcomeStyle.background)
        .accessibilityIdentifier("welcomeAboutSheet")
        .onAppear { didFailLoading = false }
    }
}

@MainActor
private struct WelcomeAboutWebView: UIViewRepresentable {
    let url: URL
    let onLoadingError: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadingError: onLoadingError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onLoadingError: (Bool) -> Void

        init(onLoadingError: @escaping (Bool) -> Void) {
            self.onLoadingError = onLoadingError
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingError(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showError(for: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showError(for: error)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                UIApplication.shared.open(url)
            }
            return nil
        }

        private func showError(for error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onLoadingError(true)
        }
    }
}
