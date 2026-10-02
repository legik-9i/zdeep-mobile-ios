import Foundation
import Combine
import WebKit

@MainActor
final class WebSession: NSObject, WebSessionHandle, ObservableObject {
    let id = UUID()
    let webView: WKWebView

    @Published private(set) var requestedURL: URL?
    @Published private(set) var currentURL: URL?
    @Published private(set) var redirectChain: [URL] = []
    @Published private(set) var responseStatusCode: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var navigationError: String?
    @Published private(set) var isClosed = false

    private let diagnosticExecutor: DiagnosticExecutor

    override init() {
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: "window.ZdeepNative = {};",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)

        let webView = self.webView
        diagnosticExecutor = DiagnosticExecutor { source, completion in
            Task { @MainActor in
                do {
                    let result = try await webView.callAsyncJavaScript(
                        """
                        try {
                            return { __zdeepDiagnosticOK: true, value: await eval(source) };
                        } catch (error) {
                            return { __zdeepDiagnosticError: {
                                name: String(error?.name ?? 'Error'),
                                message: String(error?.message ?? error),
                                stack: String(error?.stack ?? '')
                            } };
                        }
                        """,
                        arguments: ["source": source],
                        in: nil,
                        contentWorld: .page
                    )
                    if let payload = result as? [String: Any] {
                        if let error = payload["__zdeepDiagnosticError"] as? [String: Any] {
                            completion(.failure(JavaScriptException(
                                name: error["name"] as? String ?? "Error",
                                message: error["message"] as? String ?? "Unknown JavaScript error",
                                stack: error["stack"] as? String ?? ""
                            )))
                            return
                        }
                        if payload["__zdeepDiagnosticOK"] as? Bool == true {
                            completion(.success(payload["value"]))
                            return
                        }
                    }
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        super.init()
        webView.navigationDelegate = self
    }

    func load(url: URL) {
        guard !isClosed else { return }
        requestedURL = url
        redirectChain = [url]
        responseStatusCode = nil
        currentURL = url
        navigationError = nil
        isLoading = true
        let navigation: WKNavigation?
        if url.isFileURL {
            navigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            navigation = webView.load(URLRequest(url: url))
        }
        guard navigation != nil else {
            isLoading = false
            navigationError = "WebKit did not start navigation"
            return
        }
    }

    func reload() {
        guard !isClosed, requestedURL != nil else { return }
        redirectChain = requestedURL.map { [$0] } ?? []
        responseStatusCode = nil
        navigationError = nil
        isLoading = true
        guard webView.reload() != nil else {
            isLoading = false
            navigationError = "WebKit did not reload the page"
            return
        }
    }

    func executeJavaScript(_ source: String, timeout: Duration) async throws -> JSONValue {
        try await waitForNavigation(timeout: timeout)
        return try await diagnosticExecutor.executeJavaScript(source, timeout: timeout)
    }

    func waitForJavaScript(
        _ source: String,
        equals expected: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        try await waitForNavigation(timeout: timeout)
        return try await diagnosticExecutor.waitForJavaScript(source, equals: expected, timeout: timeout)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isLoading = false
        diagnosticExecutor.close()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func waitForNavigation(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isLoading {
            guard !isClosed else { throw DiagnosticError.sessionClosed }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw DiagnosticError.timedOut(lastValue: nil) }
            try await Task.sleep(for: min(.milliseconds(20), remaining))
        }
        guard !isClosed else { throw DiagnosticError.sessionClosed }
        if let navigationError {
            throw DiagnosticError.navigationFailed(navigationError)
        }
    }

    private func recordNavigationFailure(_ error: Error) {
        isLoading = false
        navigationError = error.localizedDescription
        updateCurrentURL(webView.url)
    }

    private func updateCurrentURL(_ url: URL?) {
        guard let url else { return }
        if redirectChain.last != url {
            redirectChain.append(url)
        }
        currentURL = url
    }
}

private struct JavaScriptException: LocalizedError {
    let name: String
    let message: String
    let stack: String

    var errorDescription: String? {
        stack.isEmpty ? "\(name): \(message)" : "\(name): \(message)\n\(stack)"
    }
}

extension WebSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        diagnosticExecutor.navigationDidStart()
        isLoading = true
        updateCurrentURL(webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        updateCurrentURL(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateCurrentURL(webView.url)
        isLoading = false
        if let responseStatusCode, responseStatusCode >= 400 {
            navigationError = "HTTP \(responseStatusCode)"
        } else {
            navigationError = nil
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            responseStatusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(error)
    }
}

@MainActor
struct DefaultWebSessionFactory: WebSessionFactory {
    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        WebSession()
    }
}
