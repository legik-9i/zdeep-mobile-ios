import Foundation
import Combine
import WebKit
import UIKit

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
    private(set) var currentDocument: WebDocumentIdentity?
    var onEvent: ((WebSessionEvent) -> Void)?

#if DEBUG
    private let diagnosticExecutor: DiagnosticExecutor
#endif
    private var navigationCallbacks = NavigationCallbackGate<ObjectIdentifier>()
    private var pendingUserNavigationURL: URL?
    private var trustedURL: URL?
    private var launchBaseURL: URL?
    private var launchAppVersion: String?
    private var launchTheme = "light"
    private var nativeLaunchURL: URL?
    private var currentRequestIsNativeLaunch = false
    private var documentContext: WebDocumentContext?
    private var bridge: (any WebDocumentBridgeHandling)?
    private let openExternalURL: (URL) -> Void
    private static let infrastructureScripts = [WKUserScript(
        source: "window.ZdeepNative = {};",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: .page
    )]

    var isCurrentDocumentCommitted: Bool {
        guard let currentDocument else { return false }
        return documentContext?.isCurrentAndCommitted(currentDocument) == true
    }

    var documentContextPhase: WebDocumentContext.Phase? { documentContext?.phase }

    override convenience init() {
        self.init(trustedURL: nil)
    }

    init(trustedURL: URL?, openExternalURL: ((URL) -> Void)? = nil) {
        let contentController = WKUserContentController()
        Self.infrastructureScripts.forEach(contentController.addUserScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
#if DEBUG
        webView.isInspectable = true
#endif
        webView.allowsBackForwardNavigationGestures = false
        self.trustedURL = trustedURL
        self.openExternalURL = openExternalURL ?? { url in
            Task { @MainActor in UIApplication.shared.open(url) }
        }

#if DEBUG
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
#endif
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(url: URL) {
        guard !isClosed else { return }
        let isInitialLaunch = requestedURL == nil && currentDocument == nil
        let (targetURL, isNativeLaunch) = launchURL(for: url, isNativeLaunch: isInitialLaunch)
        if documentContext?.phase != .preparing || requestedURL != targetURL {
            prepare(url: targetURL, reason: currentDocument == nil ? .initial : .explicitRetry, isNativeLaunch: isNativeLaunch)
            startLoad(url: targetURL)
        } else {
            startLoad(url: targetURL)
        }
    }

    func prepareAndLoad(url: URL, reason: WebPreparationReason) {
        guard !isClosed else { return }
        let shouldUseLaunchMetadata: Bool
        if reason == .explicitRetry {
            shouldUseLaunchMetadata = url == launchBaseURL || url == nativeLaunchURL
        } else {
            shouldUseLaunchMetadata = reason == .processRecovery && currentRequestIsNativeLaunch && url == nativeLaunchURL
        }
        let (targetURL, isNativeLaunch) = launchURL(for: url, isNativeLaunch: shouldUseLaunchMetadata)
        prepare(url: targetURL, reason: reason, isNativeLaunch: isNativeLaunch)
        startLoad(url: targetURL)
    }

    func configureLaunchURL(baseURL: URL, appVersion: String, theme: String) {
        launchBaseURL = baseURL
        launchAppVersion = appVersion
        launchTheme = theme
    }

    func updateLaunchTheme(_ theme: String) {
        launchTheme = theme
    }

    func invalidateCurrentDocument() {
        guard !isClosed else { return }
        if let currentDocument { bridge?.closeDocument(currentDocument) }
        documentContext?.close()
        currentDocument = nil
        navigationCallbacks.clear()
    }

    func recoverFromProcessTermination() {
        guard !isClosed, let url = requestedURL ?? currentURL ?? trustedURL else { return }
        prepareAndLoad(url: url, reason: .processRecovery)
    }

    func prepare(url: URL, reason: WebPreparationReason, isNativeLaunch: Bool = false) {
        guard !isClosed else { return }
        trustedURL = trustedURL ?? url
        let origin = trustedURL ?? url
        let context = documentContext ?? WebDocumentContext(containerId: id, trustedURL: origin)
        documentContext = context
        let previous = context.currentIdentity
        let identity = context.prepare(url: url, reason: reason)
        navigationCallbacks.clear()
        if let previous, previous != identity { bridge?.closeDocument(previous) }
        currentDocument = identity
        requestedURL = url
        currentRequestIsNativeLaunch = isNativeLaunch
        redirectChain = [url]
        responseStatusCode = nil
        currentURL = url
        navigationError = nil
        isLoading = true
        onEvent?(.documentPreparing(identity, url, reason))
        installUserScripts(for: identity)
    }

    private func startLoad(url: URL) {
        pendingUserNavigationURL = nil
        navigationCallbacks.clear()
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
        let navigationId = ObjectIdentifier(navigation!)
        navigationCallbacks.replace(with: navigationId)
        if let currentDocument { documentContext?.bindNavigation(navigationId, to: currentDocument) }
    }

    func reload() {
        guard !isClosed, requestedURL != nil else { return }
        guard let url = requestedURL else { return }
        if currentRequestIsNativeLaunch {
            prepareAndLoad(url: url, reason: .explicitRetry)
            return
        }
        prepare(url: url, reason: .explicitRetry)
        pendingUserNavigationURL = nil
        navigationCallbacks.clear()
        guard let navigation = webView.reload() else {
            isLoading = false
            navigationError = "WebKit did not reload the page"
            return
        }
        let navigationId = ObjectIdentifier(navigation)
        navigationCallbacks.replace(with: navigationId)
        if let currentDocument { documentContext?.bindNavigation(navigationId, to: currentDocument) }
    }

    private func launchURL(for url: URL, isNativeLaunch: Bool) -> (URL, Bool) {
        guard isNativeLaunch, let launchBaseURL, let launchAppVersion,
              url == launchBaseURL || url == nativeLaunchURL else { return (url, false) }
        let targetURL = WebLaunchURL.make(
            baseURL: launchBaseURL,
            appVersion: launchAppVersion,
            bridgeVersion: NativeBridge.version,
            theme: launchTheme
        )
        nativeLaunchURL = targetURL
        return (targetURL, true)
    }

#if DEBUG
    func executeJavaScript(_ source: String, timeout: Duration) async throws -> JSONValue {
        try await DiagnosticOperation.run(timeout: timeout, waitForNavigation: { deadline in
            try await self.waitForNavigation(until: deadline)
        }, execute: { [diagnosticExecutor] deadline in
            try await diagnosticExecutor.executeJavaScript(source, deadline: deadline)
        })
    }

    func waitForJavaScript(
        _ source: String,
        equals expected: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        try await DiagnosticOperation.run(timeout: timeout, waitForNavigation: { deadline in
            try await self.waitForNavigation(until: deadline)
        }, execute: { [diagnosticExecutor] deadline in
            try await diagnosticExecutor.waitForJavaScript(source, equals: expected, deadline: deadline)
        })
    }
#endif

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isLoading = false
        if let currentDocument { bridge?.closeDocument(currentDocument) }
        bridge?.close()
        bridge = nil
        documentContext?.close()
        documentContext = nil
        currentDocument = nil
        onEvent = nil
#if DEBUG
        diagnosticExecutor.close()
#endif
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        navigationCallbacks.clear()
    }

#if DEBUG
    private func waitForNavigation(until deadline: DiagnosticDeadline) async throws {
        while isLoading {
            guard !isClosed else { throw DiagnosticError.sessionClosed }
            try deadline.ensureRemaining()
            try await Task.sleep(for: min(.milliseconds(20), deadline.remaining))
        }
        guard !isClosed else { throw DiagnosticError.sessionClosed }
        try deadline.ensureRemaining()
        if let navigationError {
            throw DiagnosticError.navigationFailed(navigationError)
        }
    }
#endif

    private func recordNavigationFailure(_ error: Error) {
        recordNavigationFailure(error.localizedDescription)
    }

    func recordNavigationFailure(_ message: String) {
        navigationCallbacks.clear()
        isLoading = false
        navigationError = message
        updateCurrentURL(webView.url)
        if let currentDocument {
            bridge?.closeDocument(currentDocument)
            onEvent?(.documentFailed(currentDocument, AuthFailure(
                kind: .network,
                stage: .web,
                attemptId: currentDocument.attemptId,
                message: message,
                httpStatus: responseStatusCode,
                diagnosticCode: "WEB_NAVIGATION_FAILED"
            )))
            documentContext?.fail(currentDocument)
        }
    }

    @discardableResult
    func adoptNavigation(_ id: ObjectIdentifier, requestedURL: URL?) -> Bool {
        let wasCurrent = navigationCallbacks.isCurrent(id)
        var adopted = false
        guard navigationCallbacks.beginIfCurrentOrAdopt(id, {
            guard !wasCurrent else { return }
            adopted = true
            let navigationURL = self.pendingUserNavigationURL ?? requestedURL
            self.requestedURL = navigationURL
            self.currentRequestIsNativeLaunch = false
            self.currentURL = navigationURL
            self.redirectChain = navigationURL.map { [$0] } ?? []
            self.responseStatusCode = nil
            self.navigationError = nil
            self.isLoading = true
        }) else { return false }
        return wasCurrent || adopted
    }

    func prepareForUserLinkNavigation(to url: URL?) {
        pendingUserNavigationURL = url
    }

    func attachBridge(_ bridge: any WebDocumentBridgeHandling) {
        guard !isClosed else { bridge.close(); return }
        self.bridge = bridge
    }

    private func installUserScripts(for identity: WebDocumentIdentity) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        Self.infrastructureScripts.forEach(controller.addUserScript)
        if let bridge { controller.addUserScript(bridge.bootstrap(documentId: identity.documentId)) }
    }

    func trusts(_ origin: WKSecurityOrigin) -> Bool {
        WebNavigationPolicy.sameOrigin(
            securityOriginProtocol: origin.protocol,
            host: origin.host,
            reportedPort: origin.port,
            trustedURL: trustedURL
        )
    }

    private func failCurrentDocument(_ message: String, status: Int? = nil) {
        responseStatusCode = status ?? responseStatusCode
        navigationCallbacks.clear()
        recordNavigationFailure(message)
    }

    func recordCurrentNavigationURL(_ url: URL?) {
        updateCurrentURL(url)
    }

    func recordResponseStatusCode(_ code: Int?) {
        responseStatusCode = code
    }

    private func updateCurrentURL(_ url: URL?) {
        guard let url else { return }
        if redirectChain.last != url {
            redirectChain.append(url)
        }
        currentURL = url
    }
}

