import Foundation
import WebKit

enum WebNavigationDecision: Equatable {
    case allow
    case cancel
    case openExternal
}

enum WebNavigationPolicy {
    static func decideMainFrameResponse(
        url: URL?,
        trustedURL: URL?,
        statusCode: Int?,
        requestedURL: URL? = nil,
        isPreparing: Bool = false
    ) -> WebNavigationDecision {
        if let url, url.isFileURL, isPreparing, requestedURL == url {
            return .allow
        }
        guard sameOrigin(url, trustedURL) else { return .cancel }
        if let statusCode, statusCode >= 400 { return .cancel }
        return .allow
    }

    static func shouldFailDocumentNavigation(
        url: URL?,
        trustedURL: URL?,
        isMainFrame: Bool,
        navigationType: WKNavigationType
    ) -> Bool {
        isMainFrame
            && navigationType == .other
            && !sameOrigin(url, trustedURL)
    }

    static func decide(
        url: URL?,
        trustedURL: URL?,
        navigationType: WKNavigationType,
        isMainFrame: Bool,
        hasTargetFrame: Bool,
        userInitiated: Bool
    ) -> WebNavigationDecision {
        guard let url else { return .cancel }
        if navigationType == .backForward { return .cancel }
        let isTrustedOrigin = sameOrigin(url, trustedURL)
        if isTrustedOrigin { return .allow }
        if userInitiated, navigationType == .linkActivated, isHTTPURL(url) {
            return .openExternal
        }
        if !isMainFrame && hasTargetFrame { return .allow }
        return .cancel
    }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              let leftScheme = left.scheme?.lowercased(),
              let rightScheme = right.scheme?.lowercased(),
              let leftHost = left.host?.lowercased(),
              let rightHost = right.host?.lowercased() else { return false }
        guard let leftPort = effectivePort(left), let rightPort = effectivePort(right) else { return false }
        return leftScheme == rightScheme
            && leftHost == rightHost
            && leftPort == rightPort
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