struct NavigationCallbackGate<ID: Hashable> {
    private(set) var current: ID?
    private var superseded: Set<ID> = []

    mutating func clear() {
        if let current { superseded.insert(current) }
        current = nil
    }
    mutating func replace(with id: ID) {
        if let current, current != id { superseded.insert(current) }
        current = id
    }

    @discardableResult
    mutating func beginIfCurrentOrAdopt(_ id: ID, _ callback: () -> Void) -> Bool {
        if current != id {
            guard !superseded.contains(id) else { return false }
            if let current { superseded.insert(current) }
            current = id
        }
        callback()
        return true
    }

    @discardableResult
    func applyIfCurrent(_ id: ID, _ callback: () -> Void) -> Bool {
        guard current == id else { return false }
        callback()
        return true
    }

    func isCurrent(_ id: ID) -> Bool { current == id }
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
        guard let navigation else { return }
        let id = ObjectIdentifier(navigation)
        guard adoptNavigation(id, requestedURL: pendingUserNavigationURL ?? webView.url) else { return }
        if let currentDocument { documentContext?.bindNavigation(id, to: currentDocument) }
        pendingUserNavigationURL = nil
#if DEBUG
        diagnosticExecutor.navigationDidStart()
#endif
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let userInitiated = navigationAction.navigationType == .linkActivated
        let decision: WebNavigationDecision = url?.isFileURL == true
            && url == requestedURL
            && documentContext?.phase == .preparing
            ? .allow
            : WebNavigationPolicy.decide(
            url: url,
            trustedURL: trustedURL,
            navigationType: navigationAction.navigationType,
            isMainFrame: isMainFrame,
            hasTargetFrame: navigationAction.targetFrame != nil,
            userInitiated: userInitiated
        )
        switch decision {
        case .allow:
            if isMainFrame, let url, navigationAction.navigationType != .backForward {
                let sameDocument = WebDocumentContext.isSameDocumentURL(url, as: webView.url)
                if documentContext?.phase == .committed, !sameDocument {
                    prepare(url: url, reason: .fullNavigation)
                }
                prepareForUserLinkNavigation(to: userInitiated && !sameDocument ? url : nil)
            }
            decisionHandler(.allow)
        case .openExternal:
            if let url { openExternalURL(url) }
            decisionHandler(.cancel)
        case .cancel:
            if WebNavigationPolicy.shouldFailDocumentNavigation(
                url: url,
                trustedURL: trustedURL,
                isMainFrame: isMainFrame,
                navigationType: navigationAction.navigationType
            ) {
                failCurrentDocument("Blocked navigation to an untrusted origin")
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, navigationCallbacks.isCurrent(ObjectIdentifier(navigation)) else { return }
        if let url = webView.url, !WebNavigationPolicy.sameOrigin(url, trustedURL) {
            failCurrentDocument("Redirected to an untrusted origin")
            return
        }
        recordCurrentNavigationURL(webView.url)
        if let url = webView.url { documentContext?.recordRedirect(url) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation else { return }
        let id = ObjectIdentifier(navigation)
        guard navigationCallbacks.isCurrent(id),
              let identity = documentContext?.identity(for: id),
              documentContext?.commit(identity) == true else { return }
        currentDocument = identity
        bridge?.documentDidCommit(identity)
        onEvent?(.documentCommitted(identity))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigationCallbacks.isCurrent(ObjectIdentifier(navigation)) else { return }
        recordCurrentNavigationURL(webView.url)
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
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            recordResponseStatusCode(status)
            if WebNavigationPolicy.decideMainFrameResponse(
                url: navigationResponse.response.url,
                trustedURL: trustedURL,
                statusCode: status,
                requestedURL: requestedURL,
                isPreparing: documentContext?.phase == .preparing
            ) == .cancel {
                failCurrentDocument(
                    status.map { $0 >= 400 ? "HTTP \($0)" : "Redirected to an untrusted origin" }
                        ?? "Redirected to an untrusted origin",
                    status: status
                )
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigationCallbacks.isCurrent(ObjectIdentifier(navigation)) else { return }
        recordNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigationCallbacks.isCurrent(ObjectIdentifier(navigation)) else { return }
        recordNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent?(.processTerminated)
    }
}

extension WebSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        let decision = WebNavigationPolicy.decide(
            url: url,
            trustedURL: trustedURL,
            navigationType: navigationAction.navigationType,
            isMainFrame: false,
            hasTargetFrame: false,
            userInitiated: navigationAction.navigationType == .linkActivated
        )
        if decision == .openExternal, let url {
            openExternalURL(url)
        } else if decision == .allow, let url {
            prepare(url: url, reason: .fullNavigation)
            prepareForUserLinkNavigation(to: url)
            startLoad(url: url)
        }
        return nil
    }
}
